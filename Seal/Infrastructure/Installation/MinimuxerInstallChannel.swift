import Foundation
@preconcurrency import Minimuxer

actor MinimuxerInstallChannel: InstallChannel {
    private let pairingStore: PairingStore
    private let logDirectory: URL
    private let onDemandActivator: any VPNOnDemandActivating
    private var cachedDeviceIdentifier: String?
    private var lastSuccessfulStart: Date?

    private static let startHardTimeoutSeconds: Double = 40
    private static let blockingCallTimeoutSeconds: Double = 2.0

    init(
        pairingStore: PairingStore,
        logDirectory: URL,
        onDemandActivator: any VPNOnDemandActivating = LocalTunnelActivator()
    ) {
        self.pairingStore = pairingStore
        self.logDirectory = logDirectory
        self.onDemandActivator = onDemandActivator
    }

    func start() async throws -> String {
        // 优化：如果最近 60 秒内成功启动过且设备仍就绪，直接返回缓存的 UDID
        if let cached = cachedDeviceIdentifier,
           let lastStart = lastSuccessfulStart,
           Date().timeIntervalSince(lastStart) < 60,
           await isReady() {
            return cached
        }
        // 整体硬超时：主动拉起隧道 + 最多两轮诊断，避免纯蜂窝下永久停在“准备环境”。
        return try await withHardTimeout(seconds: Self.startHardTimeoutSeconds) {
            try await self.startOnce()
        }
    }

    /// 一次完整的隧道激活与诊断流程；作为 actor 隔离方法，可直接读写自身缓存状态。
    private func startOnce() async throws -> String {
        // 先主动把 LocalDevVPN 拉起来：纯蜂窝下 iOS 不会因一次探测就自动建隧道。
        await onDemandActivator.activate()

        var diagnostics = await diagnose()
        if diagnostics.failure != nil || diagnostics.deviceIdentifier == nil {
            // 第一轮失败：重置 Minimuxer、重新激活隧道后再诊断一次。
            await reset()
            await onDemandActivator.activate()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            diagnostics = await diagnose()
        }
        if let failure = diagnostics.failure { throw failure }
        guard let deviceIdentifier = diagnostics.deviceIdentifier else {
            throw Self.channelNotReadyFailure
        }
        cachedDeviceIdentifier = deviceIdentifier
        lastSuccessfulStart = Date()
        return deviceIdentifier
    }

    func diagnose() async -> InstallChannelDiagnostics {
        var steps = InstallChannelDiagnostics.empty.steps
        var deviceIdentifier: String?

        func pass(_ kind: InstallDiagnosticStepKind) {
            if let index = steps.firstIndex(where: { $0.kind == kind }) {
                steps[index].status = .passed
            }
        }

        func fail(
            _ kind: InstallDiagnosticStepKind,
            _ failure: ImportFailure
        ) -> InstallChannelDiagnostics {
            if let index = steps.firstIndex(where: { $0.kind == kind }) {
                steps[index].status = .failed(failure)
            }
            return InstallChannelDiagnostics(
                steps: steps,
                deviceIdentifier: deviceIdentifier,
                failure: failure
            )
        }

        func run(_ kind: InstallDiagnosticStepKind) {
            if let index = steps.firstIndex(where: { $0.kind == kind }) {
                steps[index].status = .running
            }
        }

        do {
            run(.pairingFile)
            let pairingRecord = try await pairingStore.current()
            _ = try await pairingStore.contents()
            guard pairingRecord != nil else {
                return fail(.pairingFile, Self.missingPairingFailure)
            }
            pass(.pairingFile)

            #if targetEnvironment(simulator)
            deviceIdentifier = pairingRecord?.deviceIdentifier ?? "SIMULATOR"
            pass(.vpnTunnel)
            pass(.minimuxer)
            pass(.deviceIdentifier)
            pass(.pairingMatch)
            pass(.installationService)
            return InstallChannelDiagnostics(
                steps: steps,
                deviceIdentifier: deviceIdentifier,
                failure: nil
            )
            #else
            try FileManager.default.createDirectory(
                at: logDirectory,
                withIntermediateDirectories: true
            )
            NetworkObserver.shared.start()
            bindTunnelConfiguration()

            run(.vpnTunnel)
            await waitForNetworkRefresh(rounds: 2, delay: .milliseconds(250))
            let tunnelReachable = await onDemandActivator.probeTunnel()
            if tunnelReachable { pass(.vpnTunnel) }

            if let udid = try await readyDeviceIdentifier() {
                pass(.vpnTunnel)
                deviceIdentifier = udid
                pass(.minimuxer)
                pass(.deviceIdentifier)
                if let mismatch = Self.pairingMismatchFailure(
                    expected: pairingRecord?.effectiveDeviceIdentifier,
                    actual: udid
                ) {
                    return fail(.pairingMatch, mismatch)
                }
                pass(.pairingMatch)
                pass(.installationService)
                return InstallChannelDiagnostics(
                    steps: steps,
                    deviceIdentifier: deviceIdentifier,
                    failure: nil
                )
            }

            run(.minimuxer)
            do {
                let pairing = try await pairingStore.contents()
                let logPath = logDirectory.path
                let startOutcome = await offThread(seconds: 4.0) {
                    try Minimuxer.start(pairingFile: pairing, logPath: logPath)
                }
                if case .some(.failure(let startError)) = startOutcome {
                    return fail(.minimuxer, Self.connectionFailure(startError))
                }
            } catch {
                return fail(.minimuxer, Self.connectionFailure(error))
            }
            // 优化：轮询检查设备，成功即退出，最多等待 10 秒
            var resolvedUDID: String?
            for _ in 0..<20 {
                NetworkObserver.shared.refreshEndpoint()
                resolvedUDID = try await readyDeviceIdentifier()
                if resolvedUDID != nil { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard let udid = resolvedUDID else {
                if tunnelReachable == false {
                    return fail(.vpnTunnel, Self.vpnTunnelUnavailableFailure)
                }
                return fail(.deviceIdentifier, Self.deviceNotRespondingFailure)
            }
            pass(.vpnTunnel)
            deviceIdentifier = udid
            pass(.minimuxer)
            pass(.deviceIdentifier)

            if let mismatch = Self.pairingMismatchFailure(
                expected: pairingRecord?.effectiveDeviceIdentifier,
                actual: udid
            ) {
                return fail(.pairingMatch, mismatch)
            }
            pass(.pairingMatch)

            guard await isReady() else {
                return fail(.installationService, Self.channelNotReadyFailure)
            }
            pass(.installationService)
            return InstallChannelDiagnostics(
                steps: steps,
                deviceIdentifier: udid,
                failure: nil
            )
            #endif
        } catch let failure as ImportFailure {
            return fail(.pairingFile, failure)
        } catch {
            return fail(.pairingFile, Self.missingPairingFailure)
        }
    }

    func isReady() async -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        let outcome = await offThread(seconds: Self.blockingCallTimeoutSeconds) {
            Minimuxer.ready()
        }
        guard case .some(.success(let ready)) = outcome else { return false }
        return ready
        #endif
    }

    func storedDeviceIdentifier() async -> String? {
        do {
            return try await pairingStore.current()?.effectiveDeviceIdentifier
        } catch {
            return nil
        }
    }

    func reset() async {
        #if !targetEnvironment(simulator)
        Minimuxer.reset()
        #endif
    }

    /// 签名/安装结束后主动断开 LocalDevVPN，避免在纯蜂窝下常驻分流隧道影响外网。
    func stop() async {
        await onDemandActivator.deactivate()
    }

    /// 整体硬超时：先返回的结果胜出；超时即抛出，另一任务取消。
    /// 同步阻塞 FFI 无法被真正中断，会在后台自行结束，不再占用用户流程。
    private func withHardTimeout<T: Sendable>(
        seconds: Double,
        _ work: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Self.channelTimeoutFailure
            }
            guard let result = try await group.next() else {
                throw Self.channelNotReadyFailure
            }
            group.cancelAll()
            return result
        }
    }

    /// 在协作线程池中执行可能长时间阻塞的同步 Minimuxer FFI；
    /// 超过 `seconds` 未返回则返回 nil（本次放弃），避免同步调用把整个通道拖成“假死”。
    private func offThread<T: Sendable>(
        seconds: Double,
        _ work: @Sendable @escaping () throws -> T
    ) async -> Result<T, Error>? {
        await withTaskGroup(of: Result<T, Error>?.self) { group in
            group.addTask { .some(Result(catching: work)) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            guard let outcome = await group.next() else {
                group.cancelAll()
                return nil
            }
            group.cancelAll()
            return outcome
        }
    }

    func install(
        ipaData: Data,
        bundleID: String,
        isSelfReplacement: Bool
    ) async throws {
        #if !targetEnvironment(simulator)
        guard await isReady() else { throw Self.channelNotReadyFailure }
        var lastInstallError: Error?
        for installAttempt in 1...3 {
            do {
                let pushOutcome = await offThread(seconds: 75) {
                    try Minimuxer.yeetAppAfc(bundleId: bundleID, ipaBytes: ipaData)
                }
                if case .some(.failure(let pushError)) = pushOutcome { throw pushError }
                guard pushOutcome != nil else { throw Self.installTimeoutFailure }

                if isSelfReplacement {
                    let installation = Task.detached(priority: .userInitiated) {
                        try Minimuxer.installIpa(bundleId: bundleID)
                    }
                    try await Task.sleep(for: .milliseconds(250))
                    await SelfReplacementController.returnToHomeScreen()
                    try await installation.value
                } else {
                    let installOutcome = await offThread(seconds: 75) {
                        try Minimuxer.installIpa(bundleId: bundleID)
                    }
                    if case .some(.failure(let installError)) = installOutcome { throw installError }
                    guard installOutcome != nil else { throw Self.installTimeoutFailure }
                }
                return
            } catch {
                lastInstallError = error
                guard installAttempt < 3 else { break }
                // 第一次失败：等 2 秒；第二次失败：重置设备连接后等 4 秒
                if installAttempt == 1 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                } else {
                    Minimuxer.reset()
                    await waitForNetworkRefresh(rounds: 3, delay: .milliseconds(500))
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                }
                // 等待设备重新就绪
                var readyWait = 0
                while await isReady() == false && readyWait < 10 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    readyWait += 1
                }
                continue
            }
        }
        throw Self.installationFailure(lastInstallError!)
        #endif
    }

    func verifyInstalled(bundleID: String) async throws {
        #if targetEnvironment(simulator)
        return
        #else
        guard await isReady() else { throw Self.channelNotReadyFailure }
        for _ in 0..<8 {
            if Minimuxer.lookupApp(bundleId: bundleID) != nil { return }
            try? await Task.sleep(for: .milliseconds(650))
        }
        throw ImportFailure(
            title: "安装后验证失败",
            reason: "iOS 安装服务未返回已安装的 Bundle ID。",
            recovery: "重试",
            code: "SEAL-INSTALL-707a"
        )
        #endif
    }


    #if !targetEnvironment(simulator)
    private func bindTunnelConfiguration() {
        Minimuxer.bindTunnelConfig(
            TunnelConfigBinding(
                setDeviceIP: { _ in },
                setFakeIP: { _ in },
                setSubnetMask: { _ in },
                getOverrideFakeIP: { "10.7.0.1" },
                setOverrideEffective: { _ in }
            )
        )
    }

    private func waitForNetworkRefresh(
        rounds: Int,
        delay: Duration
    ) async {
        for _ in 0..<rounds {
            NetworkObserver.shared.refreshEndpoint()
            try? await Task.sleep(for: delay)
        }
    }

    private func readyDeviceIdentifier() async throws -> String? {
        guard await isReady() else { return nil }
        let outcome = await offThread(seconds: Self.blockingCallTimeoutSeconds) {
            () -> String? in
            guard let udid = Minimuxer.fetchUDID(), udid.isEmpty == false else {
                return nil
            }
            return udid
        }
        guard case .some(.success(let maybeUDID)) = outcome,
              let udid = maybeUDID,
              udid.isEmpty == false else {
            return nil
        }
        return udid
    }

    private static func connectionFailure(_ error: Error) -> ImportFailure {
        let message = diagnostic(error)
        let normalized = message.lowercased()
        if normalized.contains("pair")
            || normalized.contains("pairing")
            || normalized.contains("lockdown")
            || normalized.contains("hostid")
            || normalized.contains("invalid host") {
            return ImportFailure(
                title: "设备配对不可用",
                reason: "请确认已连接 Wi-Fi 且 LocalDevVPN 已连接后重试。",
                recovery: "重新配对当前设备",
                code: "SEAL-INSTALL-703"
            )
        }
        if normalized.contains("trust") || normalized.contains("trusted") {
            return ImportFailure(
                title: "设备尚未信任",
                reason: "当前设备尚未完成信任确认。",
                recovery: "在 iPhone 上信任此设备后重试",
                code: "SEAL-INSTALL-704"
            )
        }
        if normalized.contains("timeout")
            || normalized.contains("timed out")
            || normalized.contains("connection")
            || normalized.contains("network")
            || normalized.contains("refused")
            || normalized.contains("unreachable")
            || normalized.contains("no connection")
            || normalized.contains("nodevice")
            || normalized.contains("no device") {
            return channelNotReadyFailure
        }
        return ImportFailure(
            title: "无法安装到手机",
            reason: "请确认已连接 Wi-Fi 且 LocalDevVPN 已连接后重试。",
            recovery: "重试",
            code: "SEAL-INSTALL-705"
        )
    }

    private static func installationFailure(_ error: Error) -> ImportFailure {
        let detail = diagnostic(error)
        return ImportFailure(
            title: "安装失败",
            reason: "iOS 安装服务未能完成安装。\n设备返回：\(detail)",
            recovery: "确认设备已信任、存储空间充足后重试；如持续失败请查看日志",
            code: "SEAL-INSTALL-702"
        )
    }

    private static func diagnostic(_ error: Error) -> String {
        let nsError = error as NSError
        if let minimuxerError = error as? MinimuxerError {
            return Minimuxer.describeError(minimuxerError)
        }
        return "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
    }
    #endif

    private static func pairingMismatchFailure(
        expected: String?,
        actual: String
    ) -> ImportFailure? {
        guard let expected,
              expected.isEmpty == false,
              expected.caseInsensitiveCompare(actual) != .orderedSame else {
            return nil
        }
        return ImportFailure(
            title: "设备配对不匹配",
            reason: "当前配对信息属于另一台设备，无法用于这台 iPhone。",
            recovery: "重新配对当前设备",
            code: "SEAL-PAIR-205"
        )
    }

    private static let missingPairingFailure = ImportFailure(
        title: "设备未配对",
        reason: "当前设备还没有完成配对。",
        recovery: "连接设备",
        code: "SEAL-PAIR-203b"
    )

    private static let vpnTunnelUnavailableFailure = ImportFailure(
        title: "无法安装到手机",
        reason: "请确认已连接 Wi-Fi 且 LocalDevVPN 已连接后重试。",
        recovery: "重试",
        code: "SEAL-INSTALL-701"
    )

    private static let deviceNotRespondingFailure = ImportFailure(
        title: "设备未响应",
        reason: "请确认已连接 Wi-Fi 且 LocalDevVPN 已连接后重试。",
        recovery: "重试",
        code: "SEAL-INSTALL-708"
    )

    private static let channelNotReadyFailure = ImportFailure(
        title: "无法安装到手机",
        reason: "请确认已连接 Wi-Fi 且 LocalDevVPN 已连接后重试。",
        recovery: "重试",
        code: "SEAL-INSTALL-706b"
    )

    private static let channelTimeoutFailure = ImportFailure(
        title: "本地通道连接超时",
        reason: "LocalDevVPN 隧道在限定时间内未就绪。已自动重试过；仍失败请确认已连接 Wi-Fi 且 LocalDevVPN 处于连接状态后再试。",
        recovery: "重新检查",
        code: "SEAL-INSTALL-706t"
    )

    private static let installTimeoutFailure = ImportFailure(
        title: "安装超时",
        reason: "向设备传输并安装应用耗时过长，将自动重试。若多次出现，请确认 LocalDevVPN 连接稳定后再试。",
        recovery: "重试",
        code: "SEAL-INSTALL-702t"
    )
}
