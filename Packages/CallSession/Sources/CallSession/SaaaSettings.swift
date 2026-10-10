import Foundation

/// App preferences in UserDefaults. Keys are storage: never rename.
public enum SaaaSettings {
    public static let localeKey = "transcription.locale"
    public static let keepAudioKey = "audio.keep"
    public static let autoSummaryKey = "summary.auto"
    public static let meetingDetectionKey = "meetingDetection"
    public static let consentReminderKey = "consent.reminder"
    public static let onboardingCompleteKey = "onboarding.v2.complete"
    public static let showIslandKey = "showIsland"
    public static let freezeMetersKey = "freezeMeters"
    public static let saveFolderKey = "export.folder"

    public static func locale(_ defaults: UserDefaults = .standard) -> Locale {
        let stored = defaults.string(forKey: localeKey) ?? ""
        return stored.isEmpty ? Locale.current : Locale(identifier: stored)
    }

    public static func keepsAudio(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: keepAudioKey)
    }

    public static func autoSummary(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: autoSummaryKey) as? Bool ?? true
    }

    public static func meetingDetection(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: meetingDetectionKey) as? Bool ?? true
    }

    public static func consentReminder(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: consentReminderKey) as? Bool ?? true
    }

    /// The line the disclosure helper copies.
    public static let disclosureLine =
        "Quick heads-up: I'm using an AI notetaker (Saaa) to transcribe this call and help me take notes."
}
