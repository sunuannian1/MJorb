import Foundation
import Testing
@testable import Seal

struct PairingStoreTests {
    @Test
    func importsValidatesProtectsAndRemovesStandardPairingFile() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "Source.plist")
        let destination = root.appending(path: "Stored/Pairing.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: standardPairingDictionary(udid: "device-123"),
            format: .binary,
            options: 0
        )
        try data.write(to: source)
        let store = PairingStore(
            fileURL: destination,
            fileProtector: MarkerFileProtector()
        )

        let imported = try await store.importFile(at: source)
        #expect(imported.deviceIdentifier == "device-123")
        #expect(imported.isRemotePairing == false)
        #expect(imported.validationStatus == .unverified)

        let validated = try await store.markValidated(deviceIdentifier: "device-123")
        #expect(validated.isVerifiedForCurrentDevice)
        #expect(validated.validatedDeviceIdentifier == "device-123")
        #expect(try await store.current() == validated)
        #expect(try await store.contents().contains("device-123"))
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathExtension("protected").path
        ))

        try await store.remove()
        #expect(try await store.current() == nil)
    }

    @Test
    func verifiedPairingSurvivesTransientRuntimeStatusChanges() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "Source.plist")
        let destination = root.appending(path: "Stored/Pairing.plist")
        try PropertyListSerialization.data(
            fromPropertyList: standardPairingDictionary(udid: "device-123"),
            format: .xml,
            options: 0
        ).write(to: source)

        let store = PairingStore(fileURL: destination)
        _ = try await store.importFile(at: source)
        let validated = try await store.markValidated(deviceIdentifier: "device-123")

        let validating = try await store.markValidating()
        #expect(validating == validated)

        let pending = try await store.markPendingValidation()
        #expect(pending == validated)
        #expect(try await store.current() == validated)
    }

    @Test
    func verifiedPairingRejectsDifferentRuntimeDeviceWithoutLosingBinding() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "Source.plist")
        let destination = root.appending(path: "Stored/Pairing.plist")
        try PropertyListSerialization.data(
            fromPropertyList: standardPairingDictionary(udid: "device-A"),
            format: .xml,
            options: 0
        ).write(to: source)

        let store = PairingStore(fileURL: destination)
        _ = try await store.importFile(at: source)
        _ = try await store.markValidated(deviceIdentifier: "device-A")

        await #expect(throws: ImportFailure.self) {
            try await store.markValidated(deviceIdentifier: "device-B")
        }

        let current = try await store.current()
        #expect(current?.validationStatus == .verified)
        #expect(current?.effectiveDeviceIdentifier == "device-A")
    }

    @Test
    func reimportResetsPreviouslyVerifiedPairingMetadata() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let sourceA = root.appending(path: "Source-A.plist")
        let sourceB = root.appending(path: "Source-B.plist")
        let destination = root.appending(path: "Stored/Pairing.plist")

        try PropertyListSerialization.data(
            fromPropertyList: standardPairingDictionary(udid: "device-A"),
            format: .xml,
            options: 0
        ).write(to: sourceA)
        try PropertyListSerialization.data(
            fromPropertyList: standardPairingDictionary(udid: "device-B"),
            format: .xml,
            options: 0
        ).write(to: sourceB)

        let store = PairingStore(fileURL: destination)
        _ = try await store.importFile(at: sourceA)
        _ = try await store.markValidated(deviceIdentifier: "device-A")
        #expect(try await store.current()?.validationStatus == .verified)

        let replacement = try await store.importFile(at: sourceB)
        #expect(replacement.deviceIdentifier == "device-B")
        #expect(replacement.validationStatus == .unverified)
        #expect(replacement.validatedDeviceIdentifier == nil)
        #expect(replacement.validatedAt == nil)

        let current = try await store.current()
        #expect(current?.deviceIdentifier == "device-B")
        #expect(current?.validationStatus == .unverified)
        #expect(current?.validatedDeviceIdentifier == nil)
        #expect(current?.validatedAt == nil)
    }

    @Test
    func importsRemotePairingWithPrivateKeyOnly() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "Remote.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["private_key": Data([1, 2, 3])],
            format: .xml,
            options: 0
        )
        try data.write(to: source)
        let store = PairingStore(fileURL: root.appending(path: "Pairing.plist"))

        let imported = try await store.importFile(at: source)
        #expect(imported.deviceIdentifier == nil)
        #expect(imported.isRemotePairing == true)
        #expect(imported.validationStatus == .unverified)
    }

    @Test
    func importsUDIDOnlyPairingForRuntimeValidation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "UDIDOnly.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["UDID": "device-123", "HostID": "host"],
            format: .xml,
            options: 0
        )
        try data.write(to: source)
        let store = PairingStore(fileURL: root.appending(path: "Pairing.plist"))

        let imported = try await store.importFile(at: source)
        #expect(imported.deviceIdentifier == "device-123")
        #expect(imported.isRemotePairing == false)
    }

    @Test
    func rejectsPairingFileForAnotherConnectedDevice() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "Source.plist")
        let destination = root.appending(path: "Pairing.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: standardPairingDictionary(udid: "device-A"),
            format: .xml,
            options: 0
        )
        try data.write(to: source)
        let store = PairingStore(fileURL: destination)
        _ = try await store.importFile(at: source)

        await #expect(throws: ImportFailure.self) {
            try await store.markValidated(deviceIdentifier: "device-B")
        }
        let current = try await store.current()
        #expect(current?.validationStatus == .deviceMismatch)
        #expect(current?.validatedDeviceIdentifier == nil)
        #expect(current?.effectiveDeviceIdentifier == "device-A")
    }

    @Test
    func rejectsPairingFileWithoutUDIDOrPrivateKey() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "Invalid.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["HostID": "host"],
            format: .xml,
            options: 0
        )
        try data.write(to: source)
        let store = PairingStore(fileURL: root.appending(path: "Pairing.plist"))

        await #expect(throws: ImportFailure.self) {
            try await store.importFile(at: source)
        }
    }

    @Test
    func rejectsOversizedPairingFile() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "Oversized.plist")
        try Data(repeating: 0, count: 5 * 1_024 * 1_024 + 1).write(to: source)
        let store = PairingStore(fileURL: root.appending(path: "Pairing.plist"))

        await #expect(throws: ImportFailure.self) {
            try await store.importFile(at: source)
        }
    }

    @Test
    func normalizesNestedBase64RemotePairingIntoCanonicalKeys() throws {
        let publicKey = Data((0..<32).map(UInt8.init))
        let privateKey = Data(repeating: 0xAB, count: 32)
        // 模拟 SideStore/Feather 一类来源：驼峰键名、嵌套、base64 字符串。
        let raw: [String: Any] = [
            "wrapping": [
                "publicKey": publicKey.base64EncodedString(),
                "privateKey": privateKey.base64EncodedString()
            ],
            "Identifier": "host-uuid-xyz"
        ]

        let normalized = try #require(
            PairingStore.normalizedRemotePairingDictionary(raw)
        )
        #expect(Set(normalized.keys) == ["public_key", "private_key", "identifier"])
        #expect(normalized["public_key"] as? Data == publicKey)
        #expect(normalized["private_key"] as? Data == privateKey)
        #expect(normalized["identifier"] as? String == "host-uuid-xyz")
    }

    @Test
    func coercesHexKeysAndRejectsMalformedOrIncompleteRemotePairing() {
        let privateKey = Data(repeating: 0xCD, count: 32)
        let hex = privateKey.map { String(format: "%02x", $0) }.joined()
        #expect(PairingStore.coerceKeyData(hex) == privateKey)
        // 20 字节的 base64 不满足 32 字节契约，应判为无效。
        let shortBase64 = Data(repeating: 1, count: 20).base64EncodedString()
        #expect(PairingStore.coerceKeyData(shortBase64) == nil)
        // 缺 identifier 不构成完整远程配对。
        let incomplete: [String: Any] = [
            "public_key": Data(repeating: 2, count: 32),
            "private_key": Data(repeating: 3, count: 32)
        ]
        #expect(PairingStore.normalizedRemotePairingDictionary(incomplete) == nil)
    }

    @Test
    func importedJsonRemotePairingIsStoredAsCanonicalTopLevelData() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "Remote.json")
        let publicKey = Data((10..<42).map(UInt8.init))
        let privateKey = Data(repeating: 0x7F, count: 32)
        let json = try JSONSerialization.data(withJSONObject: [
            "public_key": publicKey.base64EncodedString(),
            "private_key": privateKey.base64EncodedString(),
            "identifier": "json-host-id"
        ])
        try json.write(to: source)
        let store = PairingStore(fileURL: root.appending(path: "Pairing.plist"))

        let imported = try await store.importFile(at: source)
        #expect(imported.isRemotePairing == true)

        let storedText = try await store.contents()
        let plist = try PropertyListSerialization.propertyList(
            from: Data(storedText.utf8),
            options: [],
            format: nil
        ) as? [String: Any]
        #expect(plist?["public_key"] as? Data == publicKey)
        #expect((plist?["private_key"] as? Data)?.count == 32)
        #expect(plist?["identifier"] as? String == "json-host-id")
    }

    private func standardPairingDictionary(udid: String) -> [String: Any] {
        [
            "UDID": udid,
            "HostID": "host-id",
            "SystemBUID": "system-buid",
            "HostCertificate": Data([1, 2, 3]),
            "HostPrivateKey": Data([4, 5, 6]),
            "RootCertificate": Data([7, 8, 9]),
            "RootPrivateKey": Data([10, 11, 12])
        ]
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "SealPairingTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }
}
