import Testing
@testable import Core

@Test func disabledExcludesNothing() {
    for surface in SaaaSurface.allCases {
        #expect(!InvisibleModePolicy.isExcluded(surface, enabled: false, scope: .allWindows))
        #expect(!InvisibleModePolicy.isExcluded(surface, enabled: false, scope: .callContent))
    }
}

@Test func allWindowsScopeExcludesEverySurface() {
    for surface in SaaaSurface.allCases {
        #expect(InvisibleModePolicy.isExcluded(surface, enabled: true, scope: .allWindows))
    }
}

@Test func callContentScopeExcludesOnlyTranscriptSurfaces() {
    #expect(InvisibleModePolicy.isExcluded(.review, enabled: true, scope: .callContent))
    #expect(InvisibleModePolicy.isExcluded(.history, enabled: true, scope: .callContent))
    #expect(!InvisibleModePolicy.isExcluded(.island, enabled: true, scope: .callContent))
    #expect(!InvisibleModePolicy.isExcluded(.settings, enabled: true, scope: .callContent))
    #expect(!InvisibleModePolicy.isExcluded(.onboarding, enabled: true, scope: .callContent))
}

@Test func scopeRawValuesAreStableStorageKeys() {
    #expect(InvisibleModeScope(rawValue: "all") == .allWindows)
    #expect(InvisibleModeScope(rawValue: "content") == .callContent)
    #expect(InvisibleModeScope(rawValue: "bogus") == nil)
}
