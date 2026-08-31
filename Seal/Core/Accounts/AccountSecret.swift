import Foundation
import AltSign

struct AccountSecret: Codable, Equatable, Sendable {
    let email: String
    let accountIdentifier: String
    let dsid: String
    let authToken: String
    var certificateP12: Data?
    var certificateSerialNumber: String?
    var certificateMachineIdentifier: String?
    /// 登录时使用的 Anisette 数据，必须与 authToken 绑定使用，否则 Apple 返回 1100 会话过期
    /// 以 NSKeyedArchiver 序列化后的 Data 形式保存
    var anisetteData: Data?

    /// 恢复登录时保存的 Anisette 数据
    var savedAnisetteData: ALTAnisetteData? {
        guard let data = anisetteData else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: ALTAnisetteData.self, from: data)
    }

    /// 用当前 Anisette 数据创建副本
    func withAnisetteData(_ anisetteData: ALTAnisetteData) -> AccountSecret {
        var copy = self
        copy.anisetteData = try? NSKeyedArchiver.archivedData(withRootObject: anisetteData, requiringSecureCoding: false)
        return copy
    }
}
