import Foundation
import Testing
@testable import Compositor

/// Every tool explains itself when the pointer rests on it in the tool rail.
struct ToolHelpTests {
    @Test func everyToolHasATooltipThatExplainsIt() {
        for tool in NavigationTool.allCases {
            #expect(!tool.help.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(tool) has no tooltip")
            #expect(tool.help.contains(" — "), "\(tool)'s tooltip should read \"Name (key) — what it does\"")
        }
    }

    @Test func aToolsTooltipStartsWithItsRailName() {
        for tool in NavigationTool.allCases where tool != .idle {
            let name = tool.label.components(separatedBy: " · ")[0]
            #expect(tool.help.hasPrefix(name), "\(tool)'s tooltip should start with \"\(name)\"")
        }
    }
}
