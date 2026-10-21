import os

/// Unified logging. Policy: never log transcript text, audio, API keys or the content of other apps.
/// Only states, durations, sizes and error categories are logged.
public enum Log {
    private static let subsystem = "local.leblab.LeBlab"
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let transcription = Logger(subsystem: subsystem, category: "transcription")
    public static let formatting = Logger(subsystem: subsystem, category: "formatting")
    public static let insertion = Logger(subsystem: subsystem, category: "insertion")
    public static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
}
