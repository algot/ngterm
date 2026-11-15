/// What is wrong with the passphrase an export was tried with.
public enum PassphraseProblem: Hashable, Sendable {
    /// The two passphrases differ.
    case differs
    /// It has fewer than `minimum` characters.
    case short(minimum: Int)

    /// What the screen says under the field it is about.
    public var message: String {
        switch self {
        case .short(let minimum):
            String(localized: "Use at least \(minimum) characters.")

        case .differs:
            String(localized: "The two passphrases differ.")
        }
    }
}
