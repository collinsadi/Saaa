import Testing
@testable import Transcription

@Test func moduleLinksAndReportsIdentity() {
    #expect(TranscriptionModule.name == "Transcription")
}

@Test func whisperFrameworkLinksAndRuns() {
    // Calls into the C API — proves the XCFramework loads at runtime.
    let info = TranscriptionModule.whisperSystemInfo
    #expect(!info.isEmpty)
}
