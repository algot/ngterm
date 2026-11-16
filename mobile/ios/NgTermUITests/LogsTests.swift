import XCTest

/// Settings > Logs on the fake core, with the core's own log in a directory the test reads (mobile/android's
/// `AppLogsE2eTest` and `AppLogsPrivacyE2eTest`).
///
/// The page shows its own newest line as it opens, copies the lines shown, shares the log through the system's share
/// sheet and clears it after asking. A troubleshooting session (a key imported with its passphrase, a chat message
/// sent to the agent, text typed into the terminal) is then told in the log, newest first, while none of what was
/// typed, sent or imported is in the lines shown, in what Copy takes, in the file Share writes or in the log's files.
internal final class LogsTests: XCTestCase {
    private static let wait: TimeInterval = 15
    private static let swipes = 12
    private static let offerWait: TimeInterval = 5
    private static let tries = 3

    // what must be in no form of the log
    private static let typed = "qa-typed-mk9x"
    private static let chatMarker = "qa-chat-mk3p"
    private static let chatText = "\(chatMarker) please look at the build"
    private static let passphrase = "qa-pass-mk7r"
    // a key made for this test alone (ssh-keygen, ed25519, under `passphrase`), never a machine's
    private static let key = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCWngIYVP
        VfoDphEkgjvf91AAAAIAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIAQf4nqcnoLFMdd2
        Oiv6z8HrIpFslGrrx4lZRZnMxyJbAAAAkNAV6oDZnuBaC4bgT40ab7mXuhc3SFz+az1Yhh
        I+o77Iyh5R6zc8eqAt77knhwXoO4xwYTrz9Kksmzjq/FL34xgQGcxBWPjJwiAGgYZpHpTe
        G3YEmpNoPCh4DIdIPAi0iglvnx53LueqWq6bk8b4WnC3LeyHiiq+ruDes7AXg8Jwrh3Mar
        j+YSTabiXDgS4ZmQ==
        -----END OPENSSH PRIVATE KEY-----
        """
    private static let fingerprint = "b2HWDf9FyXwRq12b914kfeYPm0qpzJF8WiUKuHlr8Ag"
    // what the log tells of the session, oldest first
    private static let told = [
        "destination=settings",
        "settings page=import",
        "settings page=key",
        "destination=session",
        "action result=sent",
        "settings page=logs",
    ]

    // the log's lines as the page shows them (each row's words), top first, from one snapshot of the page: elements
    // bound by index are found again one at a time, and a row that goes in between (Clear) fails the test
    @MainActor
    private static func shownLines(in app: XCUIApplication) -> [String] {
        guard let page = try? app.snapshot() else {
            return []
        }
        return lines(under: page)
    }

    @MainActor
    private static func lines(under node: any XCUIElementSnapshot) -> [String] {
        node.identifier == "log-line" ? [node.label] : node.children.flatMap { lines(under: $0) }
    }

    // waits until the page's top line holds `text`
    @MainActor
    private static func expectNewest(_ text: String, in app: XCUIApplication) {
        let newest = NSPredicate { _, _ in shownLines(in: app).first?.contains(text) == true }
        let came = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: newest, object: nil)], timeout: wait)
        XCTAssertEqual(came, .completed, "the newest line is not \"\(text)\": \(shownLines(in: app))")
    }

    // Settings open, then Logs
    @MainActor
    private static func openLogs(in app: XCUIApplication) {
        FakeApp.showMachines(in: app)
        app.buttons["settings"].tap()
        FakeApp.expect(app.navigationBars["Settings"], "Settings")
        enterLogs(in: app)
    }

    // Settings' Logs, from Settings' own page
    @MainActor
    private static func enterLogs(in app: XCUIApplication) {
        let row = app.buttons["settings-logs"]
        reveal(row, in: app)
        row.tap()
        FakeApp.expect(app.navigationBars["Logs"], "Logs")
        FakeApp.expect(FakeApp.element(containing: "It never holds what you type", in: app), "what the log never holds")
    }

    // scrolls Settings' page to `element`: down to its foot, then back up
    @MainActor
    private static func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let form = app.collectionViews["settings-form"]
        for swipe in 0..<(swipes * 2) where !(element.exists && element.isHittable) {
            if swipe < swipes {
                form.swipeUp()
            } else {
                form.swipeDown()
            }
        }
    }

    // the confirmation dialog's own Clear logs, not the page's
    @MainActor
    private static func confirmClear(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == 'Clear logs' AND identifier != 'logs-clear'")).firstMatch
    }

    // the clipboard's text, which Copy put there, as Settings' Import a key takes it in its field: the test runner,
    // in the background, can't read the clipboard itself. Logs is left for Settings' own page, where it ends
    @MainActor
    private static func pasted(in app: XCUIApplication) -> String {
        app.buttons["BackButton"].firstMatch.tap()
        FakeApp.expect(app.navigationBars["Settings"], "Settings")
        let start = app.buttons["import-key"]
        reveal(start, in: app)
        start.tap()
        let field = app.textViews["private-key"]
        FakeApp.expect(field, "the private key's field")
        let menu = NSPredicate(
            format: "label == 'Paste' AND (elementType == %lu OR elementType == %lu)",
            XCUIElement.ElementType.menuItem.rawValue,
            XCUIElement.ElementType.button.rawValue
        )
        let paste = app.descendants(matching: .any).matching(menu).firstMatch
        // a press while the field takes the focus can bring up no menu: press again
        field.tap()
        for _ in 0..<tries where !paste.exists {
            field.press(forDuration: 1.2)
            _ = paste.waitForExistence(timeout: offerWait)
        }
        FakeApp.expect(paste, "the edit menu's Paste")
        paste.tap()
        let filled = NSPredicate { _, _ in !(field.value as? String ?? "").isEmpty }
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: filled, object: nil)], timeout: wait)
        let text = field.value as? String ?? ""
        app.buttons["BackButton"].firstMatch.tap()
        FakeApp.expect(app.navigationBars["Settings"], "Settings")
        return text
    }

    // the share sheet over the app, open and then closed
    @MainActor
    private static func shareAndClose(in app: XCUIApplication) {
        app.buttons["logs-share"].tap()
        let sheet = app.otherElements["ActivityListView"]
        FakeApp.expect(sheet, "the share sheet")
        if UIDevice.current.userInterfaceIdiom == .pad {
            // an iPad's share sheet is a popover, which a tap outside it dismisses
            tapOutsidePopover(in: app)
        } else {
            // a phone's is a sheet over the screen's lower half, which a tap above it dismisses
            app.navigationBars["Logs"].tap()
        }
        XCTAssertTrue(sheet.waitForNonExistence(timeout: wait), "the share sheet stayed")
    }

    // a tap outside an iPad's popover: near the screen's left edge, beside the sheet Settings is in and far from what
    // the popover points at, where its dismiss region takes the tap
    @MainActor
    private static func tapOutsidePopover(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.9)).tap()
    }

    @MainActor
    private static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "ngterm-logs-\(UUID().uuidString)")
    }

    // the log as the app keeps it: its file and the one it rotated to
    private static func logFiles(in directory: URL) -> String {
        files(under: directory.appending(path: "log")).joined(separator: "\n")
    }

    private static func lineCount(in directory: URL) -> Int {
        logFiles(in: directory).split(whereSeparator: \.isNewline).count
    }

    // the file the last Share wrote
    private static func exported(in directory: URL) -> String? {
        files(under: directory.appending(path: "export")).last
    }

    private static func files(under directory: URL) -> [String] {
        let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        return (walk?.allObjects as? [URL] ?? [])
            .filter { !$0.hasDirectoryPath }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    // nothing typed, sent or imported: no typed text, no chat text, no passphrase, no key line, no fingerprint
    private static func assertClean(_ what: String, _ log: String) {
        let secrets = [
            "what was typed in the terminal": typed,
            "the chat message": chatMarker,
            "the passphrase": passphrase,
            "the key's fingerprint": fingerprint,
        ]
        for (name, secret) in secrets {
            XCTAssertFalse(log.contains(secret), "\(what) hold \(name):\n\(log)")
        }
        for line in key.split(separator: "\n") where line.count > 16 && !line.hasPrefix("-----") {
            XCTAssertFalse(log.contains(line), "\(what) hold key material")
        }
        XCTAssertFalse(log.contains("PRIVATE KEY"), "\(what) hold a key's armor")
        XCTAssertFalse(log.contains("SHA256:"), "\(what) hold a fingerprint")
    }

    // `log` tells each of ``told``
    private static func assertTold(_ what: String, _ log: String) {
        for line in told {
            XCTAssertTrue(log.contains(line), "\(what) hold no \"\(line)\":\n\(log)")
        }
    }

    @MainActor
    internal func testLogsShowsItsOwnLineCopiesSharesAndClears() throws {
        let app = FakeApp.launch(withKey: true, for: self)
        Self.openLogs(in: app)
        Self.expectNewest("settings page=logs", in: app)
        // on an iPad's sheet the list runs on past the sheet's foot
        try FakeApp.auditForm(app, page: app.collectionViews["logs-list"])

        app.buttons["logs-copy"].tap()
        FakeApp.expect(app.buttons["Copied"], "Copied")
        Self.expectNewest("copied the shown lines", in: app)
        let copied = Self.pasted(in: app)
        XCTAssertTrue(copied.contains(" I nav: settings page=logs"), "Copy took no line of the log:\n\(copied)")
        Self.enterLogs(in: app)
        Self.expectNewest("settings page=logs", in: app)

        Self.shareAndClose(in: app)

        app.buttons["logs-clear"].tap()
        let confirm = Self.confirmClear(in: app)
        FakeApp.expect(confirm, "Clear logs' question")
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            // an iPad's dialog is a popover, which a tap outside it dismisses
            Self.tapOutsidePopover(in: app)
        }
        XCTAssertTrue(confirm.waitForNonExistence(timeout: Self.wait), "Clear logs' question stayed")
        let kept = Self.shownLines(in: app)
        let isCleared = kept.count < 2 || kept.contains { $0.contains("log cleared") }
        XCTAssertFalse(isCleared, "Cancel cleared the log: \(kept)")

        app.buttons["logs-clear"].tap()
        FakeApp.expect(confirm, "Clear logs' question")
        confirm.tap()
        Self.expectNewest("log cleared", in: app)
        XCTAssertEqual(Self.shownLines(in: app).count, 1, "lines from before the clear: \(Self.shownLines(in: app))")
    }

    @MainActor
    internal func testTheLogTellsWhatHappenedAndHoldsNothingTypedSentOrImported() {
        let directory = Self.directory()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let app = FakeApp.launch(
            withKey: true,
            arguments: ["-ngterm-fake-session", "-ngterm-fake-chat", "-ngterm-fake-log", directory.path],
            for: self
        )
        importKey(in: app)
        sendAndType(in: app, logIn: directory)

        Self.openLogs(in: app)
        Self.expectNewest("settings page=logs", in: app)
        let shown = Self.shownLines(in: app).joined(separator: "\n")
        Self.assertClean("the lines shown", shown)
        XCTAssertTrue(shown.contains("settings page=logs"), "the page shows no line of its own:\n\(shown)")

        app.buttons["logs-copy"].tap()
        FakeApp.expect(app.buttons["Copied"], "Copied")
        let copied = Self.pasted(in: app)
        Self.assertTold("the copied lines", copied)
        Self.assertClean("the copied lines", copied)
        Self.enterLogs(in: app)

        app.buttons["logs-share"].tap()
        let written = NSPredicate { _, _ in Self.exported(in: directory) != nil }
        let came = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: written, object: nil)], timeout: Self.wait)
        XCTAssertEqual(came, .completed, "Share wrote no file")
        let whole = Self.exported(in: directory) ?? ""
        Self.assertTold("the shared file", whole)
        Self.assertClean("the shared file", whole)
        let files = Self.logFiles(in: directory)
        Self.assertTold("the log's files", files)
        Self.assertClean("the log's files", files)
    }

    // Settings > Keys > Import a key, with the test's key and passphrase, to its public half, then Settings closed
    @MainActor
    private func importKey(in app: XCUIApplication) {
        FakeApp.showMachines(in: app)
        app.buttons["settings"].tap()
        let start = app.buttons["import-key"]
        Self.reveal(start, in: app)
        start.tap()
        let field = app.textViews["private-key"]
        FakeApp.expect(field, "the private key's field")
        field.tap()
        field.typeText(Self.key)
        let secret = app.secureTextFields["passphrase"]
        secret.tap()
        secret.typeText(Self.passphrase + "\n")
        app.buttons["import-key-action"].tap()
        FakeApp.expect(app.descendants(matching: .any)["public-key-page"].firstMatch, "the imported key's public half")
        // a phone offers to keep the passphrase in Passwords, over the page
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: Self.offerWait) {
            notNow.tap()
        }
        // a tap while the offer goes can reach nothing: tap Back again
        let done = app.buttons["settings-done"]
        for _ in 0..<Self.tries where !done.exists {
            app.buttons["BackButton"].firstMatch.tap()
            _ = done.waitForExistence(timeout: Self.offerWait)
        }
        FakeApp.expect(done, "Settings' Done")
        app.buttons["settings-done"].tap()
        // a tap while the sheet goes reaches nothing
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: Self.wait), "Settings stayed")
    }

    // a message to `work`'s agent, then text typed into its terminal; the log gains far fewer lines over the typing
    // than the text has letters
    @MainActor
    private func sendAndType(in app: XCUIApplication, logIn directory: URL) {
        FakeApp.showMachines(in: app)
        FakeApp.expectRow("split", reads: "Connected", in: app)
        app.descendants(matching: .any)["machine-row-split"].firstMatch.tap()
        let row = app.descendants(matching: .any)["session-work"].firstMatch
        FakeApp.expect(row, "the session's row")
        row.tap()
        let prompt = app.descendants(matching: .any)["chat-prompt"].firstMatch
        FakeApp.expect(prompt, "the prompt field")
        prompt.tap()
        prompt.typeText(Self.chatText)
        app.buttons["chat-send"].tap()
        FakeApp.expect(FakeApp.element(containing: "Done: \(Self.chatText).", in: app), "the agent's reply")

        app.buttons["session-view-switch"].tap()
        let terminal = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "P1 ready")).firstMatch
        FakeApp.expect(terminal, "the first pane's terminal")
        terminal.tap()
        let before = Self.lineCount(in: directory)
        app.typeText(Self.typed)
        let gained = Self.lineCount(in: directory) - before
        XCTAssertLessThan(gained, Self.typed.count, "the log gained \(gained) lines over \(Self.typed.count) keys")
        // a phone's session is a page of its own over the machines: back to them
        for _ in 0..<Self.tries where !app.buttons["add-machine"].exists {
            app.buttons["BackButton"].firstMatch.tap()
        }
    }

    deinit {
        // nothing to release: XCTest owns the app it launched
    }
}
