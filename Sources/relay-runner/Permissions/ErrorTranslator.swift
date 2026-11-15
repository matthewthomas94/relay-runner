import Foundation

/// Translates raw system and setup error strings into something a
/// non-technical user can act on: "check your internet connection and try
/// again", not a raw installer log.
///
/// Heuristics are intentionally conservative — if nothing matches, we return
/// the original string so we never *hide* the real error.
enum ErrorTranslator {

    struct Translation {
        let headline: String
        let action: String?
    }

    static func translate(_ raw: String) -> Translation {
        let lower = raw.lowercased()

        if lower.contains("no space left on device") || lower.contains("no such device") && lower.contains("space") {
            return Translation(
                headline: "Not enough disk space.",
                action: "Relay Runner needs about 1 GB for model files. Free up some space and click Retry Setup."
            )
        }

        if lower.contains("could not resolve host") ||
           lower.contains("network is unreachable") ||
           lower.contains("name or service not known") ||
           lower.contains("could not reach") ||
           lower.contains("connection reset") ||
           lower.contains("timed out") && lower.contains("download") {
            return Translation(
                headline: "Couldn't reach the internet.",
                action: "Relay Runner needs a connection to install dependencies and download models. Check your network and click Retry Setup."
            )
        }

        if lower.contains("brew install") && lower.contains("failed") {
            return Translation(
                headline: "Homebrew installation failed.",
                action: "Open Terminal and run brew doctor to diagnose, then click Retry Setup."
            )
        }

        if lower.contains("permission denied") {
            return Translation(
                headline: "A file operation was blocked.",
                action: "This usually means a disk permission issue in ~/Library/Application Support. Restart your Mac and try again, or contact support if it persists."
            )
        }

        // Model download failure — message from STTEngine / huggingface_hub
        if lower.contains("failed to download") || lower.contains("huggingface") {
            return Translation(
                headline: "Couldn't download the speech recognition model.",
                action: "This is usually a connectivity issue. Check your network and click Retry Setup."
            )
        }

        return Translation(headline: raw, action: nil)
    }
}
