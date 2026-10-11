import CoreGraphics
import Testing
@testable import ScreenContext

@Suite struct OCRLayoutTests {

    @Test func rebuildsRowsIndentationAndBlankLines() {
        let fragments = [
            frag("def area(r):", x: 100, y: 10),
            frag("return 3.14 * r * r", x: 140, y: 40),
            frag("print(area(2))", x: 100, y: 100),
        ]
        #expect(OCRLayout.assemble(fragments) == "def area(r):\n    return 3.14 * r * r\n\nprint(area(2))")
    }

    @Test func joinsFragmentsOnTheSameRow() {
        let fragments = [frag("let x = 1", x: 0, y: 0), frag("// one", x: 150, y: 2)]
        #expect(OCRLayout.assemble(fragments) == "let x = 1    // one")
    }

    @Test func dropsALineNumberGutter() {
        let code = ["import os", "", "def main():", "    print(os.getcwd())", "main()"]
        var fragments: [TextFragment] = []
        for (index, line) in code.enumerated() {
            let y = Double(index) * 30
            fragments.append(frag("\(index + 1)", x: 0, y: y))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                let indent = Double(line.prefix { $0 == " " }.count)
                fragments.append(frag(trimmed, x: 50 + indent * 10, y: y))
            }
        }
        #expect(OCRLayout.assemble(fragments) == "import os\n\ndef main():\n    print(os.getcwd())\nmain()")
    }

    @Test func stripsLineNumbersMergedIntoTheirLines() {
        let lines = ["1 import os", "2 import sys", "3 print(os.name)", "4 print(sys.path)"]
        let fragments = lines.enumerated().map { frag($1, x: 0, y: Double($0) * 30) }
        #expect(OCRLayout.assemble(fragments) == "import os\nimport sys\nprint(os.name)\nprint(sys.path)")
    }

    @Test func splitsSideBySidePanes() {
        let files = ["Sources", "App.swift", "Model.swift", "View.swift"]
        let code = ["struct Model {", "    var name: String", "    var count: Int", "}"]
        var fragments: [TextFragment] = []
        for index in 0..<4 {
            let y = Double(index) * 30
            fragments.append(frag(files[index], x: 0, y: y))
            let line = code[index]
            let indent = Double(line.prefix { $0 == " " }.count)
            fragments.append(frag(line.trimmingCharacters(in: .whitespaces), x: 300 + indent * 10, y: y))
        }
        #expect(OCRLayout.assemble(fragments) == """
            Sources
            App.swift
            Model.swift
            View.swift

            [next pane]

            struct Model {
                var name: String
                var count: Int
            }
            """)
    }

    @Test func keepsIndentedCodeInOnePane() {
        var fragments = [frag("def run():", x: 0, y: 0)]
        for index in 1...10 {
            fragments.append(frag("step_\(index)()", x: 40, y: Double(index) * 30))
        }
        let text = OCRLayout.assemble(fragments)
        #expect(!text.contains(OCRLayout.paneSeparator))
        #expect(text.hasPrefix("def run():\n    step_1()"))
    }

    @Test func ignoresMinimapGlyphs() {
        let fragments = [
            frag("let total = items.count", x: 0, y: 0),
            frag("return total", x: 0, y: 30),
            TextFragment(text: "letletlet", box: CGRect(x: 600, y: 0, width: 20, height: 3)),
        ]
        #expect(OCRLayout.assemble(fragments) == "let total = items.count\nreturn total")
    }

    @Test func nothingInNothingOut() {
        #expect(OCRLayout.assemble([]).isEmpty)
        #expect(OCRLayout.assemble([frag("   ", x: 0, y: 0)]).isEmpty)
    }
}
