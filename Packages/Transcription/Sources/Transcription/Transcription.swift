import whisper

/// whisper.cpp bridge: VAD trimming, per-channel transcription, Me/Them
/// timestamp merge, vocabulary bias.
public enum TranscriptionModule {
    /// Module identity used in diagnostics and privacy-safe logs.
    public static let name = "Transcription"

    /// The linked whisper.cpp build's capability string (proves the C API is
    /// linked and callable; useful in diagnostics).
    public static var whisperSystemInfo: String {
        String(cString: whisper_print_system_info())
    }
}
