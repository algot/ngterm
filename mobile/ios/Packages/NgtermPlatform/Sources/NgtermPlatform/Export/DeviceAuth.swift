/// Proof that whoever holds the device owns it: the system's prompt (``SystemDeviceAuth``) in the app, a fake in its
/// tests.
public protocol DeviceAuth: Sendable {
    /// Whether the device has a passcode: without one there is nothing to prove ownership with.
    var isSecured: Bool { get }

    /// Asks the owner to unlock, saying `reason` in the system's prompt.
    func confirm(reason: String) async -> AuthOutcome
}
