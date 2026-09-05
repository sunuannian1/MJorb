//
//  SignedArtifactValidator.swift
//  Seal
//
//  安装前验证签名后 IPA 的结构完整性，避免把损坏/不完整的包传到设备端
//  （设备端 installd 对结构损坏的包可能误报 MissingPackagePath 或其他模糊错误）。
//

import Foundation
import ZIPFoundation

/// 签名后 IPA 的结构验证结果。
struct SignedArtifactValidationResult: Equatable, Sendable {
    let isValid: Bool
    let failureReason: String?
    let failureCode: String?

    static let valid = SignedArtifactValidationResult(
        isValid: true,
        failureReason: nil,
        failureCode: nil
    )

    static func invalid(reason: String, code: String) -> SignedArtifactValidationResult {
        SignedArtifactValidationResult(
            isValid: false,
            failureReason: reason,
            failureCode: code
        )
    }
}

/// 安装前对签名后 IPA 做结构验证。所有检查只读内存中的 Data，不写临时文件。
enum SignedArtifactValidator {
    /// 验证签名后 IPA 的结构完整性。
    /// - Parameters:
    ///   - ipaData: 签名后 IPA 的完整字节
    ///   - expectedBundleID: 预期的 Bundle ID（从包内 Info.plist 回读，不一致则失败）
    /// - Returns: 验证结果，失败时包含可操作的原因和错误码
    static func validate(
        ipaData: Data,
        expectedBundleID: String
    ) -> SignedArtifactValidationResult {
        // 1. 基本检查：非空
        guard ipaData.isEmpty == false else {
            return .invalid(
                reason: "签名后 IPA 为空（0 字节），无法安装。",
                code: "SEAL-INSTALL-720"
            )
        }

        // 2. 可以作为 ZIP 打开
        guard let archive = try? Archive(data: ipaData, accessMode: .read) else {
            return .invalid(
                reason: "签名后 IPA 不是有效的 ZIP 压缩包，无法解析。可能是签名或打包过程中损坏。",
                code: "SEAL-INSTALL-721"
            )
        }

        let entries = Array(archive)

        // 3. 存在 Payload/ 目录
        let hasPayloadDir = entries.contains { entry in
            let path = entry.path
            return path == "Payload/" || path.hasPrefix("Payload/")
        }
        guard hasPayloadDir else {
            return .invalid(
                reason: "签名后 IPA 内缺少 Payload/ 目录，不是有效的 iOS 应用包。",
                code: "SEAL-INSTALL-722"
            )
        }

        // 4. 存在恰好一个 Payload/*.app 目录（主应用）
        let appDirs = entries.compactMap { entry -> String? in
            let path = entry.path
            let segments = path.split(separator: "/")
            guard segments.count >= 2,
                  segments[0] == "Payload",
                  segments[1].hasSuffix(".app") else {
                return nil
            }
            return String(segments[1])
        }
        let uniqueAppDirs = Array(Set(appDirs))
        guard uniqueAppDirs.count == 1, let appDir = uniqueAppDirs.first else {
            return .invalid(
                reason: "签名后 IPA 内 Payload/ 下应恰好有一个 .app 主程序目录，实际找到 \(uniqueAppDirs.count) 个：\(uniqueAppDirs.joined(separator: ", "))。",
                code: "SEAL-INSTALL-723"
            )
        }

        // 5. Payload/*.app/Info.plist 存在且可以解析
        let infoPlistPath = "Payload/\(appDir)/Info.plist"
        guard let infoPlistEntry = entries.first(where: { $0.path == infoPlistPath }) else {
            return .invalid(
                reason: "签名后 IPA 内缺少 \(infoPlistPath)，主应用配置文件缺失。",
                code: "SEAL-INSTALL-724"
            )
        }

        var plistData = Data()
        do {
            _ = try archive.extract(infoPlistEntry) { chunk in
                plistData.append(chunk)
            }
        } catch {
            return .invalid(
                reason: "无法读取 \(infoPlistPath) 的内容：\(error.localizedDescription)",
                code: "SEAL-INSTALL-725"
            )
        }

        guard plistData.isEmpty == false,
              let plistObj = try? PropertyListSerialization.propertyList(
                  from: plistData,
                  options: [],
                  format: nil
              ),
              let plist = plistObj as? [String: Any] else {
            return .invalid(
                reason: "\(infoPlistPath) 无法解析为有效的 plist 字典。",
                code: "SEAL-INSTALL-726"
            )
        }

        // 6. Bundle ID 与预期一致
        guard let actualBundleID = plist["CFBundleIdentifier"] as? String,
              actualBundleID.isEmpty == false else {
            return .invalid(
                reason: "\(infoPlistPath) 中缺少 CFBundleIdentifier。",
                code: "SEAL-INSTALL-727"
            )
        }
        guard actualBundleID.caseInsensitiveCompare(expectedBundleID) == .orderedSame else {
            return .invalid(
                reason: "包内 Bundle ID（\(actualBundleID)）与签名记录（\(expectedBundleID)）不一致，安装会被 installd 拒绝。",
                code: "SEAL-INSTALL-728"
            )
        }

        // 7. embedded.mobileprovision 存在
        let provisionPath = "Payload/\(appDir)/embedded.mobileprovision"
        guard entries.contains(where: { $0.path == provisionPath }) else {
            return .invalid(
                reason: "签名后 IPA 内缺少 \(provisionPath)，描述文件缺失，设备无法验证签名。",
                code: "SEAL-INSTALL-729"
            )
        }

        // 8. 主可执行文件存在（从 Info.plist 的 CFBundleExecutable 读取）
        if let executableName = plist["CFBundleExecutable"] as? String,
           executableName.isEmpty == false {
            let executablePath = "Payload/\(appDir)/\(executableName)"
            guard entries.contains(where: { $0.path == executablePath }) else {
                return .invalid(
                    reason: "签名后 IPA 内缺少主可执行文件 \(executablePath)（CFBundleExecutable=\(executableName)）。",
                    code: "SEAL-INSTALL-730"
                )
            }
        }

        return .valid
    }
}
