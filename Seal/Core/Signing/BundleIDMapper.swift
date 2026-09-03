import CryptoKit
import Foundation

struct BundleIDMapper: Sendable {
    let prefix: String

    init(prefix: String = "com.mjorb.seal.apps") {
        self.prefix = prefix
    }

    func mainBundleID(
        original: String,
        teamID: String,
        requested: String? = nil
    ) -> String {
        if let requested, requested.isEmpty == false {
            return requested
        }
        // 对齐 AltStore 官方格式（原始+teamID），同时保留 Seal 标识：原始.seal.teamID
        // 恒定不变，同一个应用+同一个 team 永远是同一个 Bundle ID，不随机
        return BundleIDPolicy.recommendedBundleIdentifier(for: original, teamID: teamID)
    }

    func extensionBundleID(
        original: String,
        originalMainBundleID: String,
        mappedMainBundleID: String
    ) -> String {
        let originalLower = original.lowercased()
        let mainLower = originalMainBundleID.lowercased()
        if originalLower.hasPrefix(mainLower + ".") {
            let suffixIndex = original.index(
                original.startIndex,
                offsetBy: originalMainBundleID.count
            )
            let suffix = String(original[suffixIndex...])
            return mappedMainBundleID + suffix
        }
        return "\(mappedMainBundleID).e\(digest(original, length: 10))"
    }

    func extensionBundleID(
        original: String,
        mappedMainBundleID: String
    ) -> String {
        "\(mappedMainBundleID).e\(digest(original, length: 10))"
    }

    func appGroupID(original: String, teamID: String) -> String {
        // 和 Bundle ID 格式对齐：group.<去掉group.前缀的原始ID>.seal.<teamID>
        // 保留完整原始标识，多 group 自然唯一，teamID 保证全局唯一
        let base = original.hasPrefix("group.") ? String(original.dropFirst(6)) : original
        return "group.\(base).seal.\(teamID)"
    }

    private func digest(_ value: String, length: Int) -> String {
        let hash = SHA256.hash(data: Data(value.utf8))
        return hash.map { String(format: "%02x", $0) }
            .joined()
            .prefix(length)
            .description
    }
}
