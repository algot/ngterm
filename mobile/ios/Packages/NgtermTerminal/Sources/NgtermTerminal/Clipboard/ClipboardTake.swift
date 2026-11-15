import NgtermCore

/// What a program's read takes from the clipboard at one moment: its data, the types held and the sensitive mark, all
/// of the same clip.
public struct ClipboardTake: Equatable, Sendable {
    // how often a take reads a clipboard that changes under it
    internal static let attempts = 3

    /// Each requested type the clipboard holds, in the read's order.
    public let contents: [ClipboardPart]
    /// The types the clipboard holds, when the read asked for them.
    public let types: [String]
    /// Whether the app that copied it marked it sensitive.
    public let sensitive: Bool

    /// What was taken.
    public init(contents: [ClipboardPart], types: [String], sensitive: Bool) {
        self.contents = contents
        self.types = types
        self.sensitive = sensitive
    }
}

extension TerminalClipboard {
    /// Each of `mimes` it holds, the types it holds when `list` asks, and whether that same clip is marked sensitive.
    ///
    /// A clipboard that changed while it was read is read again, so a mark is never one clip's and the data another's;
    /// one that keeps changing reads as sensitive, the side that asks.
    public func take(_ mimes: [String], list: Bool) -> ClipboardTake {
        var taken = ClipboardTake(contents: [], types: [], sensitive: true)
        for _ in 0..<ClipboardTake.attempts {
            let count = changeCount
            let sensitive = isSensitive
            let contents = mimes.isEmpty ? [] : read(mimes)
            let held = list ? types() : []
            if changeCount == count {
                return ClipboardTake(contents: contents, types: held, sensitive: sensitive)
            }
            taken = ClipboardTake(contents: contents, types: held, sensitive: true)
        }
        return taken
    }
}
