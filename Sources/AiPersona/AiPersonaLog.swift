import Foundation
import os

/// Central `os.Logger` factory for the package. Every log line uses subsystem
/// `cc.nerdsnipe.AiPersona` so one predicate captures everything:
///
///     log stream --predicate 'subsystem == "cc.nerdsnipe.AiPersona"' --level debug
///
/// Categories: `Ingestion`, `Extraction`, `Store`, `Retrieval`, `Gemini`, `Keychain`, `Notion`.
/// User content (fact text, raw model output) is logged with `privacy: .private`, so it is
/// redacted in release builds and visible when the device is attached to a debugger / when
/// private data logging is enabled.
enum AiPersonaLog {
    static let subsystem = "cc.nerdsnipe.AiPersona"

    static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
