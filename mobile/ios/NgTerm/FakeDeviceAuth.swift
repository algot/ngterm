#if DEBUG
    import NgtermPlatform

    /// The fake world's device: its owner confirms at once, with no system prompt for a UI test to answer, or it has
    /// no passcode at all.
    internal struct FakeDeviceAuth: DeviceAuth {
        internal let isSecured: Bool

        internal func confirm(reason _: String) -> AuthOutcome {
            isSecured ? .confirmed : .failed(reason: "no passcode")
        }
    }
#endif
