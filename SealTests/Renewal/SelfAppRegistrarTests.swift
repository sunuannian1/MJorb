import Foundation
import Testing
@testable import Seal

struct SelfAppRegistrarTests {
    @Test
    func preservesTheFirstOriginalBundleIdentifierAcrossSelfUpdates() {
        #expect(
            SelfAppBundleIdentity.originalBundleIdentifier(
                currentBundleIdentifier: "com.mjorb.seal.apps.renewed",
                declaredOriginalBundleIdentifier: "com.mjorb.seal",
                existingOriginalBundleIdentifier: "com.mjorb.seal"
            ) == "com.mjorb.seal"
        )
    }

    @Test
    func usesEmbeddedOriginalBundleIdentifierAfterTheAppContainerChanges() {
        #expect(
            SelfAppBundleIdentity.originalBundleIdentifier(
                currentBundleIdentifier: "com.mjorb.seal.apps.renewed",
                declaredOriginalBundleIdentifier: "com.mjorb.seal",
                existingOriginalBundleIdentifier: nil
            ) == "com.mjorb.seal"
        )
    }

    @Test
    func usesTheCurrentIdentifierOnlyForFirstRegistration() {
        #expect(
            SelfAppBundleIdentity.originalBundleIdentifier(
                currentBundleIdentifier: "com.mjorb.seal",
                declaredOriginalBundleIdentifier: nil,
                existingOriginalBundleIdentifier: nil
            ) == "com.mjorb.seal"
        )
    }

    @Test
    func matchesTheInstalledProfileTeamToTheStoredAccount() {
        let expectedID = UUID()
        let accounts = [
            AppleAccountRecord(
                maskedEmail: "other@icloud.com",
                accountIdentifier: "other",
                teamID: "OTHERTEAM",
                teamName: "Other",
                lastVerifiedAt: .distantPast
            ),
            AppleAccountRecord(
                id: expectedID,
                maskedEmail: "sunuannian1@gmail.com",
                accountIdentifier: "current",
                teamID: "T3432ZHJUF9",
                teamName: "Current",
                lastVerifiedAt: .now
            )
        ]

        #expect(
            SelfAppAccountBinding.matchedAccountID(
                teamIdentifier: "t3432zhjuf9",
                accounts: accounts
            ) == expectedID
        )
    }

    @Test
    func profileTeamWithoutSavedMatchDoesNotReuseStaleAccount() {
        let staleAccountID = UUID()

        #expect(
            SelfAppAccountBinding.resolvedAccountID(
                teamIdentifier: "CURRENTTEAM",
                accounts: [],
                fallbackAccountID: staleAccountID
            ) == nil
        )
    }

    @Test
    func missingProfileTeamFallsBackToStoredAccount() {
        let storedAccountID = UUID()

        #expect(
            SelfAppAccountBinding.resolvedAccountID(
                teamIdentifier: nil,
                accounts: [],
                fallbackAccountID: storedAccountID
            ) == storedAccountID
        )
    }

    @Test
    func doesNotReuseAnUnrelatedLegacySealRecord() {
        let stale = AppRecord(
            originalBundleIdentifier: "com.mjorb.seal",
            mappedBundleIdentifier: "com.mjorb.seal.dmj",
            name: "Seal",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            accountID: UUID(),
            ipaRelativePath: "Apps/stale.ipa",
            preferredBundleIdentifier: "com.mjorb.seal.dmj",
            isSeal: true,
            importedAt: .distantPast
        )

        #expect(
            SelfAppRecordSelection.preferredExistingSealRecord(
                in: [stale],
                currentBundleIdentifier: "com.mjorb.seal.t3432zhjuf9"
            ) == nil
        )
    }

    @Test
    func originalIdentifierDoesNotOverrideAStaleInstalledIdentifier() {
        let stale = AppRecord(
            originalBundleIdentifier: "com.mjorb.seal",
            mappedBundleIdentifier: "com.mjorb.seal.dmj",
            name: "Seal",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            accountID: UUID(),
            ipaRelativePath: "Apps/stale.ipa",
            preferredBundleIdentifier: "com.mjorb.seal.dmj",
            isSeal: true,
            importedAt: .distantPast
        )

        #expect(
            SelfAppRecordSelection.preferredExistingSealRecord(
                in: [stale],
                currentBundleIdentifier: "com.mjorb.seal"
            ) == nil
        )
    }

    @Test
    func reusesTheRecordThatMatchesTheCurrentInstalledBundleIdentifier() {
        let matching = AppRecord(
            originalBundleIdentifier: "com.mjorb.seal",
            mappedBundleIdentifier: "com.mjorb.seal.t3432zhjuf9",
            name: "Seal",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            accountID: UUID(),
            ipaRelativePath: "Apps/current.ipa",
            preferredBundleIdentifier: "com.mjorb.seal.t3432zhjuf9",
            isSeal: true,
            importedAt: .now
        )

        #expect(
            SelfAppRecordSelection.preferredExistingSealRecord(
                in: [matching],
                currentBundleIdentifier: "com.mjorb.seal.t3432zhjuf9"
            )?.id == matching.id
        )
    }

    @Test
    func doesNotOverwriteAnImportedSealUpdateSourceDuringStartupSync() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SealSelfRegistrar-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        let cache = root.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let appStore = try CoreDataAppStore(inMemory: true)
        let fileStore = AppFileStore(documentsDirectory: documents, cacheDirectory: cache)
        let sealID = UUID()
        let importedPath = "Apps/\(sealID.uuidString)/Original.ipa"
        let importedURL = documents.appending(path: importedPath)
        try FileManager.default.createDirectory(
            at: importedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("imported-seal-update".utf8).write(to: importedURL)
        let pendingUpdate = AppRecord(
            id: sealID,
            originalBundleIdentifier: "com.mjorb.seal",
            mappedBundleIdentifier: "com.mjorb.seal.3432ZHJUF9",
            name: "Seal",
            version: "2.0",
            buildNumber: "82",
            size: 100,
            state: .installed,
            accountID: UUID(),
            ipaRelativePath: importedPath,
            preferredBundleIdentifier: "com.mjorb.seal.3432ZHJUF9",
            hasPendingSelfUpdateSource: true,
            isSeal: true,
            isPinned: true,
            importedAt: .distantPast
        )
        try await appStore.save(pendingUpdate)
        let currentBundle = root.appending(path: "CurrentSeal.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: currentBundle, withIntermediateDirectories: true)
        let registrar = SelfAppRegistrar(
            metadata: SelfAppMetadata(
                bundleURL: currentBundle,
                bundleIdentifier: "com.mjorb.seal.3432ZHJUF9",
                originalBundleIdentifier: "com.mjorb.seal",
                name: "Seal",
                version: "1.0",
                buildNumber: "1",
                iconData: nil,
                expirationDate: nil,
                signingTeamIdentifier: nil,
                signingApplicationIdentifier: nil
            ),
            appStore: appStore,
            accountRepository: EmptyAccountRepository(),
            fileStore: fileStore
        )

        try await registrar.ensureRegistered()

        let records = try await appStore.fetchAll()
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.id == sealID)
        #expect(record.version == "2.0")
        #expect(record.hasPendingSelfUpdateSource)
        #expect(try Data(contentsOf: importedURL) == Data("imported-seal-update".utf8))
    }
}

private actor EmptyAccountRepository: AccountRepository {
    func fetchAll() throws -> [AppleAccountRecord] { [] }
    func save(_ account: AppleAccountRecord) throws {}
    func delete(id: UUID) throws {}
}
