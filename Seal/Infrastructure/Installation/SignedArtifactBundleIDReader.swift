//
//  SignedArtifactBundleIDReader.swift
//  Seal
//
//  从「签名后成品 IPA」回读主应用真实 Bundle ID，对齐官方 idevice 安装助手。
//

import Foundation
import ZIPFoundation

/// 从签名后成品 IPA 的 `Payload/<App>.app/Info.plist` 回读真实 CFBundleIdentifier。
///
/// 为什么需要：安装时下发给 InstallationProxy 的 ClientOptions（CFBundleIdentifier）、
/// AFC 暂存包、以及安装后 lookup 校验，必须使用同一个「包内真实 ID」。签名流程外部计算的
/// mapped bundle id 在极少数非标准包（framework 错位、ESign 残留、内含多个 Info.plist）
/// 上可能与最终写入包内 Info.plist 的值不一致，进而诱发 installd `MissingPackagePath` 或
/// 安装后校验失败。官方 idevice 的安装助手正是在上传前打开 zip 回读该 ID（只认恰好三段
/// 的 `Payload -> <App>.app -> Info.plist`，避开 extension / framework 内的同名文件），
/// 这里与其保持一致；任何一步失败都返回 nil，由调用方回退到外部计算值，绝不阻断安装。
enum SignedArtifactBundleIDReader {
    /// 主应用 Info.plist 在 IPA 内的路径段数：Payload / <App>.app / Info.plist。
    private static let mainInfoPlistSegmentCount = 3

    static func bundleIdentifier(in ipaData: Data) -> String? {
        guard let archive = try? Archive(data: ipaData, accessMode: .read) else { return nil }

        guard let entry = archive.first(where: { isMainInfoPlist($0.path) }) else { return nil }

        var plistData = Data()
        do {
            _ = try archive.extract(entry) { chunk in
                plistData.append(chunk)
            }
        } catch {
            return nil
        }

        guard plistData.isEmpty == false,
              let value = try? PropertyListSerialization.propertyList(
                  from: plistData,
                  options: [],
                  format: nil
              ),
              let plist = value as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String,
              identifier.isEmpty == false
        else {
            return nil
        }
        return identifier
    }

    private static func isMainInfoPlist(_ path: String) -> Bool {
        let segments = path.split(separator: "/")
        guard segments.count == mainInfoPlistSegmentCount else { return false }
        return segments[0] == "Payload"
            && segments[1].hasSuffix(".app")
            && segments[2] == "Info.plist"
    }
}
