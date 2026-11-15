import LocalAuthentication

/// The system's proof of ownership (LocalAuthentication): Face ID or Touch ID, with the device's passcode as the
/// fallback, each prompt on a context of its own, so one unlock never answers for the next.
public struct SystemDeviceAuth: DeviceAuth {
    private let prompt: @Sendable () -> any OwnerPrompt

    /// Whether the device has a passcode.
    public var isSecured: Bool {
        guard let refusal = prompt().refusal() else {
            return true
        }
        // any other refusal (a biometric locked out, say) still leaves the passcode to ask for
        return (refusal as? LAError)?.code != .passcodeNotSet
    }

    /// The system's prompt.
    public init() {
        self.init { LAContext() }
    }

    /// The prompt `prompt` makes, for each question a new one.
    internal init(prompt: @escaping @Sendable () -> any OwnerPrompt) {
        self.prompt = prompt
    }

    /// How the system's refusal `error` reads: backing out and the system's own interruptions say nothing.
    internal static func outcome(for error: any Error) -> AuthOutcome {
        switch (error as? LAError)?.code {
        case .userCancel, .appCancel, .systemCancel:
            .cancelled

        default:
            .failed(reason: error.localizedDescription)
        }
    }

    /// Asks the owner to unlock, saying `reason`.
    public func confirm(reason: String) async -> AuthOutcome {
        do {
            try await prompt().ask(reason: reason)
            return .confirmed
        } catch {
            return Self.outcome(for: error)
        }
    }
}
