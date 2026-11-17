import Testing

@testable import NgTerm

/// The tests' wait for a call: a call that never returns fails its test instead of holding the run.
@MainActor
@Suite("a test's wait for a call")
internal struct BoundedWaitTests {
    private struct Refused: Error, Equatable {}

    @Test("a call that returns gives its value, and one that throws its error")
    internal func ends() async throws {
        #expect(try await AppWindow.value("no value") { 7 } == 7)
        await #expect(throws: Refused()) {
            try await AppWindow.value("no error") { throw Refused() }
        }
    }

    @Test("a call that never returns fails the test, cancelled")
    internal func neverReturns() async throws {
        let cues = HeldCues()
        let cancelled = Outcome<Bool>()
        await withKnownIssue {
            try await AppWindow.value("never let on") {
                await cues.next(.duplicateLands)
                cancelled.result = .success(Task.isCancelled)
            }
        }
        cues.letOn()
        try await AppWindow.until { cancelled.result != nil }
        #expect(try cancelled.result?.get() == true)
    }
}
