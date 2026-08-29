import Foundation

struct SealRuntimeEntitlementReport: Equatable {
    let applicationIdentifier: String
    let teamIdentifier: String
    let networkExtensions: [String]
    let errorDescription: String?

    var hasPacketTunnelProvider: Bool {
        networkExtensions.contains("packet-tunnel-provider")
    }

    var networkExtensionDescription: String {
        networkExtensions.isEmpty
            ? "未发现 packet-tunnel-provider"
            : networkExtensions.joined(separator: ", ")
    }

    static func read() -> SealRuntimeEntitlementReport {
        do {
            let entitlements = try SignedExecutableEntitlements.readMainExecutable()
            return SealRuntimeEntitlementReport(
                applicationIdentifier: entitlements["application-identifier"] as? String ?? "未发现",
                teamIdentifier: entitlements["com.apple.developer.team-identifier"] as? String ?? "未发现",
                networkExtensions: stringArray(
                    entitlements["com.apple.developer.networking.networkextension"]
                ),
                errorDescription: nil
            )
        } catch {
            return SealRuntimeEntitlementReport(
                applicationIdentifier: "读取失败",
                teamIdentifier: "读取失败",
                networkExtensions: [],
                errorDescription: "无法读取已安装 Seal 的代码签名权限：\(error.localizedDescription)"
            )
        }
    }

    private static func stringArray(_ value: Any?) -> [String] {
        if let strings = value as? [String] {
            return strings
        }
        if let string = value as? String {
            return [string]
        }
        if let values = value as? [Any] {
            return values.compactMap { $0 as? String }
        }
        return []
    }
}

private enum SignedExecutableEntitlements {
    private static let mhMagic64: UInt32 = 0xFEEDFACF
    private static let lcCodeSignature: UInt32 = 0x1D

    private static let embeddedSignatureMagic: UInt32 = 0xFADE0CC0
    private static let embeddedEntitlementsMagic: UInt32 = 0xFADE7171
    private static let entitlementsSlot: UInt32 = 5

    enum ReaderError: LocalizedError {
        case executableURLUnavailable
        case truncatedMachO
        case unsupportedMachO(UInt32)
        case invalidLoadCommand
        case codeSignatureMissing
        case invalidCodeSignature
        case entitlementsMissing
        case entitlementsNotDictionary

        var errorDescription: String? {
            switch self {
            case .executableURLUnavailable:
                return "找不到当前 App 可执行文件。"
            case .truncatedMachO:
                return "当前 App 可执行文件的 Mach-O 数据不完整。"
            case .unsupportedMachO(let magic):
                return String(format: "暂不支持此 Mach-O 格式（magic 0x%08X）。", magic)
            case .invalidLoadCommand:
                return "Mach-O Load Command 数据无效。"
            case .codeSignatureMissing:
                return "当前可执行文件中没有 LC_CODE_SIGNATURE。"
            case .invalidCodeSignature:
                return "当前可执行文件的 Code Signature SuperBlob 无效。"
            case .entitlementsMissing:
                return "当前代码签名中没有 XML entitlements。"
            case .entitlementsNotDictionary:
                return "代码签名中的 entitlements 不是属性列表字典。"
            }
        }
    }

    static func readMainExecutable() throws -> [String: Any] {
        guard let executableURL = Bundle.main.executableURL else {
            throw ReaderError.executableURLUnavailable
        }

        let executable = try Data(contentsOf: executableURL, options: .mappedIfSafe)
        let signatureRange = try codeSignatureRange(in: executable)
        let signature = executable.subdata(in: signatureRange)
        return try entitlementsDictionary(in: signature)
    }

    private static func codeSignatureRange(in data: Data) throws -> Range<Int> {
        guard data.count >= 32 else {
            throw ReaderError.truncatedMachO
        }

        let magic = try uint32LittleEndian(data, at: 0)
        guard magic == mhMagic64 else {
            throw ReaderError.unsupportedMachO(magic)
        }

        let commandCount = Int(try uint32LittleEndian(data, at: 16))
        let commandBytes = Int(try uint32LittleEndian(data, at: 20))
        let commandsStart = 32
        let commandsEnd = commandsStart + commandBytes

        guard commandBytes >= 0, commandsEnd >= commandsStart, commandsEnd <= data.count else {
            throw ReaderError.truncatedMachO
        }

        var cursor = commandsStart

        for _ in 0..<commandCount {
            guard cursor + 8 <= commandsEnd else {
                throw ReaderError.invalidLoadCommand
            }

            let command = try uint32LittleEndian(data, at: cursor)
            let commandSize = Int(try uint32LittleEndian(data, at: cursor + 4))

            guard commandSize >= 8,
                  cursor + commandSize >= cursor,
                  cursor + commandSize <= commandsEnd else {
                throw ReaderError.invalidLoadCommand
            }

            if command == lcCodeSignature {
                guard commandSize >= 16 else {
                    throw ReaderError.invalidLoadCommand
                }

                let signatureOffset = Int(try uint32LittleEndian(data, at: cursor + 8))
                let signatureSize = Int(try uint32LittleEndian(data, at: cursor + 12))
                let signatureEnd = signatureOffset + signatureSize

                guard signatureOffset >= 0,
                      signatureSize > 0,
                      signatureEnd >= signatureOffset,
                      signatureEnd <= data.count else {
                    throw ReaderError.invalidCodeSignature
                }

                return signatureOffset..<signatureEnd
            }

            cursor += commandSize
        }

        throw ReaderError.codeSignatureMissing
    }

    private static func entitlementsDictionary(in signature: Data) throws -> [String: Any] {
        guard signature.count >= 12,
              try uint32BigEndian(signature, at: 0) == embeddedSignatureMagic else {
            throw ReaderError.invalidCodeSignature
        }

        let totalLength = Int(try uint32BigEndian(signature, at: 4))
        let blobCount = Int(try uint32BigEndian(signature, at: 8))

        guard totalLength >= 12,
              totalLength <= signature.count,
              blobCount >= 0,
              blobCount <= (totalLength - 12) / 8 else {
            throw ReaderError.invalidCodeSignature
        }

        for index in 0..<blobCount {
            let indexOffset = 12 + (index * 8)
            let slot = try uint32BigEndian(signature, at: indexOffset)
            let blobOffset = Int(try uint32BigEndian(signature, at: indexOffset + 4))

            guard blobOffset >= 0, blobOffset + 8 <= totalLength else {
                throw ReaderError.invalidCodeSignature
            }

            let blobMagic = try uint32BigEndian(signature, at: blobOffset)
            if slot == entitlementsSlot || blobMagic == embeddedEntitlementsMagic {
                guard blobMagic == embeddedEntitlementsMagic else {
                    continue
                }

                let blobLength = Int(try uint32BigEndian(signature, at: blobOffset + 4))
                let blobEnd = blobOffset + blobLength

                guard blobLength >= 8,
                      blobEnd >= blobOffset,
                      blobEnd <= totalLength else {
                    throw ReaderError.invalidCodeSignature
                }

                let payload = signature.subdata(in: (blobOffset + 8)..<blobEnd)
                let propertyList = try PropertyListSerialization.propertyList(
                    from: payload,
                    options: [],
                    format: nil
                )

                guard let dictionary = propertyList as? [String: Any] else {
                    throw ReaderError.entitlementsNotDictionary
                }
                return dictionary
            }
        }

        throw ReaderError.entitlementsMissing
    }

    private static func uint32LittleEndian(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw ReaderError.truncatedMachO
        }

        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func uint32BigEndian(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw ReaderError.invalidCodeSignature
        }

        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }
}
