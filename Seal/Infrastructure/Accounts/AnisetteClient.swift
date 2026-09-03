import CryptoKit
import Foundation
import os
@preconcurrency import AltSign

struct AnisetteV3Client: AnisetteEnvironmentManaging {
    private static let logger = Logger(subsystem: "com.mjorb.seal", category: "anisette")

    private let servers: [AnisetteServer]
    private let session: URLSession
    private let store: any AnisetteProvisioningStore
    private let serverStore: any AnisetteServerStore
    private let onDevice: OnDeviceAnisetteGenerator
    /// 一次性标志：为 true 时本次 fetch 跳过本地生成、直接走远程（消费后自动复位）
    private let bypassLocal = AnisetteBypassFlag()

    /// 本地 ADI 模拟（Unicorn TCI）可能卡死且无法协作取消，超时后必须遗弃而不是等待
    private static let localGenerationTimeoutSeconds: TimeInterval = 45
    /// 远程降级的总时长预算：避免服务器逐个重试把添加账号拖到数分钟
    private static let remoteFallbackBudgetSeconds: TimeInterval = 120

    init(
        servers: [AnisetteServer] = AnisetteServerCatalog.official,
        session: URLSession = .shared,
        store: any AnisetteProvisioningStore = KeychainAnisetteProvisioningStore(),
        serverStore: any AnisetteServerStore = UserDefaultsAnisetteServerStore(),
        onDevice: OnDeviceAnisetteGenerator = .shared
    ) {
        self.servers = servers
        self.session = session
        self.store = store
        self.serverStore = serverStore
        self.onDevice = onDevice
    }

    func preferRemoteOnNextFetch() async {
        bypassLocal.set()
        Self.logger.error("下一次 Anisette 获取将跳过本地生成、直接使用远程服务器")
    }

    /// 本地生成是否曾成功过。一旦成功，machineID 已固定，后续必须继续用本地，
    /// 降级远程会导致 machineID 漂移，Apple 判定会话异常返回 1100，触发重新登录+2FA。
    private static let localSucceededKey = "com.mjorb.seal.anisette.localSucceeded"

    func fetch() async throws -> ALTAnisetteData {
        // 本地与远程共享同一套稳定设备标识（16 字节 → localUserID / deviceIdentifier），
        // 但 machineID 本地与远程不同：本地 adi.pb 恒定，远程与服务器绑定。
        // 一旦本地成功过就必须继续用本地，切换通道会使 Apple 会话失效（1100）。
        let identity = try await loadIdentity()
        let localHasSucceeded = UserDefaults.standard.bool(forKey: Self.localSucceededKey)

        // 1. 优先使用设备本地 AnisetteKit 生成（指纹恒定，不依赖公共服务器）
        // 本地首次生成需初始化 Unicorn(TCI) 引擎，最慢约 30 秒；超过 45 秒遗弃本地任务
        // 本地曾成功过则 machineID 已与 Apple 会话绑定，必须始终走本地，
        // 忽略 bypassLocal（认证失败时的"换远程重试"会导致 machineID 漂移触发 2FA）
        let shouldUseLocal = localHasSucceeded || bypassLocal.consume() == false
        if shouldUseLocal {
            do {
                let data = try await HardTimeout.run(seconds: Self.localGenerationTimeoutSeconds) {
                    try await onDevice.makeAnisetteData(identity: identity)
                }
                if localHasSucceeded == false {
                    UserDefaults.standard.set(true, forKey: Self.localSucceededKey)
                }
                return data
            } catch let error as HardTimeout.TimeoutError {
                Self.logger.error("本地 Anisette 生成超时（\(Int(error.seconds))s）")
                if localHasSucceeded {
                    // 本地曾成功过，machineID 已固定，降级远程会导致会话失效，直接报错让用户重试
                    Self.logger.error("本地曾成功，拒绝降级远程以避免 machineID 漂移导致 Apple 会话失效")
                    throw AnisetteV3Error.localGenerationFailed
                }
                Self.logger.error("首次使用本地未成功，降级远程服务器")
            } catch {
                Self.logger.error("本地 Anisette 生成失败：\(String(describing: error), privacy: .public)")
                if localHasSucceeded {
                    Self.logger.error("本地曾成功，拒绝降级远程以避免 machineID 漂移导致 Apple 会话失效")
                    throw AnisetteV3Error.localGenerationFailed
                }
                Self.logger.error("首次使用本地未成功，降级远程服务器")
            }
        } else {
            Self.logger.error("按上一次认证结果跳过本地 Anisette，直接使用远程服务器")
        }

        // 2. 远程公共服务器降级路径（带总时长预算，避免逐个服务器重试拖到数分钟）
        let fallbackDeadline = Date().addingTimeInterval(Self.remoteFallbackBudgetSeconds)
        var lastError: Error?
        for server in await prioritizedServers() where server.url.scheme == "https" {
            if Date() > fallbackDeadline {
                Self.logger.error("远程 Anisette 降级预算耗尽（\(Int(Self.remoteFallbackBudgetSeconds))s），停止尝试剩余服务器")
                break
            }
            do {
                try Task.checkCancellation()
                return try await fetch(from: server.url, identity: identity)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Self.logger.error("Anisette 服务器 \(server.displayName, privacy: .public) 失败：\(String(describing: error), privacy: .public)")
                lastError = error
            }
        }
        throw lastError ?? AnisetteV3Error.unavailable
    }

    func resetProvisioning() async {
        // 只清除远程 v3 provisioning session，不清除本地 adi.pb 和 identifier。
        // adi.pb 是本地 machineID 的来源，与 Apple authToken 绑定；
        // identifier（16字节 → localUserID/deviceUniqueIdentifier）也与 authToken 绑定。
        // 清除任一项都会导致所有已登录 Apple ID 全部失效（1100 会话过期），触发重新登录+2FA。
        // 本地 adi.pb 仅在用户手动清除应用数据时才会重置。
        try? await store.remove()
    }

    func availableServers() async -> [AnisetteServer] {
        servers
    }

    func selectedServerID() async -> String? {
        await serverStore.selectedServerID()
    }

    func selectServer(id: String) async {
        guard servers.contains(where: { $0.id == id }) else { return }
        await serverStore.saveSelectedServerID(id)
    }

    private func fetch(from server: URL, identity: AnisetteV3Identity) async throws -> ALTAnisetteData {
        let clientInfo = try await fetchClientInfo(from: server)

        if let state = try await store.load() {
            do {
                return try await fetchHeaders(
                    from: server,
                    state: state,
                    clientInfo: clientInfo,
                    identity: identity
                )
            } catch AnisetteV3Error.staleProvisioning,
                    AnisetteV3Error.invalidServerResponse,
                    AnisetteV3Error.provisioningFailed {
                // 本地 provisioning 失效或服务器响应异常，重置后重新 provision
                try await store.remove()
            }
        }

        // provision 失败时只报错，不重置 identity
        // identity 是设备标识（deviceUniqueIdentifier/localUserID），与 authToken 绑定
        // 重置会导致所有已登录 Apple ID 全部失效（1100 会话过期）
        let state = try await provision(
            on: server,
            clientInfo: clientInfo,
            identity: identity
        )
        try await store.save(state)
        return try await fetchHeaders(
            from: server,
            state: state,
            clientInfo: clientInfo,
            identity: identity
        )
    }

    private func loadIdentity() async throws -> AnisetteV3Identity {
        if let encoded = try await store.loadIdentifier(),
           let bytes = Data(base64Encoded: encoded) {
            return try AnisetteV3Identity(bytes: bytes)
        }

        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let encoded = bytes.base64EncodedString()
        try await store.saveIdentifier(encoded)
        return try AnisetteV3Identity(bytes: bytes)
    }

    private func fetchClientInfo(from server: URL) async throws -> AnisetteV3ClientInfo {
        let url = server.appendingPathComponent("v3").appendingPathComponent("client_info")
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AnisetteV3Error.invalidServerResponse
        }
        return try Self.parseClientInfo(data: data)
    }

    static func parseClientInfo(data: Data) throws -> AnisetteV3ClientInfo {
        let json: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AnisetteV3Error.invalidServerResponse
            }
            json = value
        } catch let error as AnisetteV3Error {
            throw error
        } catch {
            throw AnisetteV3Error.invalidServerResponse
        }
        guard
              let clientInfo = json["client_info"] as? String,
              let userAgent = json["user_agent"] as? String,
              clientInfo.isEmpty == false,
              userAgent.isEmpty == false else {
            throw AnisetteV3Error.invalidServerResponse
        }
        return AnisetteV3ClientInfo(clientInfo: clientInfo, userAgent: userAgent)
    }

    private func provision(
        on server: URL,
        clientInfo: AnisetteV3ClientInfo,
        identity: AnisetteV3Identity
    ) async throws -> AnisetteProvisioningState {
        let urls = try await provisioningURLs(clientInfo: clientInfo, identity: identity)
        var socketRequest = URLRequest(url: try websocketURL(for: server))
        socketRequest.timeoutInterval = 15
        let socket = session.webSocketTask(with: socketRequest)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        while true {
            let json = try await receiveJSON(from: socket)
            guard let result = json["result"] as? String else {
                throw AnisetteV3Error.provisioningFailed
            }

            switch result {
            case "GiveIdentifier":
                try await send(["identifier": identity.encodedIdentifier], through: socket)

            case "GiveStartProvisioningData":
                let spim = try await startProvisioning(
                    at: urls.start,
                    clientInfo: clientInfo,
                    identity: identity
                )
                try await send(["spim": spim], through: socket)

            case "GiveEndProvisioningData":
                guard let cpim = json["cpim"] as? String, cpim.isEmpty == false else {
                    throw AnisetteV3Error.provisioningFailed
                }
                let endData = try await finishProvisioning(
                    at: urls.end,
                    cpim: cpim,
                    clientInfo: clientInfo,
                    identity: identity
                )
                try await send(endData, through: socket)

            case "ProvisioningSuccess":
                guard let adiPB = json["adi_pb"] as? String,
                      let state = AnisetteProvisioningState(
                        identifier: identity.encodedIdentifier,
                        adiPB: adiPB
                      ) else {
                    throw AnisetteV3Error.provisioningFailed
                }
                return state

            default:
                if result.contains("Error") || result.contains("Invalid") ||
                    result == "ClosingPerRequest" || result == "Timeout" || result == "TextOnly" {
                    throw AnisetteV3Error.provisioningFailed
                }
            }
        }
    }

    private func provisioningURLs(
        clientInfo: AnisetteV3ClientInfo,
        identity: AnisetteV3Identity
    ) async throws -> (start: URL, end: URL) {
        guard let url = URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup") else {
            throw AnisetteV3Error.provisioningFailed
        }
        let request = appleRequest(
            url: url,
            clientInfo: clientInfo,
            identity: identity
        )
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                format: nil
              ) as? [String: [String: Any]],
              let startString = plist["urls"]?["midStartProvisioning"] as? String,
              let endString = plist["urls"]?["midFinishProvisioning"] as? String,
              let start = URL(string: startString),
              let end = URL(string: endString) else {
            throw AnisetteV3Error.provisioningFailed
        }
        return (start, end)
    }

    private func startProvisioning(
        at url: URL,
        clientInfo: AnisetteV3ClientInfo,
        identity: AnisetteV3Identity
    ) async throws -> String {
        let body: [String: [String: Any]] = [
            "Header": [:],
            "Request": [:]
        ]
        let data = try await postApplePlist(
            url: url,
            body: body,
            clientInfo: clientInfo,
            identity: identity
        )
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            format: nil
        ) as? [String: [String: Any]],
        let spim = plist["Response"]?["spim"] as? String else {
            throw AnisetteV3Error.provisioningFailed
        }
        return spim
    }

    private func finishProvisioning(
        at url: URL,
        cpim: String,
        clientInfo: AnisetteV3ClientInfo,
        identity: AnisetteV3Identity
    ) async throws -> [String: String] {
        let body: [String: [String: Any]] = [
            "Header": [:],
            "Request": ["cpim": cpim]
        ]
        let data = try await postApplePlist(
            url: url,
            body: body,
            clientInfo: clientInfo,
            identity: identity
        )
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            format: nil
        ) as? [String: [String: Any]],
        let ptm = plist["Response"]?["ptm"] as? String,
        let tk = plist["Response"]?["tk"] as? String else {
            throw AnisetteV3Error.provisioningFailed
        }
        return ["ptm": ptm, "tk": tk]
    }

    private func postApplePlist(
        url: URL,
        body: [String: [String: Any]],
        clientInfo: AnisetteV3ClientInfo,
        identity: AnisetteV3Identity
    ) async throws -> Data {
        var request = appleRequest(
            url: url,
            clientInfo: clientInfo,
            identity: identity
        )
        request.httpMethod = "POST"
        request.httpBody = try PropertyListSerialization.data(
            fromPropertyList: body,
            format: .xml,
            options: 0
        )
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AnisetteV3Error.provisioningFailed
        }
        return data
    }

    private func fetchHeaders(
        from server: URL,
        state: AnisetteProvisioningState,
        clientInfo: AnisetteV3ClientInfo,
        identity: AnisetteV3Identity
    ) async throws -> ALTAnisetteData {
        let url = server.appendingPathComponent("v3").appendingPathComponent("get_headers")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "identifier": state.identifier,
            "adi_pb": state.adiPB
        ])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AnisetteV3Error.invalidServerResponse
        }
        let json: [String: String]
        do {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                throw AnisetteV3Error.invalidServerResponse
            }
            json = value
        } catch let error as AnisetteV3Error {
            throw error
        } catch {
            throw AnisetteV3Error.invalidServerResponse
        }
        if json["result"] == "GetHeadersError" {
            if json["message"]?.contains("-45061") == true {
                throw AnisetteV3Error.staleProvisioning
            }
            throw AnisetteV3Error.provisioningFailed
        }

        var formatted: [String: String] = [
            "deviceSerialNumber": "0",
            "deviceDescription": clientInfo.clientInfo,
            "localUserID": identity.localUserID,
            "deviceUniqueIdentifier": identity.deviceIdentifier,
            "date": Self.currentDateString(),
            "locale": Locale.current.identifier,
            "timeZone": TimeZone.current.abbreviation() ?? "PST"
        ]
        guard let machineID = json["X-Apple-I-MD-M"],
              let oneTimePassword = json["X-Apple-I-MD"],
              let routingInfo = json["X-Apple-I-MD-RINFO"] else {
            throw AnisetteV3Error.invalidServerResponse
        }
        formatted["machineID"] = machineID
        formatted["oneTimePassword"] = oneTimePassword
        formatted["routingInfo"] = routingInfo
        guard let anisette = ALTAnisetteData(json: formatted) else {
            throw AnisetteV3Error.invalidServerResponse
        }
        return anisette
    }

    private func appleRequest(
        url: URL,
        clientInfo: AnisetteV3ClientInfo,
        identity: AnisetteV3Identity
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(clientInfo.clientInfo, forHTTPHeaderField: "X-Mme-Client-Info")
        request.setValue(clientInfo.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(identity.localUserID, forHTTPHeaderField: "X-Apple-I-MD-LU")
        request.setValue(identity.deviceIdentifier, forHTTPHeaderField: "X-Mme-Device-Id")
        request.setValue(Self.currentDateString(), forHTTPHeaderField: "X-Apple-I-Client-Time")
        request.setValue(Locale.current.identifier, forHTTPHeaderField: "X-Apple-Locale")
        request.setValue(
            TimeZone.current.abbreviation() ?? "PST",
            forHTTPHeaderField: "X-Apple-I-TimeZone"
        )
        return request
    }

    private func websocketURL(for server: URL) throws -> URL {
        guard var components = URLComponents(
            url: server,
            resolvingAgainstBaseURL: false
        ) else {
            throw AnisetteV3Error.invalidServerResponse
        }
        components.scheme = "wss"
        guard let baseURL = components.url else {
            throw AnisetteV3Error.invalidServerResponse
        }
        return baseURL
            .appendingPathComponent("v3")
            .appendingPathComponent("provisioning_session")
    }

    private func send(
        _ values: [String: String],
        through socket: URLSessionWebSocketTask
    ) async throws {
        let data = try JSONSerialization.data(withJSONObject: values)
        guard let string = String(data: data, encoding: .utf8) else {
            throw AnisetteV3Error.provisioningFailed
        }
        try await socket.send(.string(string))
    }

    /// 单次 WebSocket 接收超时并解析为 JSON。
    /// request.timeoutInterval 只约束建连，receive 本身可以无限期挂起；
    /// 挂起时按 provisioning 失败处理，换下一个服务器。
    private func receiveJSON(
        from socket: URLSessionWebSocketTask
    ) async throws -> [String: Any] {
        // URLSessionWebSocketTask 的 Sendable 标注随 SDK 版本不一，用 @unchecked 包装
        // 穿过竞速边界；URLSessionWebSocketTask 本身线程安全。
        final class SendableSocket: @unchecked Sendable {
            let task: URLSessionWebSocketTask
            init(_ task: URLSessionWebSocketTask) { self.task = task }
        }
        let boxed = SendableSocket(socket)
        let text: String
        do {
            text = try await HardTimeout.run(seconds: 20) {
                let message = try await boxed.task.receive()
                switch message {
                case .string(let string):
                    return string
                case .data(let data):
                    return String(decoding: data, as: UTF8.self)
                @unknown default:
                    return ""
                }
            }
        } catch is HardTimeout.TimeoutError {
            throw AnisetteV3Error.provisioningFailed
        }
        guard let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            throw AnisetteV3Error.provisioningFailed
        }
        return json
    }

    private static func currentDateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: Date())
    }

    private func prioritizedServers() async -> [AnisetteServer] {
        let selectedID = await serverStore.selectedServerID()
        guard let selectedID,
              let selected = servers.first(where: { $0.id == selectedID }) else {
            return servers
        }
        return [selected] + servers.filter { $0.id != selected.id }
    }
}

struct AnisetteV3ClientInfo: Equatable, Sendable {
    let clientInfo: String
    let userAgent: String
}

/// 一次性"跳过本地 Anisette"标志：本地指纹被 Apple 拒绝后，下一次 fetch 直接走远程。
/// 用引用类型 + 锁，保证 struct 跨并发上下文共享同一状态且线程安全。
final class AnisetteBypassFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }

    /// 读取并复位（只生效一次）
    func consume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let current = value
        value = false
        return current
    }
}

typealias AnisetteClient = AnisetteV3Client
