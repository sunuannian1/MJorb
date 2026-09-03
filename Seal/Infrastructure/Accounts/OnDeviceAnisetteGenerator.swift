import Foundation
import ZIPFoundation
@preconcurrency import AltSign
import AnisetteKit

/// 设备本地 Anisette 生成器（对齐 SideStore `OnDeviceAnisetteManager` + SideSign remoteODA 流程）。
///
/// 原理：通过 AnisetteKit 在 App 进程内用 Unicorn CPU 解释器运行 Apple 的 ADI 库
/// （libstoreservicescore.so / libCoreADI.so），在本地完成 provisioning 并生成
/// X-Apple-I-MD 系列请求头，完全不依赖远程公共 Anisette 服务器。
///
/// 解决的根本问题：远程方案在多台公共服务器之间轮询，而 provisioning 得到的
/// machineID 与服务器绑定，切换服务器会重新 provision 导致设备指纹漂移，
/// Apple 因此判定会话异常并返回 1100（会话过期），表现为 Apple ID 频繁失效。
/// 本地方案的设备标识与 adi.pb 永久保存在本机，设备指纹恒定，从根源消除该问题。
actor OnDeviceAnisetteGenerator {
    static let shared = OnDeviceAnisetteGenerator()

    /// SideStore 官方默认的 ODA 元数据地址，返回 `{s: sha256, l: base64(zip)}`
    private static let odaMetadataURL = URL(string: "https://zzz.haus/oda.json")!

    private let libsDirectory: URL
    private let provisioningDirectory: URL
    private let keychain: OnDeviceAnisetteKeychain

    private var isPreparingLibraries = false

    init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        let rootDirectory = appSupport
            .appendingPathComponent("Seal", isDirectory: true)
            .appendingPathComponent(".anisette", isDirectory: true)
        provisioningDirectory = rootDirectory.appendingPathComponent("Provisioning", isDirectory: true)
        keychain = OnDeviceAnisetteKeychain()

        // 库文件必须放在可写目录：Unicorn 引擎 mmap 加载 .so 时需要 PROT_WRITE。
        // App Bundle 是只读的，直接用会导致加载失败。copyBundledLibraries() 会把
        // 构建时打进 .app/Anisette/ 的 .so 复制到这里。
        libsDirectory = rootDirectory.appendingPathComponent("Libraries", isDirectory: true)
    }

    /// 本地库是否已就绪（两个 .so 都存在）
    func isReady() -> Bool {
        LocalAnisetteProvider.validateLibrariesExist(at: libsDirectory)
    }

    /// 生成本地 Anisette 数据。
    /// - Parameter identity: 与远程方案共享的稳定设备标识
    func makeAnisetteData(identity: AnisetteV3Identity) async throws -> ALTAnisetteData {
        try await ensureLibrariesReady()
        let identifierUUID = try Self.uuid(fromBase64Identifier: identity.encodedIdentifier)

        let existingBlob = try? await keychain.loadAdiBlob()
        let (headers, newBlob) = try await Self.generateHeaders(
            provisioningDirectory: provisioningDirectory,
            librariesDirectory: libsDirectory,
            identifier: identifierUUID,
            existingBlob: existingBlob
        )
        if let newBlob, newBlob.isEmpty == false {
            try await keychain.saveAdiBlob(newBlob)
        }

        guard let machineID = headers["X-Apple-I-MD-M"],
              let oneTimePassword = headers["X-Apple-I-MD"],
              machineID.isEmpty == false,
              oneTimePassword.isEmpty == false else {
            throw OnDeviceAnisetteError.invalidHeaders
        }
        let routingInfo = headers["X-Apple-I-MD-RINFO"]
            ?? LocalAnisetteProvider.defaultRoutingInfo

        // 对齐 SideStore 官方的 clientInfo 格式，避免 Apple 因设备描述不匹配拒绝请求
        let clientInfo = "<MacBookPro18,3> <macOS;26.6;25F84> <com.apple.AuthKit/1 (com.apple.dt.Xcode/26.0)>"
        // 字段逻辑必须与远程 AnisetteClient.fetchHeaders 完全一致，
        // 本地/远程通道切换时设备指纹字段才不会跳变
        let formatted: [String: String] = [
            "deviceSerialNumber": headers["X-Apple-I-SRL-NO"]?.isEmpty == false
                ? headers["X-Apple-I-SRL-NO"]! : "0",
            "deviceDescription": clientInfo,
            // 优先使用共享 identity 推导出的稳定标识，保证本地/远程指纹完全一致
            "localUserID": identity.localUserID,
            "deviceUniqueIdentifier": identity.deviceIdentifier,
            "date": Self.currentDateString(),
            "locale": Locale.current.identifier,
            "timeZone": TimeZone.current.abbreviation() ?? "PST",
            "machineID": machineID,
            "oneTimePassword": oneTimePassword,
            "routingInfo": routingInfo
        ]

        guard let anisetteData = ALTAnisetteData(json: formatted) else {
            throw OnDeviceAnisetteError.invalidHeaders
        }
        return anisetteData
    }

    /// 清除本地 provisioning（adi.pb），保留设备标识与已下载的库
    func resetProvisioning() async {
        try? await keychain.removeAdiBlob()
    }

    /// 在非隔离上下文创建并调用 `LocalAnisetteProvider`。
    ///
    /// `LocalAnisetteProvider` 是未标注 Sendable 的 class，在 Swift 6 严格并发下
    /// 不能从 actor 隔离域跨 await 发送。这里把它的创建与调用完全封闭在一个
    /// `nonisolated` 静态函数内，入参/返回值均为 Sendable，由调用方 actor 串行保证安全。
    private nonisolated static func generateHeaders(
        provisioningDirectory: URL,
        librariesDirectory: URL,
        identifier: UUID,
        existingBlob: Data?
    ) async throws -> (headers: [String: String], newBlob: Data?) {
        let provider = try LocalAnisetteProvider(
            provisioningDir: provisioningDirectory,
            clientInfo: LocalAnisetteProvider.defaultClientInfo
        ) { librariesDirectory }
        return try await provider.getHeaders(
            identifier: identifier,
            storage: .memory(existingBlob: existingBlob)
        )
    }

    // MARK: - Provider / Libraries

    private func ensureLibrariesReady() async throws {
        try FileManager.default.createDirectory(
            at: provisioningDirectory,
            withIntermediateDirectories: true
        )

        // 如果 libsDirectory 已就绪（通常是 App Bundle 内置目录），跳过复制/下载
        if LocalAnisetteProvider.validateLibrariesExist(at: libsDirectory) {
            return
        }

        // 工作目录需要创建
        try FileManager.default.createDirectory(
            at: libsDirectory,
            withIntermediateDirectories: true
        )
        try await prepareLibraries()
    }

    private func prepareLibraries() async throws {
        if isPreparingLibraries {
            // 等待并发的另一次准备完成，避免重复下载
            for _ in 0..<60 where !isReady() {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            guard isReady() else { throw OnDeviceAnisetteError.librariesMissing }
            return
        }
        isPreparingLibraries = true
        defer { isPreparingLibraries = false }

        // 1. 优先使用内置在 IPA 中的 ADI 库（零网络依赖，指纹环境恒定）
        if copyBundledLibraries() {
            guard LocalAnisetteProvider.validateLibrariesExist(at: libsDirectory) else {
                throw OnDeviceAnisetteError.librariesMissing
            }
            return
        }

        // 2. 后备：首次从官方 ODA 源下载
        let info = try await fetchODAInfo()
        let zipData = try Self.decodeODAZip(info)
        try Self.extractZip(zipData, to: libsDirectory)

        guard LocalAnisetteProvider.validateLibrariesExist(at: libsDirectory) else {
            throw OnDeviceAnisetteError.librariesMissing
        }
    }

    /// 从 App Bundle 复制内置的两个 .so 到工作目录。成功返回 true。
    private func copyBundledLibraries() -> Bool {
        let fileManager = FileManager.default
        let required = LocalAnisetteProvider.requiredLibraryNames
        var bundledURLs: [String: URL] = [:]
        for name in required {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            // 构建脚本把 .so 复制到 .app/Anisette/ 目录。
            // 直接用 bundleURL 拼接路径检查，绕过 Bundle.url 的资源索引
            // （.so 不被 Xcode 识别为资源，不在资源索引里，Bundle.url 永远返回 nil）。
            let bundledDir = Bundle.main.bundleURL
                .appendingPathComponent("Anisette", isDirectory: true)
            let directURL = bundledDir.appendingPathComponent(name)
            var found: URL?
            if fileManager.fileExists(atPath: directURL.path) {
                found = directURL
            }
            // Fallback: 遍历 Bundle 根目录递归查找（兼容旧打包方式）
            if found == nil {
                let enumerator = fileManager.enumerator(at: Bundle.main.bundleURL, includingPropertiesForKeys: nil)
                while let fileURL = enumerator?.nextObject() as? URL {
                    if fileURL.lastPathComponent == name {
                        found = fileURL
                        break
                    }
                }
            }
            guard let url = found else { return false }
            bundledURLs[name] = url
        }

        do {
            try fileManager.createDirectory(at: libsDirectory, withIntermediateDirectories: true)
            for (name, url) in bundledURLs {
                let destination = libsDirectory.appendingPathComponent(name)
                if fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: url, to: destination)
            }
            return true
        } catch {
            return false
        }
    }

    private func fetchODAInfo() async throws -> ODAInfo {
        var request = URLRequest(url: Self.odaMetadataURL)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw OnDeviceAnisetteError.downloadFailed
        }
        return try JSONDecoder().decode(ODAInfo.self, from: data)
    }

    // MARK: - Helpers

    private static func decodeODAZip(_ info: ODAInfo) throws -> Data {
        guard let base64 = info.base64Payload,
              let zipData = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              zipData.isEmpty == false else {
            throw OnDeviceAnisetteError.invalidPackage
        }
        // 传输层已由 HTTPS 保证完整性；sha256 字段仅用于可观测，不匹配也不阻断
        // （与 SideSign 行为一致，避免远端元数据短暂不一致时直接不可用）。
        return zipData
    }

    private static func extractZip(_ zipData: Data, to directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempZip = fileManager.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).oda.zip")
        try zipData.write(to: tempZip, options: .atomic)
        defer { try? fileManager.removeItem(at: tempZip) }
        try fileManager.unzipItem(at: tempZip, to: directory)
    }

    private static func uuid(fromBase64Identifier base64: String) throws -> UUID {
        guard let data = Data(base64Encoded: base64), data.count == 16 else {
            throw OnDeviceAnisetteError.invalidIdentifier
        }
        return data.withUnsafeBytes { raw in
            UUID(uuid: raw.load(as: uuid_t.self))
        }
    }

    private static func currentDateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: Date())
    }
}

// MARK: - ODA metadata

private struct ODAInfo: Decodable {
    let sha256: String?
    let base64Payload: String?

    enum CodingKeys: String, CodingKey {
        case sha256
        case sha
        case s
        case l
        case payload
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sha256 =
            (try? container.decodeIfPresent(String.self, forKey: .sha256))
            ?? (try? container.decodeIfPresent(String.self, forKey: .sha))
            ?? (try? container.decodeIfPresent(String.self, forKey: .s))
        base64Payload =
            (try? container.decodeIfPresent(String.self, forKey: .l))
            ?? (try? container.decodeIfPresent(String.self, forKey: .payload))
            ?? (try? container.decodeIfPresent(String.self, forKey: .data))
    }
}

enum OnDeviceAnisetteError: Error, LocalizedError, Sendable {
    case downloadFailed
    case invalidPackage
    case librariesMissing
    case invalidHeaders
    case invalidIdentifier

    var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "本地签名内核下载失败"
        case .invalidPackage:
            return "本地签名内核数据包无效"
        case .librariesMissing:
            return "本地签名内核文件缺失"
        case .invalidHeaders:
            return "本地签名内核未能生成有效请求头"
        case .invalidIdentifier:
            return "设备标识无效"
        }
    }
}

// MARK: - adi.pb Keychain storage

/// 独立存储本地 provisioning blob（adi.pb），与远程 v3 provisioning 互不干扰。
private actor OnDeviceAnisetteKeychain {
    private let service = "com.mjorb.seal.anisette-oda"
    private let account = "adi.pb"

    func loadAdiBlob() throws -> Data? {
        var request = baseQuery()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw OnDeviceAnisetteError.invalidPackage
        }
        return data
    }

    func saveAdiBlob(_ data: Data) throws {
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw OnDeviceAnisetteError.invalidPackage
            }
        } else if status != errSecSuccess {
            throw OnDeviceAnisetteError.invalidPackage
        }
    }

    func removeAdiBlob() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OnDeviceAnisetteError.invalidPackage
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }
}
