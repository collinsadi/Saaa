import Core
import Testing
@testable import ScreenContext

@Suite struct SceneClassifierTests {

    @Test func errorsAreRecognizedAcrossLanguages() {
        #expect(SceneClassifier.classify("""
            Traceback (most recent call last):
              File "main.py", line 3, in <module>
            ZeroDivisionError: division by zero
            """) == .error)
        #expect(SceneClassifier.classify("Sources/App/main.swift:12:5: error: cannot find 'foo' in scope") == .error)
        #expect(SceneClassifier.classify("""
            TypeError: Cannot read properties of undefined (reading 'map')
                at render (App.jsx:14:22)
            """) == .error)
        #expect(SceneClassifier.classify("panic: runtime error: index out of range [3] with length 3") == .error)
    }

    @Test func problemStatementsAreRecognized() {
        let twoSum = """
            1. Two Sum
            Given an array of integers nums and an integer target, return indices of the two numbers.
            Example 1:
            Input: nums = [2,7,11,15], target = 9
            Output: [0,1]
            Constraints:
            2 <= nums.length <= 10^4
            """
        #expect(SceneClassifier.classify(twoSum) == .problem)
    }

    @Test func anErrorUnderAProblemIsTheError() {
        let text = """
            Example 1:
            Input: s = "abc"
            Output: 3
            Constraints:
            Runtime Error
            IndexError: list index out of range
            """
        #expect(SceneClassifier.classify(text) == .error)
    }

    @Test func codeIsRecognized() {
        let swift = """
            struct Cart {
                var items: [Item] = []
                func total() -> Decimal {
                    items.reduce(0) { $0 + $1.price }
                }
            }
            """
        #expect(SceneClassifier.classify(swift) == .code)
    }

    @Test func codingQuestionsInProse() {
        #expect(SceneClassifier.classify("Hey, how do I reverse a linked list in Python without recursion?") == .question)
        #expect(SceneClassifier.classify("Why does this function return null on the first call?") == .question)
    }

    @Test func meetingScreensStayOther() {
        #expect(SceneClassifier.classify("Q3 revenue grew 12% year over year.\nNext steps: hire two AEs.\nAny questions?") == .other)
        #expect(SceneClassifier.classify("Can we trust the vendor's timeline?\nCan we make an exception for Acme?") == .other)
        #expect(SceneClassifier.classify("Docs: Example usage of the dashboard. Return the form by Friday.") == .other)
    }
}
