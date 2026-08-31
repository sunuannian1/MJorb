import Foundation
@preconcurrency import Minimuxer

actor MinimuxerInstallChannel: InstallChannel {
    private let pairingStore: PairingStore
    private let logDirectory: URL
    private let onDemandActivator: any VPNOnDemandActivating
    private var cachedDeviceIdentifier: String?
    private var lastSuccessfulStart: Date?

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
        // 宽松策略：通道诊断失败（VPN 抖动/Minimuxer 尚未就绪）时内部再试一次，
        // 不把瞬时抖动直接抛给上层签名/续签流程
        var diagnostics = await diagnose()
        if diagnostics.failure != nil || diagnostics.deviceIdentifier == nil {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
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
            await waitForNetworkRefresh(rounds: 4, delay: .milliseconds(250))
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
                try Minimuxer.start(pairingFile: pairing, logPath: logDirectory.path)
            } catch {
                return fail(.minimuxer, Self.connectionFailure(error))
            }
            // 优化：轮询检查设备，成功即退出，最多等待 20 秒
            var resolvedUDID: String?
            for _ in 0..<40 {
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
        return Minimuxer.ready()
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
                try Minimuxer.yeetAppAfc(bundleId: bundleID, ipaBytes: ipaData)
                if isSelfReplacement {
                    let installation = Task.detached(priority: .userInitiated) {
                        try Minimuxer.installIpa(bundleId: bundleID)
                    }
                    try await Task.sleep(for: .milliseconds(250))
                    await SelfReplacementController.returnToHomeScreen()
                    try await installation.value
                } else {
                    try Minimuxer.installIpa(bundleId: bundleID)
                }
                return
            } catch {
                lastInstallError = error
                if installAttempt < 3 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
            }
        }
        throw Self.installationFailure(lastInstallError!)
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
        guard let udid = Minimuxer.fetchUDID(), udid.isEmpty == false else {
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
                reason: "请确认 Wi-Fi 和 LocalDevVPN 已开启后重试。",
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
            reason: "请确认 Wi-Fi 和 LocalDevVPN 已开启后重试。",
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
        reason: "请确认 Wi-Fi 和 LocalDevVPN 已开启后重试。",
        recovery: "重试",
        code: "SEAL-INSTALL-701"
    )

    private static let deviceNotRespondingFailure = ImportFailure(
        title: "设备未响应",
        reason: "请确认 Wi-Fi 和 LocalDevVPN 已开启后重试。",
        recovery: "重试",
        code: "SEAL-INSTALL-708"
    )

    private static let channelNotReadyFailure = ImportFailure(
        title: "无法安装到手机",
        reason: "请确认 Wi-Fi 和 LocalDevVPN 已开启后重试。",
        recovery: "重试",
        code: "SEAL-INSTALL-706b"
    )
}
