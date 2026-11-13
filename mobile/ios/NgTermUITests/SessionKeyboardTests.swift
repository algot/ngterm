import XCTest

/// A session opened with a hardware keyboard takes the keyboard at once, with no tap on it (Android's `FollowFocus`):
/// its selected pane's terminal, or its chat's prompt field when the pane shows its chat. The fake core's `split`
/// (`-ngterm-fake-session`): each pane names itself on its first line ("P1 ready") and echoes what it was typed on its
/// second ("$ ls"); New session there opens `session 1`, of one pane, `P1` too. The simulator has the Mac's keyboard
/// attached, so each test runs with a hardware keyboard; the session moves' chords chaining is SessionViewTests'.
internal final class SessionKeyboardTests: XCTestCase {
    private static let wait: TimeInterval = 15

    // the terminal whose screen names the pane `pane` and shows `typed` after its prompt (VoiceOver's value of it)
    @MainActor
    private static func screen(_ pane: String, typed: String = "", in app: XCUIApplication) -> XCUIElement {
        let shows = NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@", "\(pane) ready", "$ \(typed)")
        return app.textViews.matching(shows).firstMatch
    }

    // the session view's title naming `name`
    @MainActor
    private static func title(naming name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'session-title' AND label CONTAINS %@", name))
            .firstMatch
    }

    // types `text` key by key on the hardware keyboard, to whatever has the focus
    @MainActor
    private static func type(_ text: String, in app: XCUIApplication) {
        for character in text {
            app.typeKey(String(character), modifierFlags: [])
        }
    }

    // no soft keyboard came up: the hardware one types
    @MainActor
    private static func expectNoSoftKeyboard(in app: XCUIApplication, _ when: String) {
        XCTAssertEqual(app.keyboards.count, 0, "a soft keyboard came up \(when)")
    }

    // the app on `split`'s sessions, past the machines
    @MainActor
    private func openSplit(arguments: [String]) -> XCUIApplication {
        let app = FakeApp.launch(withKey: true, arguments: ["-ngterm-fake-session"] + arguments, for: self)
        FakeApp.showMachines(in: app)
        FakeApp.expectRow("split", reads: "Connected", in: app)
        app.descendants(matching: .any)["machine-row-split"].firstMatch.tap()
        return app
    }

    // a tap on `work`'s row opens it on its first pane, which takes the typing; a tablet's split shows the second pane
    // beside it, which takes none; then New session opens a session whose pane takes the typing in its turn
    @MainActor
    internal func testASessionOpenedByItsRowOrNewSessionTakesTheTypingAtOnce() {
        let app = openSplit(arguments: [])
        let row = app.descendants(matching: .any)["session-work"].firstMatch
        FakeApp.expect(row, "work's row")
        row.tap()
        FakeApp.expect(Self.screen("P1", in: app), "work's first pane")
        Self.type("ls", in: app)
        FakeApp.expect(Self.screen("P1", typed: "ls", in: app), "the typing on work's first pane, with no tap")
        XCTAssertFalse(Self.screen("P2", typed: "l", in: app).exists, "the pane not selected took the typing")
        Self.expectNoSoftKeyboard(in: app, "on work")

        // a phone goes back from the session to the machine's sessions; a tablet shows them beside it
        let newSession = app.buttons["new-session"]
        if !newSession.exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        FakeApp.expect(newSession, "New session")
        newSession.tap()
        FakeApp.expect(Self.title(naming: "session 1", in: app), "the new session's view")
        FakeApp.expect(Self.screen("P1", in: app), "the new session's pane")
        Self.type("pwd", in: app)
        FakeApp.expect(Self.screen("P1", typed: "pwd", in: app), "the typing on the new session's pane, with no tap")
        Self.expectNoSoftKeyboard(in: app, "on the new session")
    }

    // `work`'s first pane runs Claude Code, so the session opens on its chat: the prompt field takes the typing
    @MainActor
    internal func testASessionOpenedOnItsChatTakesTheTypingInItsPrompt() {
        let app = openSplit(arguments: ["-ngterm-fake-chat"])
        app.descendants(matching: .any)["session-work"].firstMatch.tap()
        let field = app.descendants(matching: .any)["chat-prompt"].firstMatch
        FakeApp.expect(field, "the chat's prompt field")
        Self.type("hi", in: app)
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'hi'"), object: field)
        XCTAssertEqual(
            XCTWaiter.wait(for: [typed], timeout: Self.wait),
            .completed,
            "the prompt field reads '\(field.value as? String ?? "")', not the typing"
        )
        Self.expectNoSoftKeyboard(in: app, "on the chat")
    }

    deinit {
        // nothing to release: XCTest owns the app it launched
    }
}
