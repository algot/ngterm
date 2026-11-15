import NgtermPlatform
import Synchronization

/// The device's owner, faked: a device with a passcode whose owner confirms, unless a test says otherwise.
internal final class FakeDeviceAuth: DeviceAuth {
    private let secured = Mutex(true)
    private let outcomes = Mutex<[AuthOutcome]>([])
    private let reasons = Mutex<[String]>([])

    /// Whether the device has a passcode.
    internal var isSecured: Bool {
        get { secured.withLock { $0 } }
        set { secured.withLock { $0 = newValue } }
    }

    /// How the next prompts end, in order; once they run out the owner confirms.
    internal var next: [AuthOutcome] {
        get { outcomes.withLock { $0 } }
        set { outcomes.withLock { $0 = newValue } }
    }

    /// What each prompt said, in order.
    internal var asked: [String] {
        reasons.withLock { $0 }
    }

    internal init() {
        // a passcode, and an owner who confirms
    }

    internal func confirm(reason: String) -> AuthOutcome {
        reasons.withLock { $0.append(reason) }
        return outcomes.withLock { $0.isEmpty ? .confirmed : $0.removeFirst() }
    }

    deinit {
        // nothing to release
    }
}
