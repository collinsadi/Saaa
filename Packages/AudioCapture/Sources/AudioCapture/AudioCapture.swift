/// Core Audio process taps plus mic capture: lock-free ring buffer, two 16 kHz mono WAV streams, ScreenCaptureKit fallback.
public enum AudioCaptureModule {
    /// Module identity used in diagnostics and privacy-safe logs.
    public static let name = "AudioCapture"
}
