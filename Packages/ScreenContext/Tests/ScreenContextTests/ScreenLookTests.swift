import Core
import Testing
@testable import ScreenContext

@Suite struct ScreenLookTests {

    @Test func composeRedactsLabelsAndClassifies() throws {
        let fragments = [
            frag("let key = \"sk-ant-api03-abcdefghijklmnopqrstuvwxyz\"", x: 0, y: 0),
            frag("func load() -> Data {", x: 0, y: 30),
            frag("return Data()", x: 40, y: 60),
            frag("}", x: 0, y: 90),
        ]
        let snapshot = try ScreenLook.compose(fragments: fragments, appName: "Xcode", windowTitle: "Loader.swift")
        #expect(!snapshot.text.contains("sk-ant"))
        #expect(snapshot.text.contains("let key = \"[secret]\""))
        #expect(snapshot.text.contains("\n    return Data()\n"))
        #expect(snapshot.redactions == 1)
        #expect(snapshot.scene == .code)
        #expect(snapshot.sourceLabel == "Xcode · Loader.swift")
        #expect(!snapshot.truncated)
    }

    @Test func composeCutsLongScreensAtALineBreak() throws {
        let fragments = (0..<50).map { frag("line \($0) of a long document", x: 0, y: Double($0) * 30) }
        let snapshot = try ScreenLook.compose(fragments: fragments, appName: "Preview", windowTitle: nil, limit: 200)
        #expect(snapshot.truncated)
        #expect(snapshot.text.count <= 200)
        #expect(snapshot.text.split(separator: "\n").allSatisfy { $0.hasSuffix("document") })
        #expect(snapshot.sourceLabel == "Preview")
    }

    @Test func composeRejectsEmptyScreens() {
        #expect(throws: ScreenReadError.nothingReadable) {
            _ = try ScreenLook.compose(fragments: [], appName: "Finder", windowTitle: nil)
        }
    }
}
