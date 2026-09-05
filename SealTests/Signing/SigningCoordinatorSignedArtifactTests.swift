import Foundation
import Testing
import ZIPFoundation
@testable import Seal

struct SigningCoordinatorSignedArtifactTests {
    @Test
    func installsPersistedSignedArtifactWithoutRunningSigningAgain() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let appID = UUID()
        let source = environment.root.appending(path: "AlreadySigned.ipa")
        try Self.makeMinimalValidIPA(
            at: source,
            bundleID: "com.example.demo.seal",
            executableName: "Demo"
        )
        let signedPath = try await environment.fileStore.storeSignedIPA(sourceURL: source, appID: appID)
        let sha = try await environment.fileStore.sha256(relativePath: signedPath)
        let expiration = Date().addingTimeInterval(3 * 86_400)
        let app = AppRecord(
            id: appID,
            originalBundleIdentifier: "com.example.demo",
            mappedBundleIdentifier: "com.example.demo.seal",
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 18,
            state: .signed,
            signedDeviceIdentifier: "DEVICE-1",
            provisioningProfileExpirationDate: expiration,
            ipaRelativePath: "Apps/\(appID.uuidString)/Original.ipa",
            signedIPARelativePath: signedPath,
            signedIPASHA256: sha,
            signedArtifactStatus: .available,
            preferredBundleIdentifier: "com.example.demo.seal",
            importedAt: Date()
        )
        try await environment.appStore.save(app)

        let coordinator = SigningCoordinator(
            appStore: environment.appStore,
            accountRepository: environment.accountRepository,
            keychain: KeychainVault(),
            fileStore: environment.fileStore,
            installChannel: environment.installChannel
        )
        let result = try await coordinator.installSignedArtifact(appID: appID) { _ in }

        #expect(result.state == .installed)
        #expect(result.signedArtifactStatus == .installed)
        #expect(result.mappedBundleIdentifier == "com.example.demo.seal")
        #expect(await environment.installChannel.installCount == 1)
        #expect(await environment.installChannel.verifyCount == 1)
    }

    @Test
    func missingSignedFileIsKeptAsRecordAndMarkedMissing() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let appID = UUID()
        let app = AppRecord(
            id: appID,
            originalBundleIdentifier: "com.example.demo",
            mappedBundleIdentifier: "com.example.demo.seal",
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 18,
            state: .signed,
            signedDeviceIdentifier: "DEVICE-1",
            provisioningProfileExpirationDate: Date().addingTimeInterval(86_400),
            ipaRelativePath: "Apps/\(appID.uuidString)/Original.ipa",
            signedIPARelativePath: "Apps/\(appID.uuidString)/Signed.ipa",
            signedIPASHA256: String(repeating: "a", count: 64),
            signedArtifactStatus: .available,
            preferredBundleIdentifier: "com.example.demo.seal",
            importedAt: Date()
        )
        try await environment.appStore.save(app)
        let coordinator = SigningCoordinator(
            appStore: environment.appStore,
            accountRepository: environment.accountRepository,
            keychain: KeychainVault(),
            fileStore: environment.fileStore,
            installChannel: environment.installChannel
        )

        do {
            _ = try await coordinator.installSignedArtifact(appID: appID) { _ in }
            Issue.record("Expected missing signed artifact failure")
        } catch let failure as ImportFailure {
            #expect(failure.code == "SEAL-INSTALL-711")
        }
        let records = try await environment.appStore.fetchAll()
        let stored = try #require(records.first { $0.id == appID })
        #expect(stored.state == .signed)
        #expect(stored.signedArtifactStatus == .missing)
    }

    private func makeEnvironment() throws -> Environment {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "SealSignedArtifactTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        let cache = root.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let appStore = try CoreDataAppStore(inMemory: true)
        let accountRepository = ProtectedAccountRepository(
            fileURL: root.appending(path: "Accounts.json"),
            fileProtector: MarkerFileProtector()
        )
        return Environment(
            root: root,
            fileStore: AppFileStore(documentsDirectory: documents, cacheDirectory: cache),
            appStore: appStore,
            accountRepository: accountRepository,
            installChannel: SignedArtifactInstallChannel()
        )
    }
}

private extension SigningCoordinatorSignedArtifactTests {
    struct Environment {
        let root: URL
        let fileStore: AppFileStore
        let appStore: CoreDataAppStore
        let accountRepository: ProtectedAccountRepository
        let installChannel: SignedArtifactInstallChannel
    }
}

private actor SignedArtifactInstallChannel: InstallChannel {
    private(set) var installCount = 0
    private(set) var verifyCount = 0
    private(set) var pushCount = 0
    private(set) var pushedInstallCount = 0

    func start() async throws -> String { "DEVICE-1" }
    func diagnose() async -> InstallChannelDiagnostics { .empty }
    func isReady() async -> Bool { true }
    func pushIpa(ipaData: Data, bundleID: String) async throws {
        pushCount += 1
    }
    func installPushedIpa(bundleID: String, isSelfReplacement: Bool) async throws {
        pushedInstallCount += 1
    }
    func install(ipaData: Data, bundleID: String, isSelfReplacement: Bool) async throws {
        installCount += 1
    }
    func verifyInstalled(bundleID: String) async throws {
        verifyCount += 1
    }
}

private extension SigningCoordinatorSignedArtifactTests {
    /// 创建一个结构完整的最小有效 IPA（通过 SignedArtifactValidator 的所有检查）。
    static func makeMinimalValidIPA(
        at url: URL,
        bundleID: String,
        executableName: String
    ) throws {
        guard let archive = Archive(url: url, accessMode: .create) else {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot create ZIP"])
        }

        func addData(_ data: Data, _ path: String) throws {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: UInt32(data.count),
                provider: { (pos: Int, size: Int) in
                    data.subdata(in: pos..<(pos + size))
                }
            )
        }

        // Info.plist
        let infoPlist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": executableName,
            "CFBundleName": "Demo"
        ]
        let infoPlistData = try PropertyListSerialization.data(
            fromPropertyList: infoPlist,
            format: .xml,
            options: 0
        )
        try addData(infoPlistData, "Payload/Demo.app/Info.plist")

        // embedded.mobileprovision（模拟，内容不校验）
        try addData(Data("mock-mobileprovision".utf8), "Payload/Demo.app/embedded.mobileprovision")

        // 主可执行文件（空文件即可，验证器只检查存在性）
        try archive.addEntry(
            with: "Payload/Demo.app/\(executableName)",
            type: .file,
            uncompressedSize: UInt32(0),
            provider: { (_: Int, _: Int) in Data() }
        )
    }
}
