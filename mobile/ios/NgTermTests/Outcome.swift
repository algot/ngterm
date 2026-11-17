/// How a call that a test waits for ended, once it has (``AppWindow/value(_:of:)``).
@MainActor
internal final class Outcome<Value> {
    /// What the call returned or threw: nil while it runs.
    internal var result: Result<Value, any Error>?

    deinit {
        // nothing to release: it only holds the result
    }
}
