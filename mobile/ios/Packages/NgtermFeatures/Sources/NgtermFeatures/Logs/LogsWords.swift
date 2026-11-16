import Foundation

/// What the Logs page says in words.
internal enum LogsWords {
    /// What the log holds.
    internal static var holds: String {
        String(
            localized: """
                The log holds what the app and its connections did: connecting and signing in, the session lists a \
                machine gave, panes, the chat view's state, and why a message or a key was not sent. It names your \
                machines as you named them.
                """
        )
    }

    /// What the log never holds.
    internal static var never: String {
        String(
            localized: """
                It never holds what you type, terminal output, chat messages, keys, passphrases or host key \
                fingerprints.
                """
        )
    }

    /// How much of the log shows (`count` lines of `bytes`), and, when it is `isCut`, that Share sends all of it.
    internal static func extent(count: Int, bytes: UInt64, isCut: Bool) -> String {
        let size = Int64(clamping: bytes).formatted(.byteCount(style: .file))
        if isCut {
            return String(
                localized: """
                    The newest \(count) lines of \(size), newest first, times in UTC. Copy takes these; Share sends \
                    the whole log.
                    """
            )
        }
        if count == 1 {
            return String(localized: "1 line, \(size). Newest first, times in UTC.")
        }
        return String(localized: "\(count) lines, \(size). Newest first, times in UTC.")
    }
}
