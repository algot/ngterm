import NgtermCore

/// What the export screen holds while it is filled in, in memory only: the passphrase, typed twice, or the choice to
/// export with none.
public struct ExportDraft: Hashable, Sendable {
    /// The passphrase.
    public var passphrase = ""
    /// The passphrase, typed again.
    public var again = ""
    /// Whether the key is exported without a passphrase: not encrypted.
    public var isUnprotected = false

    /// How the export is protected, as the draft stands.
    public var protection: ExportProtection {
        isUnprotected ? .unprotected : .passphrase(passphrase: passphrase)
    }

    /// An empty draft: a passphrase to be typed.
    public init() {
        // every part starts at its default
    }
}
