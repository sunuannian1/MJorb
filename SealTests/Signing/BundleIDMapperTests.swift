import Foundation
import Testing
@testable import Seal

struct BundleIDMapperTests {
    @Test
    func mainBundleIdentifierUsesStableSealTeamSuffix() {
        let mapper = BundleIDMapper()
        let first = mapper.mainBundleID(original: "com.example.demo", teamID: "TEAM1")
        let sameTeam = mapper.mainBundleID(original: "com.example.demo", teamID: "TEAM1")
        let otherTeam = mapper.mainBundleID(original: "com.example.demo", teamID: "TEAM2")
        let appExtension = mapper.extensionBundleID(
            original: "com.example.demo.share",
            originalMainBundleID: "com.example.demo",
            mappedMainBundleID: first
        )
        let appGroup = mapper.appGroupID(
            original: "group.com.example.demo",
            teamID: "TEAM1"
        )

        // 新格式：原始.seal.teamID（对齐 AltStore）；同 app+同 team 恒定不随机，不同 team 相互隔离
        #expect(first == "com.example.demo.seal.TEAM1")
        #expect(first == sameTeam)
        #expect(otherTeam == "com.example.demo.seal.TEAM2")
        #expect(first != otherTeam)
        #expect(appExtension == "com.example.demo.seal.TEAM1.share")
        #expect(appGroup == "group.com.example.demo.seal.TEAM1")
        #expect(appGroup == mapper.appGroupID(
            original: "group.com.example.demo",
            teamID: "TEAM1"
        ))
    }

    @Test
    func requestedMainBundleIdentifierWins() {
        let mapper = BundleIDMapper()
        #expect(
            mapper.mainBundleID(
                original: "com.example.demo",
                teamID: "TEAM1",
                requested: "com.example.demo.custom"
            ) == "com.example.demo.custom"
        )
    }

    @Test
    func policyIgnoresRequestedBundleIdentifierForRenewal() throws {
        let installed = AppRecord(
            originalBundleIdentifier: "com.example.demo",
            mappedBundleIdentifier: "com.example.demo.seal",
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            ipaRelativePath: "Apps/demo.ipa",
            importedAt: Date()
        )

        #expect(
            try BundleIDPolicy.targetBundleIdentifier(
                for: installed,
                requestedBundleIdentifier: "com.example.demo.other"
            ) == "com.example.demo.seal"
        )
    }

    @Test
    func policyUsesMappedBundleIdentifierForInstalledRenewal() throws {
        var installed = AppRecord(
            originalBundleIdentifier: "com.example.demo",
            mappedBundleIdentifier: "com.example.demo.seal",
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            ipaRelativePath: "Apps/demo.ipa",
            importedAt: Date()
        )
        installed.preferredBundleIdentifier = "com.example.demo.old"

        #expect(try BundleIDPolicy.targetBundleIdentifier(for: installed) == "com.example.demo.seal")
    }

    @Test
    func policyRejectsInstalledRenewalWithoutSignedBundleIdentifier() throws {
        let installed = AppRecord(
            originalBundleIdentifier: "com.example.demo",
            mappedBundleIdentifier: nil,
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            ipaRelativePath: "Apps/demo.ipa",
            importedAt: Date()
        )

        #expect(throws: ImportFailure.self) {
            try BundleIDPolicy.targetBundleIdentifier(for: installed)
        }
    }

    @Test
    func policyIgnoresRequestedBundleIdentifierForSealPackage() throws {
        let seal = AppRecord(
            originalBundleIdentifier: "com.mjorb.seal",
            mappedBundleIdentifier: "com.mjorb.seal.current",
            name: "Seal",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            ipaRelativePath: "Apps/seal.ipa",
            isSeal: true,
            importedAt: Date()
        )

        #expect(
            try BundleIDPolicy.targetBundleIdentifier(
                for: seal,
                requestedBundleIdentifier: "com.mjorb.seal.seal",
                currentSealBundleIdentifier: "com.mjorb.seal"
            ) == "com.mjorb.seal.current"
        )
    }

    @Test
    func recommendedBundleIdentifierDoesNotDoubleAppendSealCaseInsensitively() {
        // 带 teamID 版本负责追加 .seal.teamID；输入已带 .seal（大小写不敏感）时先剥离再追加，不重复
        #expect(BundleIDPolicy.recommendedBundleIdentifier(for: "com.example.demo", teamID: "T") == "com.example.demo.seal.T")
        #expect(BundleIDPolicy.recommendedBundleIdentifier(for: "com.example.demo.seal", teamID: "T") == "com.example.demo.seal.T")
        #expect(BundleIDPolicy.recommendedBundleIdentifier(for: "com.example.demo.SEAL", teamID: "T") == "com.example.demo.seal.T")
        // 无 teamID 重载仅用于无账号上下文的兜底，原样返回 trim 后的原始值，不追加后缀
        #expect(BundleIDPolicy.recommendedBundleIdentifier(for: "com.example.demo") == "com.example.demo")
    }

    @Test
    func extensionMappingPreservesRelativeSuffix() {
        let mapper = BundleIDMapper()
        #expect(
            mapper.extensionBundleID(
                original: "com.example.app.widget",
                originalMainBundleID: "com.example.app",
                mappedMainBundleID: "com.example.app.seal"
            ) == "com.example.app.seal.widget"
        )
        #expect(
            mapper.extensionBundleID(
                original: "com.example.app.share",
                originalMainBundleID: "com.example.app",
                mappedMainBundleID: "com.example.custom"
            ) == "com.example.custom.share"
        )
    }

    @Test
    func bundleIdentifierValidationCoversFinalRules() {
        #expect(BundleIDPolicy.validationError(for: "") != nil)
        #expect(BundleIDPolicy.validationError(for: "single") != nil)
        #expect(BundleIDPolicy.validationError(for: ".com.example") != nil)
        #expect(BundleIDPolicy.validationError(for: "com..example") != nil)
        #expect(BundleIDPolicy.validationError(for: "com.-example") != nil)
        #expect(BundleIDPolicy.validationError(for: "com.example-") != nil)
        #expect(BundleIDPolicy.validationError(for: "com.example_app") != nil)
        #expect(BundleIDPolicy.validationError(for: "com.example-app") == nil)
    }

}
