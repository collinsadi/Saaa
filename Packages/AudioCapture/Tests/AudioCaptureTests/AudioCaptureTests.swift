import Testing
@testable import AudioCapture

@Test func moduleLinksAndReportsIdentity() {
    #expect(AudioCaptureModule.name == "AudioCapture")
}
