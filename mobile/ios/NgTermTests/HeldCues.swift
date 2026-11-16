import Synchronization

@testable import NgTerm

/// The cues the fake world asks for, let on as a UI test's posts would: each step waits until the test lets it on.
internal final class HeldCues: Sendable {
    private struct State {
        var asked: [FakeCues.Cue] = []
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// The cues asked for, oldest first.
    internal var asked: [FakeCues.Cue] {
        state.withLock { $0.asked }
    }

    /// Returns once the test lets the step on.
    internal func next(_ cue: FakeCues.Cue) async {
        await withCheckedContinuation { waiter in
            state.withLock { state in
                state.asked.append(cue)
                state.waiting.append(waiter)
            }
        }
    }

    /// Lets every step that waits go on.
    internal func letOn() {
        let waiting = state.withLock { state in
            defer { state.waiting = [] }
            return state.waiting
        }
        for waiter in waiting {
            waiter.resume()
        }
    }

    deinit {
        // nothing to release: a step left waiting ends with its test
    }
}
