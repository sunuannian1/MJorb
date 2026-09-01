import Foundation
@preconcurrency import NetworkExtension

/// 不依赖界面的 LocalDevVPN 激活器。
///
/// 与仅发送 TCP 探测的 `LocalDevVPNOnDemandActivator` 不同，本激活器会在签名/安装前
/// 显式加载并启动 Packet Tunnel（startVPNTunnel），然后在有界时间内等待本地回环
/// （10.7.0.1）真正可达。这样在纯蜂窝（未连接 Wi-Fi）环境下也能把本地隧道主动拉起来，
/// 因为 on-demand 处于关闭状态时，iOS 不会因为一次 TCP 探测就自动建立隧道——这正是
/// 纯流量卡在“准备环境”的根因。
actor LocalTunnelActivator: VPNOnDemandActivating {
    private enum Config {
        static let deviceAddress = "10.7.0.0"
        static let reflectedAddress = "10.7.0.1"
        static let subnetMask = "255.255.255.0"
        static let providerSuffix = ".TunnelProv"
        static let deviceKey = "TunnelDeviceIP"
        static let fakeKey = "TunnelFakeIP"
        static let maskKey = "TunnelSubnetMask"
        static let serverAddress = "Seal Local Network Tunnel"
        static let localizedDescription = "Seal"
    }

    /// 回环连通性探测复用现有实现（对 10.7.0.1 发起短连接）。
    private let reachability = LocalDevVPNOnDemandActivator()

    func activate() async {
        _ = await ensureConnected()
    }

    func probeTunnel() async -> Bool {
        await reachability.probeTunnel()
    }

    /// 签名/安装结束后主动断开隧道，避免在纯蜂窝下常驻分流隧道影响外网访问。
    func deactivate() async {
        #if targetEnvironment(simulator)
        return
        #else
        await Self.stopTunnelOnMain(bundleID: providerBundleID)
        #endif
    }

    /// 主动连接隧道并在有限尝试次数内等待回环可达；隧道一旦可达会立即返回。
    /// - Returns: 隧道回环是否最终可达
    func ensureConnected(attempts: Int = 8, intervalMilliseconds: UInt64 = 1000) async -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        // 已经连通就不必重复启动。
        if await reachability.probeTunnel() { return true }

        let bundleID = providerBundleID
        let startRequested = await Self.startTunnelOnMain(bundleID: bundleID)

        for index in 0..<attempts {
            if await reachability.probeTunnel() { return true }
            // 连 startVPNTunnel 都没请求成功，就不必继续空等。
            if index == 0, startRequested == false { return false }
            try? await Task.sleep(nanoseconds: intervalMilliseconds * 1_000_000)
        }
        return await reachability.probeTunnel()
        #endif
    }

    private var providerBundleID: String {
        (Bundle.main.bundleIdentifier ?? "com.mjorb.seal") + Config.providerSuffix
    }

    // MARK: - NetworkExtension (MainActor)

    /// 在 MainActor 上加载（或创建）并启动隧道。NEVPNManager 系列 API 要求在主线程使用。
    @MainActor
    private static func startTunnelOnMain(bundleID: String) async -> Bool {
        // NetworkExtension 的完成回调在调用方主线程执行；manager 是 non-Sendable 的
        // Objective-C 引用类型，用 nonisolated(unsafe) 显式承接，并只在 MainActor 内使用。
        nonisolated(unsafe) var loadedManagers: [NETunnelProviderManager]?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, _ in
                loadedManagers = managers
                continuation.resume()
            }
        }

        let matching = (loadedManagers ?? []).first { manager in
            (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == bundleID
        }

        let manager: NETunnelProviderManager
        if let matching {
            manager = matching
        } else {
            let created = NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = bundleID
            proto.serverAddress = Config.serverAddress
            proto.providerConfiguration = [
                Config.deviceKey: Config.deviceAddress,
                Config.fakeKey: Config.reflectedAddress,
                Config.maskKey: Config.subnetMask
            ]
            created.localizedDescription = Config.localizedDescription
            created.protocolConfiguration = proto
            created.isEnabled = true
            created.isOnDemandEnabled = false
            created.onDemandRules = nil

            guard await save(created), await reload(created) else { return false }
            manager = created
        }

        switch manager.connection.status {
        case .connected, .connecting, .reasserting:
            // 已连接或正在连接，交给外层轮询等待可达即可。
            return true
        default:
            break
        }

        do {
            try manager.connection.startVPNTunnel(options: [
                Config.deviceKey: Config.deviceAddress as NSString,
                Config.fakeKey: Config.reflectedAddress as NSString,
                Config.maskKey: Config.subnetMask as NSString
            ])
            return true
        } catch {
            // 例如隧道正在建立、配置冲突等；交给外层探测判断最终状态。
            return false
        }
    }

    @MainActor
    private static func save(_ manager: NETunnelProviderManager) async -> Bool {
        nonisolated(unsafe) let target = manager
        nonisolated(unsafe) var savedError: Error?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            target.saveToPreferences { error in
                savedError = error
                continuation.resume()
            }
        }
        return savedError == nil
    }

    @MainActor
    private static func reload(_ manager: NETunnelProviderManager) async -> Bool {
        nonisolated(unsafe) let target = manager
        nonisolated(unsafe) var reloadedError: Error?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            target.loadFromPreferences { error in
                reloadedError = error
                continuation.resume()
            }
        }
        return reloadedError == nil
    }

    @MainActor
    private static func stopTunnelOnMain(bundleID: String) async {
        nonisolated(unsafe) var loadedManagers: [NETunnelProviderManager]?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, _ in
                loadedManagers = managers
                continuation.resume()
            }
        }
        let matching = (loadedManagers ?? []).first { manager in
            (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == bundleID
        }
        guard let matching else { return }
        switch matching.connection.status {
        case .connected, .connecting, .reasserting:
            matching.connection.stopVPNTunnel()
        default:
            break
        }
    }
}
