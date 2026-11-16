import Foundation
import Synchronization

/// A golden log's clock: a line every 23 s from the evening of 2025-11-14, and from the next morning on from the third.
internal final class LogClock: Sendable {
    // 2025-11-14 22:00 UTC, in seconds since 1970
    private static let eveningSeconds: TimeInterval = 1_763_157_600
    private static let evening = Date(timeIntervalSince1970: eveningSeconds)
    private static let step: TimeInterval = 23
    // ten hours: the night between the evening's lines and the morning's
    private static let night: TimeInterval = 36_000
    private static let eveningLines = 2

    private let count = Mutex(0)

    /// The next line's time.
    internal func next() -> Date {
        let index = count.withLock { value in
            defer { value += 1 }
            return value
        }
        let gap = index >= Self.eveningLines ? Self.night : 0
        return Self.evening.addingTimeInterval(Double(index) * Self.step + gap)
    }

    deinit {
        // nothing to release
    }
}
