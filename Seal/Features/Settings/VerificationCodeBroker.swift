import Foundation

@MainActor
final class VerificationCodeBroker: ObservableObject {
    @Published private(set) var isRequested = false
    @Published private(set) var hasSubmittedCode = false

    private var continuation: CheckedContinuation<String?, Never>?

    /// 是否允许弹出交互式验证码输入。
    /// 后台批量续签时置为 false：LocalDevVPN 隔离 gsa.apple.com，交互式 2FA 在续签
    /// 路径下必败，弹窗只会让用户空等；此时 request() 立即返回 nil，让认证快速失败，
    /// 由上层统一引导用户到“我的”页重新验证。用户主动签名/添加账号保持 true。
    private var allowsInteractivePrompt = true

    /// 切换交互模式。关闭时取消任何正在等待的请求，避免悬挂的续算。
    func setInteractivePromptAllowed(_ allowed: Bool) {
        allowsInteractivePrompt = allowed
        if !allowed {
            finish(with: nil)
        }
    }

    /// 当前是否允许交互式验证码弹窗（供 UI/测试判断）。
    var isInteractivePromptAllowed: Bool {
        allowsInteractivePrompt
    }

    func request() async -> String? {
        // 非交互场景：不置 isRequested（UI 不会弹窗），直接放弃 2FA。
        guard allowsInteractivePrompt else { return nil }
        cancel()
        hasSubmittedCode = false
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.isRequested = true
            }
        } onCancel: {
            Task { @MainActor in
                self.cancel()
            }
        }
    }

    func submit(_ code: String) {
        let normalized = code.filter(\.isNumber)
        guard normalized.isEmpty == false else { return }
        hasSubmittedCode = true
        finish(with: normalized)
    }

    func cancel() {
        finish(with: nil)
    }

    private func finish(with code: String?) {
        let pending = continuation
        continuation = nil
        isRequested = false
        if code == nil {
            hasSubmittedCode = false
        }
        pending?.resume(returning: code)
    }
}
