#if DEBUG
    import NgtermPlatform
    import Synchronization

    /// The fake world's device: its owner confirms at once, with no system prompt for a UI test to answer; or it has
    /// no passcode at all; or its first check fails, as a wrong face or passcode does, and the next ones confirm.
    internal final class FakeDeviceAuth: DeviceAuth {
        internal let isSecured: Bool
        private let failsNext: Mutex<Bool>

        internal init(isSecured: Bool, failsFirst: Bool) {
            self.isSecured = isSecured
            failsNext = Mutex(failsFirst)
        }

        internal func confirm(reason _: String) -> AuthOutcome {
            guard isSecured else {
                return .failed(reason: "no passcode")
            }
            let fails = failsNext.withLock { fails in
                defer { fails = false }
                return fails
            }
            return fails ? .failed(reason: "not recognized") : .confirmed
        }

        deinit {
            // nothing to release
        }
    }
#endif
