/// One line of the diagnostic log as the Logs screen shows it (mobile/android's `LogLine`).
///
/// Its day (`2026-11-15`) and time (`10:11:12`), both UTC as written, its level, its component and what happened. A
/// line not in the log's format keeps all of it as its text.
public struct LogLine: Equatable, Sendable {
    /// A line's level, as the log writes it.
    public enum Level: Sendable {
        case info
        case warning
        case error
    }

    /// The day it was written, UTC; empty for a line not in the log's format.
    public let day: String
    /// The time it was written, UTC, to the second; empty for a line not in the log's format.
    public let time: String
    /// Its level.
    public let level: Level
    /// The component that wrote it; empty for a line not in the log's format.
    public let tag: String
    /// What happened, with its `key=value` fields as written.
    public let text: String

    /// A line of these parts.
    public init(day: String, time: String, level: Level, tag: String, text: String) {
        self.day = day
        self.time = time
        self.level = level
        self.tag = tag
        self.text = text
    }

    /// `line` as the log wrote it (`2026-11-15T10:11:12.345Z W link: reconnecting delay=4`).
    public init(parsing line: Substring) {
        let format = /^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})\.\d{3}Z ([IWE]) ([^ :]+): (.*)$/
        guard let match = line.wholeMatch(of: format) else {
            self.init(day: "", time: "", level: .info, tag: "", text: String(line))
            return
        }
        let written: Level =
            switch match.3 {
            case "W":
                .warning

            case "E":
                .error

            default:
                .info
            }
        self.init(
            day: String(match.1),
            time: String(match.2),
            level: written,
            tag: String(match.4),
            text: String(match.5)
        )
    }

    /// `raw` (the log's text, oldest line first) as lines, newest first, at most `limit` of them.
    public static func parse(_ raw: String, limit: Int) -> [Self] {
        raw.split(whereSeparator: \.isNewline)
            .filter { !$0.allSatisfy(\.isWhitespace) }
            .suffix(limit)
            .reversed()
            .map(Self.init(parsing:))
    }
}
