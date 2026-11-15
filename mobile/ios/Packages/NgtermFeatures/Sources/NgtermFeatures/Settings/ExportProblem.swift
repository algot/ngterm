import NgtermCore

/// Why an export didn't happen (mobile/android's `ExportProblem`).
public enum ExportProblem: Hashable, Sendable {
    /// The proof that it is the owner is too old: they confirm again.
    case expired
    /// The key couldn't be read or written out, for `reason`.
    case failed(reason: String)
    /// The key is no longer on this device.
    case gone
    /// The passphrase has fewer than `minimum` characters.
    case shortPassphrase(minimum: Int)

    /// What the screen says.
    public var message: String {
        switch self {
        case .expired:
            String(localized: "It's been a while since you unlocked. Go back and export again.")

        case .shortPassphrase(let minimum):
            String(localized: "Use at least \(minimum) characters.")

        case .gone:
            String(localized: "This key is no longer on this device.")

        case .failed(let reason):
            String(localized: "The key couldn't be exported: \(reason)")
        }
    }

    /// Why the export threw `error`.
    public init(_ error: any Error) {
        switch error {
        case let error as KeyError:
            if case .PassphraseTooShort(let minimum) = error {
                self = .shortPassphrase(minimum: Int(minimum))
            } else {
                self = .failed(reason: error.reason)
            }

        case let error as VaultError:
            switch error {
            case .Missing:
                self = .gone

            case .Unavailable(let reason):
                self = .failed(reason: reason)
            }

        default:
            self = .failed(reason: ErrorWords.of(error))
        }
    }
}
