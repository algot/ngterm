import NgtermCore

/// What the clipboard holds of a read's types: each one it holds, the types it holds when the read asked, and whether
/// the app that copied it marked it sensitive, and whether an exported private key may be among them.
public struct ClipboardSnapshot: Equatable, Sendable {
    /// Each requested type the clipboard holds, in the read's order.
    public let contents: [ClipboardPart]
    /// The types the clipboard holds, when the read asked for them.
    public let available: [String]
    /// Whether the clip is marked sensitive (a password manager's, an exported key).
    public let sensitive: Bool
    /// Whether an exported private key may be among ``contents``, so the prompt doesn't show them.
    public let mayHoldKey: Bool

    /// What a read would hand over.
    public init(contents: [ClipboardPart], available: [String], sensitive: Bool = false, mayHoldKey: Bool = false) {
        self.contents = contents
        self.available = available
        self.sensitive = sensitive
        self.mayHoldKey = mayHoldKey
    }
}
