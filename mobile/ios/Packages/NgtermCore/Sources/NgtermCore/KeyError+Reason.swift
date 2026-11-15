import NgtermCoreBindings

extension KeyError {
    /// The words for why the key could not be made, imported or exported.
    public var reason: String {
        switch self {
        case .PassphraseRequired:
            "the key is protected by a passphrase"

        case .WrongPassphrase:
            "the passphrase doesn't open the key"

        case .PassphraseTooShort(let minimum):
            "the passphrase needs at least \(minimum) characters"

        case .Invalid(let reason):
            reason
        }
    }
}
