import Foundation
import Testing
@testable import Seal

struct SigningWorkspaceTests {
    @Test
    func safelyRemapsMainAndExtensionThenPackagesIPA() throws {
        let source = try IPAArchiveFixture.make(includeShareExtension: true)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let root = FileManager.default.temporaryDirectory.appending(
            path: "SealSigningTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SigningWorkspace()
        let prepared = try workspace.prepare(
            ipaURL: source,
            workspaceRoot: root.appending(path: "Work"),
            originalBundleID: "com.example.demo",
            teamID: "TEAMID"
        )
        let output = root.appending(path: "Signed.ipa")

        try workspace.package(prepared, outputURL: output)
        let parsed = try IPAParserService().parse(url: output)

        #expect(parsed.bundleIdentifier == prepared.mappedMainBundleID)
        #expect(parsed.extensions.first?.originalBundleIdentifier ==
            prepared.bundleIDMappings["com.example.demo.share"])
    }
    @Test
    func appliesCustomDisplayNameAndPrimaryIconToPackagedApp() throws {
        let source = try IPAArchiveFixture.make()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let root = FileManager.default.temporaryDirectory.appending(
            path: "SealCustomSigningTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let iconData = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII="
        ))
        let workspace = SigningWorkspace()
        let prepared = try workspace.prepare(
            ipaURL: source,
            workspaceRoot: root.appending(path: "Work"),
            originalBundleID: "com.example.demo",
            teamID: "TEAMID",
            preferredDisplayName: "Demo Custom",
            preferredIconData: iconData
        )

        let infoData = try Data(contentsOf: prepared.appURL.appending(path: "Info.plist"))
        let info = try #require(try PropertyListSerialization.propertyList(
            from: infoData,
            options: [],
            format: nil
        ) as? [String: Any])
        #expect(info["CFBundleDisplayName"] as? String == "Demo Custom")
        #expect(info["CFBundleName"] as? String == "Demo Custom")
        #expect(FileManager.default.fileExists(atPath: prepared.appURL.appending(path: "SealCustomIcon60@3x.png").path))

        let output = root.appending(path: "Signed.ipa")
        try workspace.package(prepared, outputURL: output)
        let parsed = try IPAParserService().parse(url: output)
        #expect(parsed.name == "Demo Custom")
    }

    @Test
    func removesThirdPartySigningResidueButKeepsOrdinaryFiles() throws {
        let source = try IPAArchiveFixture.make(extraEntries: [
            (path: "Payload/Demo.app/lzlukvca_inject.js", data: Data("inject".utf8)),
            (path: "Payload/Demo.app/SignedByEsign", data: Data("mark".utf8)),
            (path: "Payload/Demo.app/normal.json", data: Data("{}".utf8))
        ])
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let root = FileManager.default.temporaryDirectory.appending(
            path: "SealResidueTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let prepared = try SigningWorkspace().prepare(
            ipaURL: source,
            workspaceRoot: root.appending(path: "Work"),
            originalBundleID: "com.example.demo",
            teamID: "TEAMID"
        )

        // ESign 注入脚本与签名标记必须在重签前清除
        #expect(FileManager.default.fileExists(
            atPath: prepared.appURL.appending(path: "lzlukvca_inject.js").path) == false)
        #expect(FileManager.default.fileExists(
            atPath: prepared.appURL.appending(path: "SignedByEsign").path) == false)
        // 普通资源不得被误伤
        #expect(FileManager.default.fileExists(
            atPath: prepared.appURL.appending(path: "normal.json").path))
    }
}
