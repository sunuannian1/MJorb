import Foundation
import Security
import RorkSign

/// 基于 rork-sign（纯 Swift zsign 兼容签名引擎）的 App 签名器。
///
/// 替代 ALTSigner/ldid：
/// - 纯 Swift 流式处理，大 IPA 不会触发 ldid.cpp(538) 内存崩溃；
/// - 自己实现 CMS/PKCS#7 签名，格式与 zsign/codesign 对齐；
/// - inside-out 一次签名主 app、扩展、Framework，并自动嵌入描述文件、生成 CodeResources。
///
/// 本类型只依赖 Foundation + Security + RorkSign（不依赖 AltSign），入参全部是 Sendable 的
/// String/Data，可安全地在后台线程/Task.detached 中执行 CPU 密集型签名。
enum RorkAppSigner {

    /// 一个待嵌入的描述文件：bundleID 为改写后的 ID，data 为描述文件原始字节。
    struct ProfileMaterial: Sendable {
        let bundleID: String
        let data: Data
    }

    enum SignError: LocalizedError {
        case missingP12
        case missingMainProfile(String)
        case identityImportFailed(String)
        case signFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingP12:
                return "证书数据缺失（P12），请重新登录 Apple ID 后重试"
            case .missingMainProfile(let bundleID):
                return "主应用描述文件缺失：\(bundleID)"
            case .identityImportFailed(let detail):
                return "证书导入失败：\(detail)"
            case .signFailed(let detail):
                return "签名失败：\(detail)"
            }
        }
    }

    /// SecPKCS12Import 返回字典的键（iOS 上 kSecImportItem* 常量在某些 Swift 版本不可用，用字面量）
    private static let kImportIdentity = "identity"
    private static let kImportCertificate = "certificate"
    private static let kImportPrivateKey = "privateKey"

    /// 用 iOS 原生 Security framework 解析 P12，导出证书 DER 和私钥 DER。
    ///
    /// AltSign 用 unencryptedP12Data() 生成 Apple 原生无密码 P12，rork-sign 自带的
    /// PKCS12 解析器与 Apple 的 MAC 计算不兼容（报 PKCS#12 MAC verification failed）。
    /// 用 SecPKCS12Import 解析后直接传 DER 给 rork-sign，彻底绕过这个问题。
    private static func extractIdentityDER(from p12Data: Data) throws -> (certificate: Data, privateKey: Data) {
        var importResult: CFArray?

        // 先尝试空密码（AltSign 无密码 P12 在 Apple 实现中用空串即可导入）
        let optionsWithEmpty: [String: Any] = [kSecImportExportPassphrase as String: ""]
        var status = SecPKCS12Import(p12Data as CFData, optionsWithEmpty as CFDictionary, &importResult)

        // 空密码失败时尝试无密码（不传 passphrase）
        if status != errSecSuccess {
            importResult = nil
            status = SecPKCS12Import(p12Data as CFData, [:] as CFDictionary, &importResult)
        }

        guard status == errSecSuccess,
              let items = importResult as? [[String: Any]],
              let first = items.first else {
            throw SignError.identityImportFailed("SecPKCS12Import 失败 (OSStatus \(status))，请重新登录 Apple ID")
        }

        // 优先从 identity 提取；identity 包含证书+私钥，最可靠
        if let identity = first[kImportIdentity] as! SecIdentity? {
            var cert: SecCertificate?
            let certStatus = SecIdentityCopyCertificate(identity, &cert)
            var key: SecKey?
            let keyStatus = SecIdentityCopyPrivateKey(identity, &key)
            if certStatus == errSecSuccess, keyStatus == errSecSuccess,
               let certificate = cert, let privateKey = key {
                let certificateDER = SecCertificateCopyData(certificate) as Data
                var error: Unmanaged<CFError>?
                if let privateKeyDER = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? {
                    return (certificateDER, privateKeyDER)
                }
            }
        }

        // 回退：分别取 certificate 和 privateKey
        guard let cert = first[kImportCertificate] as? SecCertificate else {
            throw SignError.identityImportFailed("P12 中未找到证书")
        }
        guard let key = first[kImportPrivateKey] as? SecKey else {
            throw SignError.identityImportFailed("P12 中未找到私钥")
        }

        let certificateDER = SecCertificateCopyData(cert) as Data
        var error: Unmanaged<CFError>?
        guard let privateKeyDER = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            let desc = error?.takeRetainedValue().localizedDescription ?? "未知错误"
            throw SignError.identityImportFailed("私钥导出失败：\(desc)")
        }

        return (certificateDER, privateKeyDER)
    }

    /// 用 rork-sign 原地签名整个 .app bundle。
    ///
    /// 调用前 `SigningWorkspace.prepare` 已完成：解压、改 BundleID、strip arm64e、
    /// 删除旧 _CodeSignature、ad-hoc 占位。本方法只负责正式的 CMS 签名。
    /// 可在后台线程执行。
    ///
    /// - Parameters:
    ///   - appURL: .app bundle 路径
    ///   - p12Data: P12 证书数据（AltSign unencryptedP12Data 生成，Apple 原生无密码 P12）
    ///   - mainBundleID: 主应用改写后的 Bundle ID（prepared.mappedMainBundleID）
    ///   - profiles: 全部描述文件（主应用 + 扩展），bundleID 均为改写后的 ID
    static func signAppBundle(
        at appURL: URL,
        p12Data: Data?,
        mainBundleID: String,
        profiles: [ProfileMaterial]
    ) throws {
        guard let p12Data, p12Data.isEmpty == false else {
            throw SignError.missingP12
        }

        // 主描述文件：优先精确匹配主 Bundle ID，兜底取第一个
        guard let mainProfile = profiles.first(where: {
            $0.bundleID.caseInsensitiveCompare(mainBundleID) == .orderedSame
        }) ?? profiles.first else {
            throw SignError.missingMainProfile(mainBundleID)
        }

        // 扩展描述文件：按"改写后的 Bundle ID -> 描述文件数据"建索引
        var extensionProfiles: [String: Data] = [:]
        for profile in profiles {
            if profile.bundleID.caseInsensitiveCompare(mainBundleID) == .orderedSame {
                continue
            }
            extensionProfiles[profile.bundleID] = profile.data
        }

        // 用 iOS 原生 Security framework 解析 P12，绕过 rork-sign PKCS12 解析器的 MAC 不兼容
        let identity: SigningIdentity
        do {
            let der = try extractIdentityDER(from: p12Data)
            identity = try SigningIdentity(certificateDER: der.certificate, privateKeyDER: der.privateKey)
        } catch let error as SignError {
            throw error
        } catch {
            throw SignError.identityImportFailed(error.localizedDescription)
        }

        // 主 Bundle ID 已在 prepare 阶段改写，这里传同一个 ID，rork-sign rebase 后保持不变
        let options = AppSigningOptions(
            bundleIdentifier: mainBundleID,
            rootProvisioningProfile: mainProfile.data,
            provisioningProfilesByBundleIdentifier: extensionProfiles,
            embedProvisioningProfiles: true,
            codeDirectoryHashingMode: .sha256Only
        )

        do {
            try RorkSigner.signBundle(
                at: appURL,
                identity: identity,
                options: options
            )
        } catch {
            throw SignError.signFailed(error.localizedDescription)
        }
    }
}
