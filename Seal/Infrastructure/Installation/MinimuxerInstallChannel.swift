import Foundation
@preconcurrency import Minimuxer

actor MinimuxerInstallChannel: InstallChannel {
    private let pairingStore: PairingStore
    private let logDirectory: URL
    private let onDemandActivator: any VPNOnDemandActivating
    private var cachedDeviceIdentifier: String?
    private var lastSuccessfulStart: Date?

    private static let startHardTimeoutSeconds: Double = 40
    private static let blockingCallTimeoutSeconds: Double = 5.0

    init(
        pairingStore: PairingStore,
        logDirectory: URL,
        onDemandActivator: any VPNOnDemandActivating = LocalDevVPNOnDemandActivator()
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
        // 整体硬超时：最多两轮诊断，避免永久停在"准备环境"。
        return try await withHardTimeout(seconds: Self.startHardTimeoutSeconds) {
            try await self.startOnce()
        }
    }

    /// 一次完整的隧道诊断流程；作为 actor 隔离方法，可直接读写自身缓存状态。
    private func startOnce() async throws -> String {
        var diagnostics = await diagnose()
        if diagnostics.failure != nil || diagnostics.deviceIdentifier == nil {
            // 第一轮失败：重置 Minimuxer 后再诊断一次。
            await reset()
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

    /// 整体硬超时：超时先到直接抛出；同步阻塞 FFI 无法被真正中断，
    /// 会在后台自行结束（结果被遗弃丢弃），不再阻塞用户流程。
    private func withHardTimeout<T: Sendable>(
        seconds: Double,
        _ work: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        do {
            return try await HardTimeout.run(seconds: seconds, work)
        } catch is HardTimeout.TimeoutError {
            throw Self.channelTimeoutFailure
        }
    }

    /// Result 的 Failure 侧（any Error）不保证 Sendable，用 @unchecked 包装穿过竞速边界
    private struct OffThreadOutcome<T: Sendable>: @unchecked Sendable {
        let result: Result<T, Error>
    }

    /// 在后台线程执行可能长时间阻塞的同步 Minimuxer FFI；
    /// 超过 `seconds` 未返回则返回 nil（本次放弃），FFI 在后台自行结束后结果被丢弃，
    /// 避免同步调用把整个通道拖成“假死”。
    private func offThread<T: Sendable>(
        seconds: Double,
        _ work: @Sendable @escaping () throws -> T
    ) async -> Result<T, Error>? {
        // 抛错只可能是超时（工作结果/错误都装在 Result 里返回），统一映射为 nil
        do {
            let outcome: OffThreadOutcome<T> = try await HardTimeout.run(seconds: seconds) {
                OffThreadOutcome(result: Result(catching: work))
            }
            return outcome.result
        } catch {
            return nil
        }
    }

    func pushIpa(ipaData: Data, bundleID: String) async throws {
        #if !targetEnvironment(simulator)
        guard await isReady() else { throw Self.channelNotReadyFailure }
        let ipaMB = Double(ipaData.count) / 1_000_000
        let pushTimeout = min(1200.0, 120.0 + ipaMB * 2.5)
        let maxAttempts = ipaMB > 100 ? 2 : 4
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                let pushOutcome = await offThread(seconds: pushTimeout) {
                    try Minimuxer.yeetAppAfc(bundleId: bundleID, ipaBytes: ipaData)
                }
                if case .some(.failure(let pushError)) = pushOutcome { throw pushError }
                guard pushOutcome != nil else { throw Self.installTimeoutFailure }
                return
            } catch {
                lastError = error
                guard attempt < maxAttempts else { break }
                if attempt == 1 {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                } else {
                    Minimuxer.reset()
                    await waitForNetworkRefresh(rounds: 4, delay: .milliseconds(600))
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                }
                var readyWait = 0
                while await isReady() == false && readyWait < 15 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    readyWait += 1
                }
                continue
            }
        }
        throw Self.installationFailure(lastError!)
        #endif
    }

    func installPushedIpa(bundleID: String, isSelfReplacement: Bool) async throws {
        #if !targetEnvironment(simulator)
        guard await isReady() else { throw Self.channelNotReadyFailure }
        let installTimeout = 600.0
        var lastError: Error?
        for attempt in 1...3 {
            do {
                // 每次安装前重置Install提供者，避免使用已断开的RSD缓存连接
                // 推送大文件后RSD连接可能超时断开，isReady()只检查TCP不检查RSD服务
                Install.resetProvider()
                if isSelfReplacement {
                    let installation = Task.detached(priority: .userInitiated) {
                        try Minimuxer.installIpa(bundleId: bundleID)
                    }
                    try await Task.sleep(for: .milliseconds(250))
                    await SelfReplacementController.returnToHomeScreen()
                    try await installation.value
                } else {
                    let installOutcome = await offThread(seconds: installTimeout) {
                        try Minimuxer.installIpa(bundleId: bundleID)
                    }
                    if case .some(.failure(let installError)) = installOutcome { throw installError }
                    guard installOutcome != nil else { throw Self.installTimeoutFailure }
                }
                return
            } catch {
                lastError = error
                guard attempt < 3 else { break }
                // 重试前重置连接，避免用死连接重试
                Install.resetProvider()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                continue
            }
        }
        throw Self.installationFailure(lastError!)
        #endif
    }

    /// 完整安装：push + install，遇到 MissingPackagePath 时自动重新 push 再 install。
    /// 根因：yeetAppAfc 的 afc.writeFile 可能写入不完整但返回 true，导致 installd 找不到包。
    /// 原 installPushedIpa 只重试 install 不重试 push，所以一直失败。
    func install(ipaData: Data, bundleID: String, isSelfReplacement: Bool) async throws {
        try await pushIpa(ipaData: ipaData, bundleID: bundleID)
        do {
            try await installPushedIpa(bundleID: bundleID, isSelfReplacement: isSelfReplacement)
        } catch {
            let msg = error.localizedDescription
            if msg.contains("MissingPackagePath") || msg.contains("missing package path") {
                NSLog("[Seal] MissingPackagePath detected, re-pushing IPA and retrying install")
                try await pushIpa(ipaData: ipaData, bundleID: bundleID)
                try await installPushedIpa(bundleID: bundleID, isSelfReplacement: isSelfReplacement)
            } else {
                throw error
            }
        }
    }

    func verifyInstalled(bundleID: String) async throws {
        #if targetEnvironment(simulator)
        return
        #else
        guard await isReady() else { throw Self.channelNotReadyFailure }
        // 验证前重置连接，避免用死连接查询
        Install.resetProvider()
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
        let isNoDevice = detail.contains("NoDevice") || detail.contains("device")
        let recovery = isNoDevice
            ? "与设备连接断开，请检查 WiFi 连接后重试；大文件安装请保持 Seal 在前台"
            : "确认设备已信任、存储空间充足后重试"
        return ImportFailure(
            title: "安装失败",
            reason: "设备返回：\(detail)",
            recovery: recovery,
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
