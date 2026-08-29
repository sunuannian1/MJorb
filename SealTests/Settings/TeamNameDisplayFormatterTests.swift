import Testing
@testable import Seal

struct TeamNameDisplayFormatterTests {
    @Test
    func displaysChinesePersonalTeamInLocalNameOrder() {
        #expect(TeamNameDisplayFormatter.string(from: "年年 苏") == "苏 年年")
    }

    @Test
    func keepsNonChineseTeamNamesUnchanged() {
        #expect(TeamNameDisplayFormatter.string(from: "John Smith") == "John Smith")
        #expect(TeamNameDisplayFormatter.string(from: "Example LLC") == "Example LLC")
    }
}
