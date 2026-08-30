fpath = r"C:\Users\DMJ\Desktop\Seal--source-e50b594\Seal\Infrastructure\Installation\MinimuxerInstallChannel.swift"
with open(fpath, 'r', encoding='utf-8') as f:
    content = f.read()

old = """actor MinimuxerInstallChannel: InstallChannel {
    private let pairingStore: PairingStore
    private let logDirectory: URL
    private let onDemandActivator: any VPNOnDemandActivating

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
        let diagnostics = await diagnose()
        if let failure = diagnostics.failure { throw failure }
        guard let deviceIdentifier = diagnostics.deviceIdentifier else {
            throw Self.channelNotReadyFailure
        }
        return deviceIdentifier
    }"""

new = """actor MinimuxerInstallChannel: InstallChannel {
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
        let diagnostics = await diagnose()
        if let failure = diagnostics.failure { throw failure }
        guard let deviceIdentifier = diagnostics.deviceIdentifier else {
            throw Self.channelNotReadyFailure
        }
        cachedDeviceIdentifier = deviceIdentifier
        lastSuccessfulStart = Date()
        return deviceIdentifier
    }"""

if old in content:
    content = content.replace(old, new)
    with open(fpath, 'w', encoding='utf-8') as f:
        f.write(content)
    print("Done!")
else:
    print("ERROR: old string not found")
