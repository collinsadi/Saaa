import Core
import Foundation
import Testing
@testable import ScreenContext

@Suite struct EditorLookTests {

    static let sample = EditorContext(
        file: "src/app.ts", language: "typescript", lineCount: 120, cursorLine: 5,
        visible: [
            .init(startLine: 1, text: "import { load } from \"./load\";\n\nexport function total(items: number[]): number {\n  let sum = 0;\n  for (const item of items) sum += item.value;\n  return sum;\n}"),
            .init(startLine: 9, text: "export const answer = total(load());"),
        ],
        snippets: [.init(startLine: 98, text: "  const x = y\n  return x.z")],
        selection: "item.value",
        problems: [
            .init(line: 5, severity: "error", message: "Property 'value' does not exist\non type 'number'.", source: "ts", code: "2339"),
            .init(line: 10, severity: "warning", message: "'unused' is never read.", source: "ts", code: "6133"),
        ],
        terminal: .init(command: "npm test", exitCode: 1, output: "\n\nFAIL src/app.test.ts\n  total adds values\n"))

    @Test func rendersProblemsFirstThenNumberedCode() throws {
        let snapshot = try #require(EditorLook.compose(Self.sample, appName: "Visual Studio Code"))
        #expect(snapshot.source == .editor)
        #expect(snapshot.scene == .error)
        #expect(snapshot.sourceLabel == "Visual Studio Code · app.ts")
        #expect(snapshot.text == """
            File: src/app.ts (typescript, 120 lines)

            Problems:
            - line 5, error: Property 'value' does not exist on type 'number'. [ts 2339]
            - line 10, warning: 'unused' is never read. [ts 6133]

            Selected:
            item.value

            Last terminal command failed: npm test (exit code 1)
            FAIL src/app.test.ts
              total adds values

            On screen, lines 1 to 7, cursor on line 5:
             1  import { load } from "./load";
             2  
             3  export function total(items: number[]): number {
             4    let sum = 0;
             5    for (const item of items) sum += item.value;
             6    return sum;
             7  }

            Also on screen, line 9:
             9  export const answer = total(load());

            Near a problem, lines 98 to 99:
            98    const x = y
            99    return x.z
            """)
    }

    @Test func aRegionEndingOnABlankLineKeepsIt() throws {
        let context = EditorContext(file: "a.swift", cursorLine: 4, visible: [.init(startLine: 1, text: "func f() {\n}\n\n")])
        let text = try #require(EditorLook.compose(context, appName: "Code")).text
        #expect(text.contains("On screen, lines 1 to 4, cursor on line 4:"))
        #expect(text.hasSuffix("3  \n4  "))
    }

    @Test func masksSecretsInEditorText() throws {
        let context = EditorContext(
            file: ".env.ts", language: "typescript", visible: [.init(startLine: 1, text: "const key = \"sk-ant-api03-abcdefghijklmnopqrstuvwxyz\"")])
        let snapshot = try #require(EditorLook.compose(context, appName: "Cursor"))
        #expect(!snapshot.text.contains("sk-ant"))
        #expect(snapshot.redactions == 1)
    }

    @Test func codeWithoutProblemsIsCodeEvenWhenItMentionsErrors() throws {
        let context = EditorContext(
            file: "parse.py", language: "python",
            visible: [.init(startLine: 1, text: "def parse(s):\n    if not s:\n        raise ValueError: bad\n    return s\n    error: str = ''\n")])
        #expect(EditorLook.compose(context, appName: "Code")?.scene == .code)
    }

    @Test func proseFilesKeepTheirScene() throws {
        let problem = """
            Given an array of integers nums and an integer target, return indices of the two numbers.
            Example 1:
            Input: nums = [2,7,11,15], target = 9
            Output: [0,1]
            Constraints:
            2 <= nums.length <= 10^4
            """
        let context = EditorContext(file: "two-sum.md", language: "markdown", visible: [.init(startLine: 1, text: problem)])
        #expect(EditorLook.compose(context, appName: "Code")?.scene == .problem)
    }

    @Test func nothingVisibleMeansReadTheScreenInstead() {
        #expect(EditorLook.compose(EditorContext(file: "a.swift", terminal: .init(command: "swift build", exitCode: 1, output: "x")), appName: "Code") == nil)
        #expect(EditorLook.compose(EditorContext(file: "a.swift", visible: [.init(startLine: 1, text: "")]), appName: "Code") == nil)
    }

    @Test func capsLongContextsByTrimmingCodeFirst() throws {
        let code = (1...400).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let context = EditorContext(
            file: "Big.swift", language: "swift", visible: [.init(startLine: 1, text: code)],
            problems: [.init(line: 1, severity: "error", message: "boom")])
        let snapshot = try #require(EditorLook.compose(context, appName: "Code", limit: 500))
        #expect(snapshot.truncated)
        #expect(snapshot.text.count <= 500)
        #expect(snapshot.text.contains("- line 1, error: boom"))
    }
}
