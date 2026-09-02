import Foundation

/// 可遗弃的超时竞速。
///
/// `withThrowingTaskGroup` 实现的超时有一个致命限制：任务组退出前必须等待所有子任务
/// 结束，`cancelAll()` 只能设置协作取消标记。如果被超时的操作卡在无法响应取消的
/// 同步 FFI 里（Unicorn/ADI 模拟、Minimuxer Rust FFI、AltSign 内部回调），
/// 超时错误要一直等 FFI 返回才能抛出，等于没有超时。
///
/// 这里改用非结构化任务：超时先到就直接返回或抛出，输掉竞速的任务被“遗弃”在后台
/// 自行结束，其结果被安全丢弃（continuation 只允许 resume 一次，由锁保证）。
enum HardTimeout {
    struct TimeoutError: Error, LocalizedError, Sendable {
        let seconds: TimeInterval

        var errorDescription: String? {
            "操作超过 \(Int(seconds)) 秒未完成"
        }
    }

    static func run<T: Sendable>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let state = RaceState<T>()
        return try await withCheckedThrowingContinuation { continuation in
            // 必须先同步存入 continuation，再启动竞速任务，保证 resume 永远发生在 store 之后
            state.store(continuation)
            state.startTimer(seconds: seconds)
            state.startOperation(operation)
        }
    }

    /// 锁保护的竞速状态；同一模式见 AppleAccountClient.LegacyCallbackBox。
    /// 获胜方负责 resume；输掉的一方稍后调用 finish 时 continuation 已被清空，安全忽略。
    private final class RaceState<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var timer: Task<Void, Never>?
        private var work: Task<Void, Never>?

        func store(_ continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func startTimer(seconds: TimeInterval) {
            lock.lock()
            let task = Task.detached(priority: .utility) { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                } catch {
                    return // 工作先完成时定时器已被取消
                }
                self?.finish(.failure(TimeoutError(seconds: seconds)))
            }
            timer = task
            lock.unlock()
        }

        func startOperation(_ operation: @escaping @Sendable () async throws -> T) {
            lock.lock()
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                let result: Result<T, Error>
                do {
                    result = .success(try await operation())
                } catch {
                    result = .failure(error)
                }
                self?.finish(result)
            }
            work = task
            lock.unlock()
        }

        private func finish(_ result: Result<T, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            let timerToCancel = timer
            timer = nil
            let workToCancel = work
            work = nil
            lock.unlock()

            timerToCancel?.cancel()
            workToCancel?.cancel()
            pending?.resume(with: result)
        }
    }
}
