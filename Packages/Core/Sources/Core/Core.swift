/// Shared models and utilities used by every other Saaa package. No
/// dependencies: everything here is plain, Codable, testable data.
public enum CoreModule {
    /// Module identity used in diagnostics and privacy-safe logs.
    public static let name = "Core"
}

/// `mm:ss` (or `h:mm:ss`) call-time stamps for transcripts and prompts.
public enum CallTime {
    public static func stamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        func pad(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        return hours > 0 ? "\(hours):\(pad(minutes)):\(pad(secs))" : "\(pad(minutes)):\(pad(secs))"
    }
}
