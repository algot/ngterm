#if NGTERM_FAKES
    import Foundation
    import NgtermCore
    import Synchronization

    /// A diagnostic log in memory, in place of the core's (mobile/android's `FakeAppLog`).
    ///
    /// It writes its lines as the core does (`2026-11-15T10:11:12.345Z I tag: text`), keeps the tag and message rules
    /// of the core's `append`, and fails its exports when told to.
    public final class MemoryAppLog: AppLogProtocol, Sendable {
        private struct State {
            var lines: [String] = []
            var failsExport = false
        }

        // the core's own: a tag of 1 to 16 letters, digits, - or _, else `app`; a message of one line, at most 300
        private static let tagCap = 16
        private static let messageCap = 300

        private let state = Mutex(State())
        private let clock: @Sendable () -> Date

        /// Every line, oldest first, as the log holds them.
        public var lines: [String] {
            state.withLock { $0.lines }
        }

        /// Whether ``export(path:)`` fails, as a file that can't be written does.
        public var failsExport: Bool {
            get { state.withLock { $0.failsExport } }
            set { state.withLock { $0.failsExport = newValue } }
        }

        /// An empty log whose lines are stamped by `clock`.
        @preconcurrency
        public init(clock: @escaping @Sendable () -> Date = { Date() }) {
            self.clock = clock
        }

        private static func isTag(_ tag: String) -> Bool {
            (1...tagCap).contains(tag.count)
                && tag.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }

        private static func letter(_ level: LogLevel) -> String {
            switch level {
            case .info:
                "I"

            case .warn:
                "W"

            case .error:
                "E"
            }
        }

        /// Appends a line of `level` for the component `tag`, as the core's `append` does.
        public func append(level: LogLevel, tag: String, message: String) {
            let component = Self.isTag(tag) ? tag : "app"
            let text = String(message.map { $0.isNewline ? " " : $0 }.prefix(Self.messageCap))
            write(level, tag: component, text: text)
        }

        /// Deletes every line, then says so.
        public func clear() {
            state.withLock { $0.lines = [] }
            write(.info, tag: "log", text: "log cleared")
        }

        /// Writes the whole log to `path`, or fails as told.
        public func export(path: String) throws -> UInt64 {
            if failsExport {
                throw LogError.Io(reason: "no space left on device")
            }
            let whole = text()
            do {
                try Data(whole.utf8).write(to: URL(fileURLWithPath: path))
            } catch {
                throw LogError.Io(reason: error.localizedDescription)
            }
            return UInt64(whole.utf8.count)
        }

        /// The bytes the log holds.
        public func size() -> UInt64 {
            UInt64(text().utf8.count)
        }

        /// The newest whole lines that fit in `maxBytes`, oldest first.
        public func tail(maxBytes: UInt32) -> String {
            var kept: [String] = []
            var bytes = 0
            for line in lines.reversed() {
                bytes += line.utf8.count + 1
                guard bytes <= Int(maxBytes) else {
                    break
                }
                kept.append(line)
            }
            return kept.reversed().map { "\($0)\n" }.joined()
        }

        /// The whole log, oldest first.
        public func text() -> String {
            lines.map { "\($0)\n" }.joined()
        }

        private func write(_ level: LogLevel, tag: String, text: String) {
            let stamp = clock().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
            let line = "\(stamp)Z \(Self.letter(level)) \(tag): \(text)"
            state.withLock { $0.lines.append(line) }
        }

        deinit {
            // nothing to release
        }
    }
#endif
