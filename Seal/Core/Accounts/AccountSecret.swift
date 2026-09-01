import Foundation

struct AccountSecret: Codable, Equatable, Sendable {
    let email: String
    let accountIdentifier: String
    let dsid: String
    let authToken: String
    /// Apple ID 密码，用于 authToken 失效（1100）时自动重新登录
    /// 保存在钥匙串加密的 AccountSecret 中，参照 SideStore 官方做法
    let password: String?
    var certificateP12: Data?
    var certificateSerialNumber: String?
    var certificateMachineIdentifier: String?

    /// 用新的 authToken 和 dsid 创建副本（自动重登时使用）
    func withNewSession(dsid: String, authToken: String) -> AccountSecret {
        AccountSecret(
            email: email,
            accountIdentifier: accountIdentifier,
            dsid: dsid,
            authToken: authToken,
            password: password,
            certificateP12: certificateP12,
            certificateSerialNumber: certificateSerialNumber,
            certificateMachineIdentifier: certificateMachineIdentifier
        )
    }
}
