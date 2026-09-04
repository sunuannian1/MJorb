import Foundation
import Testing
@testable import Seal

struct AppleAccountClientTests {
    @Test
    func masksEmailWithoutPersistingTheFullAddress() {
        #expect(AppleAccountClient.mask("seal.user@icloud.com") == "sea***er@icloud.com")
        #expect(AppleAccountClient.mask("developer@icloud.com") == "dev***er@icloud.com")
        #expect(AppleAccountClient.mask("13812345678") == "138****5678")
        #expect(AppleAccountClient.mask("+8613812345678") == "+86 138****5678")
        #expect(AppleAccountClient.mask("+14155552671") == "+1 415****2671")
        #expect(AppleAccountClient.mask("invalid") == "inv***id")
    }

    @Test
    func teamLookupFailureDoesNotExposeRawAppleTechnicalDetails() {
        let error = NSError(
            domain: "com.apple.authentication",
            code: -20101,
            userInfo: [NSLocalizedDescriptionKey: "Developer services are unavailable"]
        )

        let failure = AppleAuthenticationFailure.make(
            stage: .teamLookup,
            error: error
        )

        // teamLookup 失败细分为 SEAL-AUTH-105f（精确匹配策略层，团队查不到不要求重验凭据）
        #expect(failure.code == "SEAL-AUTH-105f")
        #expect(failure.reason.contains("-20101") == false)
        #expect(failure.reason.contains("Developer services are unavailable") == false)
        #expect(failure.reason.contains("开发团队"))
    }
}
