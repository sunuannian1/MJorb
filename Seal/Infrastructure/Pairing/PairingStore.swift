import Foundation

/// 配对文件来源类型。
/// - remote: iOS 17+ 生成的 .mobiledevicepairing，包含 private_key，用于 CoreDevice/RemotePairing
/// - lockdown: iOS 17- 传统 Lockdown 配对 plist，包含 UDID / HostID / EscrowBag
enum PairingFileKind: String, Sendable {
    case remote
    case lockdown
    case unknown
}

actor PairingStore {
    private struct ValidationMetadata: Codable, Sendable {
        let status: PairingValidationStatus
        let validatedDeviceIdentifier: String?
        let validatedAt: Date?
    }

    private static let maximumFileSize = 5 * 1_024 * 1_024
    private let fileURL: URL
    private let metadataURL: URL
    private let backupURL: URL
    private let backupMetadataURL: URL
    private let fileProtector: any FileProtecting

    init(
        fileURL: URL,
        fileProtector: any FileProtecting = CompleteFileProtector()
    ) {
        self.fileURL = fileURL
        self.metadataURL = fileURL.appendingPathExtension("validation.json")
        self.backupURL = fileURL.appendingPathExtension("backup")
        self.backupMetadataURL = fileURL.appendingPathExtension("backup.validation.json")
        self.fileProtector = fileProtector
    }

    func importFile(at sourceURL: URL) throws -> PairingRecord {
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= Self.maximumFileSize else {
            throw Self.invalidFailure
        }
        let data = try Data(contentsOf: sourceURL)
        guard data.isEmpty == false, data.count <= Self.maximumFileSize else {
            throw Self.invalidFailure
        }

        // 同时支持 plist（iOS 17- Lockdown）和 JSON（iOS 17+ RemotePairing）解析
        let dictionary = try Self.parseDictionary(from: data)
        let inspection = try Self.inspect(dictionary)

        // 统一转成 XML plist 保存，确保 minimuxer 能识别配对文件格式
        let normalized = try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .xml,
            options: 0
        )
        let hadExistingPairing = FileManager.default.fileExists(atPath: fileURL.path)
        try backupCurrentIfNeeded()
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        do {
            try normalized.write(to: fileURL, options: .atomic)
            try fileProtector.protect(fileURL)
            try saveMetadata(
                ValidationMetadata(
                    status: .unverified,
                    validatedDeviceIdentifier: nil,
                    validatedAt: nil
                )
            )
        } catch {
            if hadExistingPairing {
                _ = try? restoreBackupIfPresent()
            } else {
                try? removeCurrentFilesAfterFailedInitialImport()
            }
            throw error
        }

        return PairingRecord(
            deviceIdentifier: inspection.udid,
            isRemotePairing: inspection.isRemote,
            validationStatus: .unverified
        )
    }

    func current() throws -> PairingRecord? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let dictionary = try dictionary()
        let inspection = try Self.inspect(dictionary)
        let metadata = try? loadMetadata()
        let storedStatus = metadata?.status ?? .unverified
        let status: PairingValidationStatus = storedStatus == .validating ? .unverified : storedStatus
        return PairingRecord(
            deviceIdentifier: inspection.udid,
            isRemotePairing: inspection.isRemote,
            validationStatus: status,
            validatedDeviceIdentifier: metadata?.validatedDeviceIdentifier,
            validatedAt: metadata?.validatedAt
        )
    }

    func markValidated(deviceIdentifier: String) throws -> PairingRecord {
        let dictionary = try dictionary()
        let inspection = try Self.inspect(dictionary)
        let existingMetadata = try? loadMetadata()

        // First successful validation establishes the persistent device binding.
        // Runtime reachability, tunnel state, or a later probe must not rewrite
        // that binding unless the user explicitly imports a new pairing file.
        if existingMetadata?.status == .verified,
           let boundDeviceIdentifier = existingMetadata?.validatedDeviceIdentifier,
           boundDeviceIdentifier.isEmpty == false {
            if boundDeviceIdentifier.caseInsensitiveCompare(deviceIdentifier) != .orderedSame {
                throw Self.mismatchFailure(
                    fileUDID: boundDeviceIdentifier,
                    connectedUDID: deviceIdentifier
                )
            }
            return PairingRecord(
                deviceIdentifier: inspection.udid,
                isRemotePairing: inspection.isRemote,
                validationStatus: .verified,
                validatedDeviceIdentifier: boundDeviceIdentifier,
                validatedAt: existingMetadata?.validatedAt
            )
        }

        if let fileUDID = inspection.udid,
           fileUDID.caseInsensitiveCompare(deviceIdentifier) != .orderedSame {
            try saveMetadata(
                ValidationMetadata(
                    status: .deviceMismatch,
                    validatedDeviceIdentifier: nil,
                    validatedAt: Date()
                )
            )
            throw Self.mismatchFailure(fileUDID: fileUDID, connectedUDID: deviceIdentifier)
        }

        let metadata = ValidationMetadata(
            status: .verified,
            validatedDeviceIdentifier: deviceIdentifier,
            validatedAt: Date()
        )
        try saveMetadata(metadata)
        try discardBackup()
        return PairingRecord(
            deviceIdentifier: inspection.udid,
            isRemotePairing: inspection.isRemote,
            validationStatus: .verified,
            validatedDeviceIdentifier: deviceIdentifier,
            validatedAt: metadata.validatedAt
        )
    }

    func markValidating() throws -> PairingRecord {
        try updateValidationStatus(.validating)
    }

    func markPendingValidation() throws -> PairingRecord {
        try updateValidationStatus(.unverified)
    }

    private func updateValidationStatus(
        _ status: PairingValidationStatus
    ) throws -> PairingRecord {
        let dictionary = try dictionary()
        let inspection = try Self.inspect(dictionary)

        // Validating/pending are runtime states. They cannot downgrade a pairing
        // relationship that has already been proven for this app installation.
        if let existingMetadata = try? loadMetadata(),
           existingMetadata.status == .verified,
           let boundDeviceIdentifier = existingMetadata.validatedDeviceIdentifier,
           boundDeviceIdentifier.isEmpty == false {
            return PairingRecord(
                deviceIdentifier: inspection.udid,
                isRemotePairing: inspection.isRemote,
                validationStatus: .verified,
                validatedDeviceIdentifier: boundDeviceIdentifier,
                validatedAt: existingMetadata.validatedAt
            )
        }

        let metadata = ValidationMetadata(
            status: status,
            validatedDeviceIdentifier: nil,
            validatedAt: nil
        )
        try saveMetadata(metadata)
        return PairingRecord(
            deviceIdentifier: inspection.udid,
            isRemotePairing: inspection.isRemote,
            validationStatus: status
        )
    }

    func contents() throws -> String {
        let data = try Data(contentsOf: fileURL)
        // 先尝试直接 UTF-8 解码（XML plist / JSON 都是文本）
        if let string = String(data: data, encoding: .utf8) {
            return string
        }
        // 二进制 plist 需要转成 XML 文本后再返回给 minimuxer
        if let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ), let xmlData = try? PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        ), let string = String(data: xmlData, encoding: .utf8) {
            return string
        }
        throw Self.invalidFailure
    }

    func remove() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            try FileManager.default.removeItem(at: metadataURL)
        }
        try discardBackup()
    }

    func restoreBackupIfPresent() throws -> PairingRecord? {
        guard FileManager.default.fileExists(atPath: backupURL.path) else { return nil }
        let data = try Data(contentsOf: backupURL)
        try data.write(to: fileURL, options: .atomic)
        try fileProtector.protect(fileURL)

        if FileManager.default.fileExists(atPath: backupMetadataURL.path) {
            let metadataData = try Data(contentsOf: backupMetadataURL)
            try metadataData.write(to: metadataURL, options: .atomic)
            try fileProtector.protect(metadataURL)
        } else if FileManager.default.fileExists(atPath: metadataURL.path) {
            try FileManager.default.removeItem(at: metadataURL)
        }
        try discardBackup()
        return try current()
    }

    private func backupCurrentIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              FileManager.default.fileExists(atPath: backupURL.path) == false else { return }
        let data = try Data(contentsOf: fileURL)
        try data.write(to: backupURL, options: .atomic)
        try fileProtector.protect(backupURL)
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            let metadataData = try Data(contentsOf: metadataURL)
            try metadataData.write(to: backupMetadataURL, options: .atomic)
            try fileProtector.protect(backupMetadataURL)
        }
    }

    private func removeCurrentFilesAfterFailedInitialImport() throws {
        for url in [fileURL, metadataURL, backupURL, backupMetadataURL]
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func discardBackup() throws {
        for url in [backupURL, backupMetadataURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func dictionary() throws -> [String: Any] {
        let data = try Data(contentsOf: fileURL)
        return try Self.parseDictionary(from: data)
    }

    /// 解析配对文件数据，同时支持 plist（Lockdown）和 JSON（RemotePairing）格式。
    private static func parseDictionary(from data: Data) throws -> [String: Any] {
        // 先尝试 plist（XML / 二进制 / OpenStep）
        if let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ), let dictionary = plist as? [String: Any] {
            return dictionary
        }

        // 再尝试 JSON（iOS 17+ RemotePairing 通常为 JSON）
        if let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
           let dictionary = jsonObject as? [String: Any] {
            return dictionary
        }

        throw invalidFailure
    }

    private func loadMetadata() throws -> ValidationMetadata {
        let data = try Data(contentsOf: metadataURL)
        return try JSONDecoder().decode(ValidationMetadata.self, from: data)
    }

    private func saveMetadata(_ metadata: ValidationMetadata) throws {
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
        try fileProtector.protect(metadataURL)
    }

    private static func inspect(
        _ dictionary: [String: Any]
    ) throws -> (udid: String?, isRemote: Bool) {
        let udid = firstStringRecursive(
            in: dictionary,
            keys: [
                "UDID", "udid", "UniqueDeviceID", "device_identifier",
                "DeviceIdentifier", "unique_device_id", "deviceId",
                "DeviceID", "device_id", "UniqueDeviceIdentifier"
            ]
        )
        let hasRemotePrivateKey = containsDataOrStringRecursive(
            in: dictionary,
            keys: ["private_key", "privateKey", "PrivateKey", "Private Key"]
        )
        // RemotePairing 必须有 private_key；Lockdown 必须有 UDID。
        // 仅有 HostID/SystemBUID 等辅助字段不构成完整配对文件。
        guard hasRemotePrivateKey || udid?.isEmpty == false else {
            throw Self.invalidFailure
        }
        return (udid, hasRemotePrivateKey)
    }

    /// 检测配对文件类型。
    static func detectFileKind(_ dictionary: [String: Any]) -> PairingFileKind {
        let hasRemotePrivateKey = containsDataOrStringRecursive(
            in: dictionary,
            keys: ["private_key", "privateKey", "PrivateKey", "Private Key"]
        )
        if hasRemotePrivateKey {
            return .remote
        }
        let hasUDID = firstStringRecursive(
            in: dictionary,
            keys: ["UDID", "udid", "UniqueDeviceID", "device_identifier"]
        )?.isEmpty == false
        if hasUDID {
            return .lockdown
        }
        return .unknown
    }

    private static func firstStringRecursive(
        in dictionary: [String: Any],
        keys: [String]
    ) -> String? {
        // 先在当前层级查找
        if let value = firstString(in: dictionary, keys: keys) {
            return value
        }
        // 递归搜索嵌套字典（最多 3 层，避免无限递归）
        return firstStringRecursive(in: dictionary, keys: keys, depth: 0)
    }

    private static func firstStringRecursive(
        in dictionary: [String: Any],
        keys: [String],
        depth: Int
    ) -> String? {
        guard depth < 3 else { return nil }
        for (_, value) in dictionary {
            guard let nested = value as? [String: Any] else { continue }
            if let found = firstString(in: nested, keys: keys) {
                return found
            }
            if let found = firstStringRecursive(in: nested, keys: keys, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private static func containsDataOrStringRecursive(
        in dictionary: [String: Any],
        keys: [String]
    ) -> Bool {
        if containsDataOrString(in: dictionary, keys: keys) {
            return true
        }
        return containsDataOrStringRecursive(in: dictionary, keys: keys, depth: 0)
    }

    private static func containsDataOrStringRecursive(
        in dictionary: [String: Any],
        keys: [String],
        depth: Int
    ) -> Bool {
        guard depth < 3 else { return false }
        for (_, value) in dictionary {
            guard let nested = value as? [String: Any] else { continue }
            if containsDataOrString(in: nested, keys: keys) {
                return true
            }
            if containsDataOrStringRecursive(in: nested, keys: keys, depth: depth + 1) {
                return true
            }
        }
        return false
    }

    private static func firstString(
        in dictionary: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty == false { return trimmed }
            }
        }
        return nil
    }

    private static func containsDataOrString(
        in dictionary: [String: Any],
        keys: [String]
    ) -> Bool {
        keys.contains { key in
            if let data = dictionary[key] as? Data { return data.isEmpty == false }
            if let string = dictionary[key] as? String { return string.isEmpty == false }
            return false
        }
    }

    private static let invalidFailure = ImportFailure(
        title: "设备配对无效",
        reason: "Seal 无法读取当前设备配对信息。",
        recovery: "重新配对设备",
        code: "SEAL-PAIR-201"
    )

    private static func mismatchFailure(
        fileUDID: String,
        connectedUDID: String
    ) -> ImportFailure {
        ImportFailure(
            title: "设备配对不匹配",
            reason: "当前设备配对信息与连接的 iPhone 不匹配。",
            recovery: "重新配对当前 iPhone",
            code: "SEAL-PAIR-206a"
        )
    }
}
