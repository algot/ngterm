import NgtermPlatform

/// An exported key's clipboard in memory, for tests.
@MainActor
internal final class MemoryKeyClipboard: KeyClipboard {
    /// The key it holds, if one was copied and not cleared since.
    internal private(set) var held: String?
    /// How many times it was asked to clear.
    internal private(set) var clears = 0

    internal var mayHoldKey: Bool {
        held != nil
    }

    internal init() {
        // nothing copied yet
    }

    internal func copy(_ text: String) {
        held = text
    }

    internal func clearCopied() {
        clears += 1
        held = nil
    }

    deinit {
        // nothing to release
    }
}
