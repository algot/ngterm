/// How asking the device's owner to prove it is them ended.
public enum AuthOutcome: Hashable, Sendable {
    /// The owner backed out, or the system took the prompt away: nothing to say.
    case cancelled
    /// The owner unlocked: a biometric or the passcode.
    case confirmed
    /// The device couldn't confirm, for `reason` (the system's words).
    case failed(reason: String)
}
