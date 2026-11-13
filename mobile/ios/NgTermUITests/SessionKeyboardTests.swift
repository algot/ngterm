import XCTest

/// A session opened with a hardware keyboard takes the keyboard at once, with no tap on it.
///
/// As Android's `FollowFocus` does, its selected pane's terminal takes it, or its chat's prompt field when the pane
/// shows its chat. The fake core's `split` (`-ngterm-fake-session`): each pane names itself on its first line ("P1
/// ready") and echoes what it was typed on its second ("$ ls"); New session there opens `session 1`, of one pane, `P1`
/// too. The simulator has the Mac's keyboard attached, so each test runs with a hardware keyboard; the session moves'
/// chords chaining is SessionViewTests'.
internal final class SessionKeyboardTests: XCTestCase {
    private static let wait: TimeInterval = 15

    // the terminal whose screen names the pane `pane` and shows `typed` after its prompt (VoiceOver's value of it,
    // which leaves out a line's trailing space)
    @MainActor
    private static func screen(_ pane: String, in app: XCUIApplication, typed: String = "") -> XCUIElement {
        let prompt = typed.isEmpty ? "$" : "$ \(typed)"
        let shows = NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@", "\(pane) ready", prompt)
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

    // opens the session `id` again by its row in the machine's sessions: a phone goes back to them first, a tablet
    // lists them beside the session
    @MainActor
    private static func reopen(_ id: String, in app: XCUIApplication) {
        let row = app.descendants(matching: .any)["session-\(id)"].firstMatch
        if !row.exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        FakeApp.expect(row, "\(id)'s row")
        row.tap()
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
    // beside it, which takes none; then New session opens a session whose pane takes the typing in its turn, and
    // `work` opened again by its row takes it back
    @MainActor
    internal func testASessionOpenedByItsRowOrNewSessionTakesTheTypingAtOnce() {
        let app = openSplit(arguments: [])
        let row = app.descendants(matching: .any)["session-work"].firstMatch
        FakeApp.expect(row, "work's row")
        row.tap()
        FakeApp.expect(Self.screen("P1", in: app), "work's first pane")
        Self.type("ls", in: app)
        FakeApp.expect(Self.screen("P1", in: app, typed: "ls"), "the typing on work's first pane, with no tap")
        XCTAssertFalse(Self.screen("P2", in: app, typed: "l").exists, "the pane not selected took the typing")
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
        FakeApp.expect(Self.screen("P1", in: app, typed: "pwd"), "the typing on the new session's pane, with no tap")
        Self.expectNoSoftKeyboard(in: app, "on the new session")

        // each opened again by its row takes the typing again: work, then the new session (`fake-1`)
        Self.reopen("work", in: app)
        FakeApp.expect(Self.screen("P1", in: app), "work's first pane again")
        Self.type("cd", in: app)
        let again = NSPredicate(format: "value CONTAINS 'P1 ready' AND value CONTAINS 'cd'")
        FakeApp.expect(app.textViews.matching(again).firstMatch, "the typing on work opened again, with no tap")
        Self.reopen("fake-1", in: app)
        FakeApp.expect(Self.screen("F1", in: app, typed: "pwd"), "the new session's pane again")
        Self.type("ls", in: app)
        FakeApp.expect(Self.screen("F1", in: app, typed: "pwdls"), "the typing on the new session opened again")
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
