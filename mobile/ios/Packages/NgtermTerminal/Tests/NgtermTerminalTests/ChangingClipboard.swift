import Foundation
import NgtermCore
import NgtermTerminal

/// A clipboard whose contents change under its first `changes` reads, as another app's copy does.
@MainActor
internal final class ChangingClipboard: TerminalClipboard {
    private var changes: Int
    /// How many times its data was read.
    internal private(set) var reads = 0
    internal private(set) var changeCount = 0

    internal var hasText: Bool {
        true
    }

    internal var isSensitive: Bool {
        false
    }

    internal init(changes: Int) {
        self.changes = changes
    }

    internal func text() -> String? {
        "clip"
    }

    internal func write(_: String?) {
        // nothing is kept
    }

    internal func types() -> [String] {
        ["text/plain"]
    }

    internal func read(_ mimes: [String]) -> [ClipboardPart] {
        reads += 1
        if changes > 0 {
            changes -= 1
            changeCount += 1
        }
        return mimes.map { ClipboardPart(mime: $0, data: Data("clip".utf8)) }
    }

    internal func write(_: [ClipboardPart]) -> ClipboardWriteStatus {
        .unsupported
    }

    deinit {
        // nothing to release
    }
}
