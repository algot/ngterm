/// Why Export private key didn't open the export (mobile/android's `ExportNotice`).
public enum ExportNotice: Hashable, Sendable {
    /// The device couldn't confirm the owner of the export of the key `keyId`, for `reason`.
    case authFailed(keyId: String, reason: String)
    /// The device has no passcode, so its owner can't prove it is them.
    case noPasscode

    /// The alert's title.
    public var title: String {
        switch self {
        case .noPasscode:
            String(localized: "Set a passcode first")

        case .authFailed:
            String(localized: "Couldn't confirm it's you")
        }
    }

    /// What the alert says.
    public var message: String {
        switch self {
        case .noPasscode:
            String(
                localized: """
                    A private key leaves ngterm only after you unlock this device, and it has no passcode. Set one in \
                    the Settings app, then export.
                    """
            )

        case .authFailed(_, let reason):
            if reason.isEmpty {
                String(localized: "The device didn't confirm it's you, so the key stays here.")
            } else {
                String(localized: "The device didn't confirm it's you, so the key stays here: \(reason)")
            }
        }
    }
}
