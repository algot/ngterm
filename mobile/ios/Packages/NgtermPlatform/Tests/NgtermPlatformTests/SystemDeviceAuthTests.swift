import LocalAuthentication
import Testing

@testable import NgtermPlatform

/// The system's proof of ownership, over a prompt of the test's own: whether the device has a passcode, and how each
/// way the system's prompt ends reads.
@Suite("the device's owner")
internal struct SystemDeviceAuthTests {
    private struct Prompt: OwnerPrompt {
        let refused: LAError.Code?
        let failure: (any Error)?

        func refusal() -> (any Error)? {
            refused.map { LAError($0) }
        }

        func ask(reason _: String) throws {
            if let failure {
                throw failure
            }
        }
    }

    private struct Unknown: Error {}

    private static func auth(refused: LAError.Code? = nil, failure: (any Error)? = nil) -> SystemDeviceAuth {
        SystemDeviceAuth { Prompt(refused: refused, failure: failure) }
    }

    @Test("a device is secured unless it has no passcode: a biometric locked out still leaves the passcode")
    internal func secured() {
        #expect(Self.auth().isSecured)
        #expect(!Self.auth(refused: .passcodeNotSet).isSecured)
        #expect(Self.auth(refused: .biometryLockout).isSecured)
    }

    @Test("an owner who unlocks is confirmed")
    internal func confirmed() async {
        #expect(await Self.auth().confirm(reason: "export") == .confirmed)
    }

    @Test(
        "backing out, and the system taking the prompt away, say nothing",
        arguments: [LAError.Code.userCancel, .appCancel, .systemCancel]
    )
    internal func cancelled(code: LAError.Code) async {
        #expect(await Self.auth(failure: LAError(code)).confirm(reason: "export") == .cancelled)
    }

    @Test("a device that couldn't confirm says why, in the system's words")
    internal func failed() async {
        let refused = LAError(.authenticationFailed)
        let outcome = await Self.auth(failure: refused).confirm(reason: "export")
        #expect(outcome == .failed(reason: refused.localizedDescription))
        guard case .failed(let reason) = await Self.auth(failure: Unknown()).confirm(reason: "export") else {
            Issue.record("an unknown failure wasn't one")
            return
        }
        #expect(!reason.isEmpty)
    }
}
