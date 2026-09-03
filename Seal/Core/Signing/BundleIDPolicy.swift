import Foundation

/// Bundle ID helpers. Seal validates only local string format; Apple/iOS decide availability.
enum BundleIDPolicy {
    static func canonicalSealBundleIdentifier(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "SealOriginalBundleIdentifier") as? String
            ?? "com.mjorb.seal"
    }

    static func currentSealBundleIdentifier(bundle: Bundle = .main) -> String? {
        bundle.bundleIdentifier
    }

    static func isLegacySelfBundleIdentifier(_ bundleIdentifier: String, bundle: Bundle = .main) -> Bool {
        let canonical = canonicalSealBundleIdentifier(bundle: bundle)
        return bundleIdentifier != canonical
            && bundleIdentifier.hasPrefix(canonical + ".")
    }

    static func targetBundleIdentifier(
        for app: AppRecord,
        requestedBundleIdentifier: String? = nil,
        currentSealBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) throws -> String {
        if app.requiresLockedSigningIdentity || app.state == .installed || app.isSeal {
            if let mapped = normalized(app.mappedBundleIdentifier), mapped.isEmpty == false {
                return try validated(mapped)
            }
            if let preferred = normalized(app.preferredBundleIdentifier), preferred.isEmpty == false {
                return try validated(preferred)
            }
            throw ImportFailure(
                title: "续签记录不完整",
                reason: "未记录当前签名后的 Bundle ID。",
                recovery: "重新选择 IPA 签名并安装",
                code: "SEAL-BUNDLE-002"
            )
        }
        if let requested = normalized(requestedBundleIdentifier), requested.isEmpty == false {
            return try validated(requested)
        }
        if let preferred = normalized(app.preferredBundleIdentifier), preferred.isEmpty == false {
            return try validated(preferred)
        }
        if let mapped = normalized(app.mappedBundleIdentifier), mapped.isEmpty == false {
            return try validated(mapped)
        }
        return try validated(recommendedBundleIdentifier(for: app.originalBundleIdentifier))
    }

    static func recommendedBundleIdentifier(for original: String, teamID: String) -> String {
        let value = normalized(original) ?? original
        // 对齐 AltStore 官方格式（原始+teamID），同时保留 Seal 标识：原始.seal.teamID
        // 恒定不变，同一个应用+同一个 team 永远是同一个 Bundle ID，不随机
        // 已安装应用续签时复用之前的 mappedBundleIdentifier，不受此格式影响
        return "\(value).seal.\(teamID)"
    }

    /// 无 teamID 时的重载：返回原始 Bundle ID（仅用于恢复记录等无账号上下文的场景）
    /// 实际签名时必须调用带 teamID 的版本
    static func recommendedBundleIdentifier(for original: String) -> String {
        normalized(original) ?? original
    }

    static func isEditable(_ app: AppRecord) -> Bool {
        app.isSeal == false && app.requiresLockedSigningIdentity == false && app.state != .installed
    }

    static func displayMode(for app: AppRecord) -> String {
        "按 Apple / iOS 实际返回处理"
    }

    static func validationError(for value: String) -> String? {
        do {
            _ = try validated(value)
            return nil
        } catch let failure as ImportFailure {
            return failure.reason
        } catch {
            return "Bundle ID 格式无效"
        }
    }

    private static func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validated(_ value: String) throws -> String {
        let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identifier.isEmpty == false else {
            throw failure(reason: "不能为空")
        }
        guard identifier.count <= 255 else {
            throw failure(reason: "不能超过 255 个字符")
        }
        guard identifier.hasPrefix(".") == false,
              identifier.hasSuffix(".") == false,
              identifier.contains("..") == false else {
            throw failure(reason: "不能以 . 开头或结尾，不能包含连续 ..")
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-.")
        guard identifier.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw failure(reason: "只能包含 A-Z、a-z、0-9、- 和 .")
        }
        let segments = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else {
            throw failure(reason: "至少包含两段")
        }
        guard segments.allSatisfy({ segment in
            guard let first = segment.first, let last = segment.last else { return false }
            return first != "-" && last != "-"
        }) else {
            throw failure(reason: "每段不能以 - 开头或结尾")
        }
        return identifier
    }

    private static func failure(reason: String) -> ImportFailure {
        ImportFailure(
            title: "Bundle ID 无效",
            reason: reason,
            recovery: "修改 Bundle ID",
            code: "SEAL-BUNDLE-001"
        )
    }
}
