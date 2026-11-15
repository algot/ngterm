/// A clock a test moves by hand.
@MainActor
internal final class Ticker {
    /// The time it tells.
    internal private(set) var now = ContinuousClock.now

    internal init() {
        // starts at the time it is made
    }

    /// Moves the time on by `duration`.
    internal func advance(by duration: Duration) {
        now += duration
    }

    deinit {
        // nothing to release
    }
}
