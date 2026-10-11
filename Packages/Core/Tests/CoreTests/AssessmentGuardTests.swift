import Testing
@testable import Core

@Suite struct AssessmentGuardTests {

    @Test func assessmentPlatformsAndProctoringToolsMatch() {
        #expect(AssessmentGuard.matches(windowTitle: "Online Coding Test | HackerRank", appName: "Safari"))
        #expect(AssessmentGuard.matches(windowTitle: "Candidate Pad", appName: "Google Chrome", screenText: "CoderPad\nQuestion 1"))
        #expect(AssessmentGuard.matches(windowTitle: nil, appName: "LockDown Browser"))
        #expect(AssessmentGuard.matches(windowTitle: "Weekly Contest 421 - LeetCode", appName: "Arc"))
    }

    @Test func practiceAndOwnWorkDoNot() {
        #expect(!AssessmentGuard.matches(windowTitle: "Two Sum - LeetCode", appName: "Safari"))
        #expect(!AssessmentGuard.matches(
            windowTitle: "Two Sum - LeetCode", appName: "Safari",
            screenText: "1. Two Sum\nGiven an array of integers nums\nExample 1:\nInput: nums = [2,7]"))
        #expect(!AssessmentGuard.matches(windowTitle: "Top Interview 150 - LeetCode", appName: "Safari"))
        #expect(!AssessmentGuard.matches(windowTitle: "PromptComposer.swift", appName: "Xcode"))
        #expect(!AssessmentGuard.matches(windowTitle: "zsh", appName: "Terminal", screenText: "error: build failed"))
    }
}
