/// Core Audio process taps plus mic capture: lock-free ring buffer, two 16 kHz mono WAV streams, ScreenCaptureKit fallback.
public enum AudioCaptureModule {
    /// Module identity used in diagnostics and privacy-safe logs.
    public static let name = "AudioCapture"

    /// Debug (harness `--tap-only`): compose the aggregate with only the
    /// output device + tap, Apple-sample shape — no mic sub-device. Set once
    /// at launch, before any capture starts.
    nonisolated(unsafe) public static var debugTapOnlyComposition = false
}
