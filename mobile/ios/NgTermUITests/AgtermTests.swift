import XCTest

/// A Mac running agterm on the fake core.
///
/// `studio`, whose one session `notes` runs Claude Code in its pane (the app's `FakeAgtermWorld`). Its row, its
/// sessions screen and its session view say it runs agterm; its sessions list, attach and end as an ngterm machine's
/// do; and its pane keeps showing the terminal: agterm has no chat view, so Chat view is off and takes no tap, and no
/// view switch offers a chat. Beside it, an ngterm machine keeps no badge and its chat view; and on a Mac running both
/// apps, only the agterm session has the badge and no chat view.
internal final class AgtermTests: XCTestCase {
    // how long a view that should not come is watched for
    private static let steady: TimeInterval = 3
    // how long a press on a row holds to bring up its context menu
    private static let longPress: TimeInterval = 1
    // where a tap closes the menu that is up: below it
    private static let offMenu = CGVector(dx: 0.5, dy: 0.9)

    @MainActor
    private static func any(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private static func labelled(
        _ identifier: String,
        containing text: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", identifier, text))
            .firstMatch
    }

    // a phone goes back from the session and the machine's sessions to the machines; a tablet shows them beside it
    @MainActor
    private static func backToMachines(in app: XCUIApplication) {
        let add = app.buttons["add-machine"]
        for _ in 0..<2 where !add.exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        FakeApp.expect(add, "the machines")
    }

    // the terminal whose screen shows `text` (VoiceOver's value of it)
    @MainActor
    private static func terminal(showing text: String, in app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
    }

    @MainActor
    internal func testAnAgtermMacSaysSoAndItsPaneKeepsTheTerminal() throws {
        let app = FakeApp.launch(withKey: true, arguments: ["-ngterm-fake-agterm"], for: self)
        FakeApp.showMachines(in: app)
        FakeApp.expectRow("studio", reads: "Connected", in: app)
        FakeApp.expect(Self.labelled("machine-row-studio", containing: "agterm", in: app), "the row's agterm badge")
        try FakeApp.audit(app)

        Self.any("machine-row-studio", in: app).tap()
        let row = Self.any("session-notes", in: app)
        FakeApp.expect(row, "the session's row")
        FakeApp.expect(
            FakeApp.element(containing: "studio, nick at studio.lan, port 22, agterm", in: app),
            "the title's agterm badge"
        )
        let note = Self.labelled("sessions-peer-note", containing: "the agent chat view", in: app)
        FakeApp.expect(note, "what agterm lacks, under the list")
        try FakeApp.audit(app)

        row.tap()
        FakeApp.expect(Self.labelled("session-title", containing: "agterm", in: app), "the session's agterm badge")
        let screen = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "agterm$")).firstMatch
        FakeApp.expect(screen, "the pane's terminal")
        let chat = Self.any("chat", in: app)
        let viewSwitch = Self.any("session-view-switch", in: app)
        XCTAssertFalse(chat.waitForExistence(timeout: Self.steady), "the pane showed a chat")
        XCTAssertFalse(viewSwitch.exists, "a view switch offered a chat")
        try FakeApp.audit(app)

        app.buttons["session-menu"].tap()
        let chatView = Self.any("session-chat-view", in: app)
        FakeApp.expect(chatView, "Chat view in More")
        XCTAssertFalse(chatView.isEnabled, "Chat view took a tap on agterm")
        let end = app.buttons["session-end"]
        end.tap()
        FakeApp.expect(FakeApp.element(containing: "End notes?", in: app), "End session confirmation")
        let confirm = app.buttons.matching(identifier: "End session").allElementsBoundByIndex.first(where: \.isHittable)
        try XCTUnwrap(confirm, "no End session in the confirmation").tap()
        FakeApp.expect(FakeApp.element(containing: "No sessions on studio", in: app), "the list without the session")
    }

    // with an ngterm machine beside it, `split` (the app's `FakeSessionWorld`, its session `work` running Claude Code):
    // the agterm session's context menu in the list offers Chat view off and greyed, saying why, and attaches it;
    // `split` keeps no badge, no note and its chat view, from the same menu
    @MainActor
    internal func testBesideAnNgtermMachineOnlyAgtermsSessionsGoWithoutChat() {
        let arguments = ["-ngterm-fake-session", "-ngterm-fake-chat", "-ngterm-fake-agterm"]
        let app = FakeApp.launch(withKey: true, arguments: arguments, for: self)
        FakeApp.showMachines(in: app)
        FakeApp.expectRow("studio", reads: "Connected", in: app)
        FakeApp.expectRow("split", reads: "Connected", in: app)
        FakeApp.expect(Self.labelled("machine-row-studio", containing: "agterm", in: app), "the row's agterm badge")
        XCTAssertFalse(Self.any("machine-row-split", in: app).label.contains("agterm"), "split's row has a badge")

        Self.any("machine-row-studio", in: app).tap()
        let notes = Self.any("session-notes", in: app)
        FakeApp.expect(notes, "notes's row")
        notes.press(forDuration: Self.longPress)
        let chatView = Self.any("session-chat-view", in: app)
        FakeApp.expect(chatView, "Chat view in the row's menu")
        XCTAssertFalse(chatView.isEnabled, "Chat view took a tap on agterm")
        FakeApp.expect(FakeApp.element(containing: "agterm has no chat view", in: app), "why Chat view is off")
        app.buttons["Attach"].tap()
        FakeApp.expect(Self.labelled("session-title", containing: "agterm", in: app), "notes's agterm badge")
        FakeApp.expect(Self.terminal(showing: "agterm$", in: app), "notes's terminal")
        XCTAssertFalse(Self.any("chat", in: app).waitForExistence(timeout: Self.steady), "notes showed a chat")

        Self.backToMachines(in: app)
        Self.any("machine-row-split", in: app).tap()
        let work = Self.any("session-work", in: app)
        FakeApp.expect(work, "work's row")
        FakeApp.expect(FakeApp.element(containing: "split, nick at split.lan, port 22", in: app), "split's title")
        XCTAssertFalse(FakeApp.element(containing: "split.lan, port 22, agterm", in: app).exists, "split's badge")
        XCTAssertFalse(Self.any("sessions-peer-note", in: app).exists, "split's list says what agterm lacks")
        work.press(forDuration: Self.longPress)
        FakeApp.expect(chatView, "Chat view in work's menu")
        XCTAssertTrue(chatView.isEnabled, "split's Chat view takes no tap")
        XCTAssertFalse(FakeApp.element(containing: "has no chat view", in: app).exists, "split says it has no chat")
        app.buttons["Attach"].tap()
        FakeApp.expect(Self.any("chat", in: app), "work's chat")
        FakeApp.expect(Self.any("session-title", in: app), "work's title")
        XCTAssertFalse(Self.any("session-title", in: app).label.contains("agterm"), "work's title has a badge")
    }

    // `studio-off` (the app's `FakeAgtermWorld`), whose agterm is not in Live sessions mode: its sessions screen says
    // why it lists nothing, over the empty state, and New session is still offered
    @MainActor
    internal func testAnAgtermOutsideLiveSessionsModeSaysWhyItListsNothing() throws {
        let app = FakeApp.launch(withKey: true, arguments: ["-ngterm-fake-agterm-not-live"], for: self)
        FakeApp.showMachines(in: app)
        FakeApp.expectRow("studio-off", reads: "Connected", in: app)
        Self.any("machine-row-studio-off", in: app).tap()
        FakeApp.expect(FakeApp.element(containing: "No sessions on studio-off", in: app), "the empty state")
        let hint = FakeApp.element(containing: "agterm on studio-off is not in Live sessions mode", in: app)
        FakeApp.expect(hint, "why agterm lists nothing")
        XCTAssertTrue(hint.label.contains("Set Settings > General > Restore sessions to Live sessions"), hint.label)
        try FakeApp.audit(app)
    }

    // `duo` (the app's `FakeAgtermWorld`) runs agterm beside ngterm, Claude Code in each session's pane: the machine
    // has no badge, `journal` (agterm's) has one in its row and its title, its Chat view is off and greyed, saying
    // why, in the row's menu and in More, and its pane keeps the terminal; `build` (ngterm's) has no badge and shows
    // its chat
    @MainActor
    internal func testOnAMacRunningBothOnlyTheAgtermSessionHasTheBadgeAndNoChat() throws {
        let app = FakeApp.launch(withKey: true, arguments: ["-ngterm-fake-agterm-beside"], for: self)
        FakeApp.showMachines(in: app)
        FakeApp.expectRow("duo", reads: "Connected", in: app)
        XCTAssertFalse(Self.any("machine-row-duo", in: app).label.contains("agterm"), "duo's row has a badge")

        Self.any("machine-row-duo", in: app).tap()
        let journal = Self.labelled("session-journal", containing: "agterm", in: app)
        FakeApp.expect(journal, "journal's agterm badge")
        let build = Self.any("session-build", in: app)
        FakeApp.expect(build, "build's row")
        XCTAssertFalse(build.label.contains("agterm"), "build's row has a badge")
        FakeApp.expect(FakeApp.element(containing: "duo, nick at duo.lan, port 22", in: app), "duo's title")
        XCTAssertFalse(FakeApp.element(containing: "duo.lan, port 22, agterm", in: app).exists, "duo's title badge")
        let note = Self.labelled("sessions-peer-note", containing: "the agent chat view", in: app)
        FakeApp.expect(note, "what agterm lacks, under the list")
        try FakeApp.audit(app)

        journal.press(forDuration: Self.longPress)
        let chatView = Self.any("session-chat-view", in: app)
        FakeApp.expect(chatView, "Chat view in journal's menu")
        XCTAssertFalse(chatView.isEnabled, "journal's Chat view took a tap")
        FakeApp.expect(FakeApp.element(containing: "agterm has no chat view", in: app), "why Chat view is off")
        app.buttons["Attach"].tap()
        FakeApp.expect(Self.labelled("session-title", containing: "agterm", in: app), "journal's agterm badge")
        FakeApp.expect(Self.terminal(showing: "duo-journal$", in: app), "journal's terminal")
        XCTAssertFalse(Self.any("chat", in: app).waitForExistence(timeout: Self.steady), "journal showed a chat")
        XCTAssertFalse(Self.any("session-view-switch", in: app).exists, "a view switch offered journal a chat")
        try FakeApp.audit(app)
        app.buttons["session-menu"].tap()
        FakeApp.expect(chatView, "Chat view in journal's More")
        XCTAssertFalse(chatView.isEnabled, "journal's Chat view in More took a tap")
        // a tap beside the menu closes it
        app.windows.firstMatch.coordinate(withNormalizedOffset: Self.offMenu).tap()

        Self.backToMachines(in: app)
        Self.any("machine-row-duo", in: app).tap()
        FakeApp.expect(build, "build's row")
        build.press(forDuration: Self.longPress)
        FakeApp.expect(chatView, "Chat view in build's menu")
        XCTAssertTrue(chatView.isEnabled, "build's Chat view takes no tap")
        XCTAssertFalse(FakeApp.element(containing: "has no chat view", in: app).exists, "build says it has no chat")
        app.buttons["Attach"].tap()
        FakeApp.expect(Self.any("chat", in: app), "build's chat")
        let title = Self.any("session-title", in: app)
        FakeApp.expect(title, "build's title")
        XCTAssertFalse(title.label.contains("agterm"), "build's title has a badge")
    }

    deinit {
        // nothing to release: XCTest owns the app it launched
    }
}
