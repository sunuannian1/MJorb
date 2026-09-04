import Foundation
import Testing
@testable import Seal

struct SignedArtifactBundleIDReaderTests {
    private func data(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    private func plist(_ dictionary: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .binary,
            options: 0
        )
    }

    @Test
    func readsMainAppBundleIdentifier() throws {
        let url = try IPAArchiveFixture.make(apps: [
            IPAArchiveFixture.AppSpec(bundleIdentifier: "com.macxk.HDDJ.seal1")
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let identifier = SignedArtifactBundleIDReader.bundleIdentifier(in: try data(url))

        #expect(identifier == "com.macxk.HDDJ.seal1")
    }

    /// 非标准包（如黄豆短剧）会在 extension / framework 内携带多个同名 Info.plist，
    /// 必须只认恰好三段的 Payload/<App>.app/Info.plist，不能被内层 ID 污染。
    @Test
    func ignoresExtensionAndFrameworkInfoPlists() throws {
        let frameworkPlist = try plist([
            "CFBundleIdentifier": "com.macxk.HDDJ.Framework"
        ])
        let url = try IPAArchiveFixture.make(
            apps: [
                IPAArchiveFixture.AppSpec(bundleIdentifier: "com.macxk.HDDJ.seal1")
            ],
            includeShareExtension: true,
            extraEntries: [
                (
                    path: "Payload/Demo.app/Frameworks/Inner.framework/Info.plist",
                    data: frameworkPlist
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let identifier = SignedArtifactBundleIDReader.bundleIdentifier(in: try data(url))

        #expect(identifier == "com.macxk.HDDJ.seal1")
    }

    @Test
    func returnsNilWhenMainInfoPlistMissing() throws {
        let url = try IPAArchiveFixture.make(includeInfo: false)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let identifier = SignedArtifactBundleIDReader.bundleIdentifier(in: try data(url))

        #expect(identifier == nil)
    }

    @Test
    func returnsNilForMalformedPlist() throws {
        let url = try IPAArchiveFixture.make(apps: [
            IPAArchiveFixture.AppSpec(malformedInfo: true)
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let identifier = SignedArtifactBundleIDReader.bundleIdentifier(in: try data(url))

        #expect(identifier == nil)
    }

    @Test
    func returnsNilWhenAppDirectoryMissingAppSuffix() throws {
        let url = try IPAArchiveFixture.make(apps: [
            IPAArchiveFixture.AppSpec(
                directoryName: "PayloadFolder",
                bundleIdentifier: "com.example.wrong"
            )
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let identifier = SignedArtifactBundleIDReader.bundleIdentifier(in: try data(url))

        #expect(identifier == nil)
    }

    @Test
    func returnsNilForNonZipAndEmptyData() {
        #expect(SignedArtifactBundleIDReader.bundleIdentifier(in: Data("not-a-zip".utf8)) == nil)
        #expect(SignedArtifactBundleIDReader.bundleIdentifier(in: Data()) == nil)
    }
}
