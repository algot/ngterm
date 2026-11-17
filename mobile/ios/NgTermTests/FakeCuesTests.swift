import CoreFoundation
import Testing

@testable import NgTerm

/// The cues a UI test posts to the fake worlds: each Darwin notification lets one waiting step on.
@Suite("the fake worlds' cues")
internal struct FakeCuesTests {
    private static func post(_ cue: FakeCues.Cue) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(cue.rawValue as CFString), nil, nil, true)
    }

    @Test("a step waiting on a cue goes on once it is posted")
    internal func waits() async throws {
        let cues = FakeCues()
        let step = Task { await cues.next(.chatBack) }
        Self.post(.chatBack)
        try await AppWindow.value("the step did not go on") { await step.value }
    }

    @Test("a cue posted before its step asks waits for it, one post for one step")
    internal func banks() async throws {
        let cues = FakeCues()
        Self.post(.chatDrop)
        // the post comes on the notification queue: one step takes it, the next waits for its own
        try await AppWindow.until { cues.isBanked(.chatDrop) }
        try await AppWindow.value("the banked cue did not let the step on") { await cues.next(.chatDrop) }
        #expect(!cues.isBanked(.chatDrop))
    }
}
