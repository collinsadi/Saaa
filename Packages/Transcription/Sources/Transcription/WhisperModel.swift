import Foundation

/// The model files Saaa depends on, pinned by content hash.
public enum WhisperModel: String, Sendable, CaseIterable {
    /// The transcription model (contract choice: best affordable accuracy).
    case largeV3Turbo = "ggml-large-v3-turbo.bin"
    /// Silero VAD model used by whisper.cpp's integrated VAD.
    case sileroVAD = "ggml-silero-v5.1.2.bin"

    /// Canonical download source (HuggingFace, resolve URLs).
    public var downloadURL: URL {
        switch self {
        case .largeV3Turbo:
            URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!
        case .sileroVAD:
            URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!
        }
    }

    /// Pinned SHA-256 (from the upstream LFS metadata, verified 2026-07-21).
    public var sha256: String {
        switch self {
        case .largeV3Turbo:
            "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
        case .sileroVAD:
            "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf"
        }
    }

    /// Expected size in bytes — used for download progress and sanity checks.
    public var byteSize: Int64 {
        switch self {
        case .largeV3Turbo: 1_624_555_275
        case .sileroVAD: 885_098
        }
    }

    public var displayName: String {
        switch self {
        case .largeV3Turbo: "Whisper large-v3-turbo"
        case .sileroVAD: "Silero VAD"
        }
    }
}
