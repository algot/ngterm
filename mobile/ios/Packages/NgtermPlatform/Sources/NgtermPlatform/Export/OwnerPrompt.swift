import LocalAuthentication

/// The system's check of the device's owner, a biometric with the passcode as its fallback: `LAContext` in the app.
internal protocol OwnerPrompt {
    /// Why the owner can't be asked, if they can't be.
    func refusal() -> (any Error)?

    /// Asks the owner to unlock, saying `reason`.
    ///
    /// - Throws: the system's error when they didn't.
    func ask(reason: String) async throws
}

extension LAContext: OwnerPrompt {
    internal func refusal() -> (any Error)? {
        var error: NSError?
        return canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) ? nil : error
    }

    internal func ask(reason: String) async throws {
        _ = try await evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }
}
