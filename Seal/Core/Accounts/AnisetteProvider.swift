import CryptoKit
import Foundation
@preconcurrency import AltSign

protocol AnisetteProvider: Sendable {
    func fetch() async throws -> ALTAnisetteData
    /// 认证时强制使用本地 anisette，不允许降级远程。
    /// 用远程 machineID 认证会导致 authToken 与远程绑定，
    /// 之后切回本地时 machineID 漂移，Apple 判定会话异常返回 1100。
    func fetchForAuthentication() async throws -> ALTAnisetteData
    func resetProvisioning() async
    /// 下一次 fetch 跳过设备本地生成、直接走远程公共服务器（本地指纹被 Apple 拒绝时换指纹重试）
    func preferRemoteOnNextFetch() async
}

extension AnisetteProvider {
    /// 默认无操作；只有同时具备本地/远程双通道的实现需要覆盖
    func preferRemoteOnNextFetch() async {}
    /// 默认走 fetch；具备本地/远程双通道的实现应覆盖为强制本地
    func fetchForAuthentication() async throws -> ALTAnisetteData {
        try await fetch()
    }
}

protocol AnisetteEnvironmentManaging: AnisetteProvider {
    func availableServers() async -> [AnisetteServer]
    func selectedServerID() async -> String?
    func selectServer(id: String) async
}

enum AnisetteV3Error: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidServerResponse
    case provisioningFailed
    case staleProvisioning
    case unavailable
    case localGenerationFailed
}

struct AnisetteProvisioningState: Codable, Equatable, Sendable {
    let identifier: String
    let adiPB: String

    init?(identifier: String, adiPB: String) {
        guard identifier.isEmpty == false, adiPB.isEmpty == false else { return nil }
        self.identifier = identifier
        self.adiPB = adiPB
    }
}

struct AnisetteV3Identity: Equatable, Sendable {
    let encodedIdentifier: String
    let localUserID: String
    let deviceIdentifier: String

    init(bytes: Data) throws {
        guard bytes.count == 16 else {
            throw AnisetteV3Error.invalidIdentifier
        }

        encodedIdentifier = bytes.base64EncodedString()
        localUserID = SHA256.hash(data: bytes)
            .map { String(format: "%02X", $0) }
            .joined()

        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        deviceIdentifier = [
            String(hex.prefix(8)),
            String(hex.dropFirst(8).prefix(4)),
            String(hex.dropFirst(12).prefix(4)),
            String(hex.dropFirst(16).prefix(4)),
            String(hex.dropFirst(20).prefix(12))
        ].joined(separator: "-")
    }
}
