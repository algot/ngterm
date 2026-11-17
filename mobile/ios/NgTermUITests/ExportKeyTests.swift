import XCTest

/// A key's export on the fake core, whose device's owner confirms at once (mobile/android's `KeyExport*E2eTest`s): a
/// key made on the first run is saved under a passphrase through the system's file screen and Import a key reads the
/// file back as the same key; a save left without a place says nothing; an export without a passphrase warns and
/// asks again, and the page left forgets it; a device with no passcode exports nothing; a check that failed opens
/// the export on Try again.
///
/// The key is the core's own (made by the first run, kept in memory), so the file holds a real export. It is saved
/// under a name of this run's own, and removed after it.
internal final class ExportKeyTests: XCTestCase {
    private static let passphrase = "correct horse battery"
    // how many swipes a row far down the form may take to come into view
    private static let swipes = 12
    // how long the system's file screen may take to come or go
    private static let wait: TimeInterval = 30
    private static let nameLength = 8
    // how often, and how many times at most, a button is read while the file screen settles
    private static let settleBeat: TimeInterval = 0.5
    private static let settleReads = 20
    // where a drag of the file screen's bar starts, and how long it is held first
    private static let middle: CGFloat = 0.5
    private static let dragPress: TimeInterval = 0.1

    private let fileName = "ngterm-key-\(UUID().uuidString.prefix(ExportKeyTests.nameLength).lowercased())"

    // removes this run's file from the simulator's local file storage, where the system's file screen put it: the
    // simulator's processes share the host's files, so the storage is found from the runner's own home
    private static func removeSavedFile(named fileName: String) {
        let home = NSHomeDirectory()
        guard let containers = home.range(of: "/data/Containers/") else {
            return
        }
        let groups = URL(filePath: String(home[..<containers.upperBound]) + "Shared/AppGroup")
        let files = FileManager.default
        for group in (try? files.contentsOfDirectory(at: groups, includingPropertiesForKeys: nil)) ?? [] {
            let storage = group.appending(path: "File Provider Storage")
            guard let found = files.enumerator(at: storage, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let file as URL in found where file.lastPathComponent.hasPrefix(fileName) {
                try? files.removeItem(at: file)
            }
        }
    }

    // the app past a first run that made a key, Settings open
    @MainActor
    private func openSettings(arguments: [String]) -> XCUIApplication {
        let app = FakeApp.launch(withKey: false, arguments: arguments, for: self)
        let create = app.buttons["create-key"]
        FakeApp.expect(create, "Create a key")
        create.tap()
        let done = app.buttons["key-done"]
        FakeApp.expect(done, "the new key's public half")
        done.tap()
        FakeApp.showMachines(in: app)
        app.buttons["settings"].tap()
        FakeApp.expect(app.navigationBars["Settings"], "Settings")
        return app
    }

    // swipes Settings' form up until `element` is on screen
    @MainActor
    private func scroll(to element: XCUIElement, in app: XCUIApplication) {
        let form = app.collectionViews["settings-form"]
        for _ in 0..<Self.swipes where !(element.exists && element.isHittable) {
            form.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "\(element) never came into view")
    }

    // Settings' Export private key of the app's one key, tapped
    @MainActor
    private func tapExport(in app: XCUIApplication) {
        let export = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'export-key-'")).firstMatch
        scroll(to: export, in: app)
        export.tap()
    }

    // the export screen of the app's key, its owner having confirmed
    @MainActor
    private func openExport() -> XCUIApplication {
        let app = openSettings(arguments: ["-ngterm-fake-export-name", fileName])
        tapExport(in: app)
        FakeApp.expect(app.navigationBars["Export private key"], "the export screen")
        return app
    }

    // types the passphrase into both fields, closing the keyboard after the second
    @MainActor
    private func typePassphrase(_ passphrase: String, in app: XCUIApplication) {
        let first = app.secureTextFields["export-passphrase"]
        FakeApp.expect(first, "the passphrase field")
        first.tap()
        first.typeText(passphrase)
        let again = app.secureTextFields["export-passphrase-again"]
        again.tap()
        again.typeText(passphrase + "\n")
    }

    // the button of the system's file screen that places the file (Save)
    @MainActor
    private func placeButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons["DOCPicker.actionButton"]
    }

    // waits for the system's file screen to take taps: its Save enabled and still. The screen can take seconds to
    // lay out, and a tap that lands while its toolbar still moves opens a neighbouring button's menu instead
    @MainActor
    private func awaitFileScreen(in app: XCUIApplication, _ what: String) -> XCUIElement {
        let place = placeButton(in: app)
        FakeApp.expect(place, what)
        var before = CGRect.null
        for _ in 0..<Self.settleReads {
            let now = place.frame
            if place.isEnabled, place.isHittable, now == before {
                break
            }
            before = now
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "a beat")], timeout: Self.settleBeat)
        }
        return place
    }

    // leaves the system's file screen without a place for the file: its Cancel where it has one, else the sheet
    // swiped down by its bar, as a user lets it go
    @MainActor
    private func cancelFileScreen(in app: XCUIApplication) {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists {
            cancel.tap()
            return
        }
        let bar = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        let start = bar.coordinate(withNormalizedOffset: CGVector(dx: Self.middle, dy: Self.middle))
        let foot = app.coordinate(withNormalizedOffset: CGVector(dx: Self.middle, dy: 1))
        start.press(forDuration: Self.dragPress, thenDragTo: foot)
    }

    // waits for the system's file screen to go, the export screen taking taps again
    @MainActor
    private func expectFileScreenGone(in app: XCUIApplication) {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: app.buttons["export-copy"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: Self.wait), .completed, "the file screen stayed")
    }

    @MainActor
    internal func testAKeySavedUnderAPassphraseImportsBackAsTheSameKey() throws {
        let saved = fileName
        addTeardownBlock {
            Self.removeSavedFile(named: saved)
        }
        let app = openExport()
        let page = app.scrollViews["export-key-page"]
        try FakeApp.auditSheet(app, page: page)
        let fingerprint = try XCTUnwrap(
            page.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'SHA256:'")).firstMatch.label
        )

        // nothing is saved under a passphrase too short
        app.buttons["export-save"].tap()
        FakeApp.expect(FakeApp.element(containing: "Use at least 8 characters.", in: app), "the short passphrase")
        XCTAssertFalse(placeButton(in: app).exists)

        typePassphrase(Self.passphrase, in: app)
        app.buttons["export-save"].tap()
        awaitFileScreen(in: app, "the system's file screen").tap()
        expectFileScreenGone(in: app)
        FakeApp.expect(app.staticTexts["Saved"], "that the key was saved")

        // a second save left without a place no longer says Saved
        app.buttons["export-save"].tap()
        _ = awaitFileScreen(in: app, "the system's file screen again")
        cancelFileScreen(in: app)
        expectFileScreenGone(in: app)
        XCTAssertFalse(app.staticTexts["Saved"].exists, "a cancelled save still says Saved")

        // Import a key reads the file back, once it has the passphrase
        app.navigationBars["Export private key"].buttons.element(boundBy: 0).tap()
        let importKey = app.buttons["import-key"]
        scroll(to: importKey, in: app)
        importKey.tap()
        FakeApp.expect(app.navigationBars["Import a key"], "the import screen")
        app.buttons["Choose file"].tap()
        FileScreen.choose(fileStartingWith: fileName, in: app)
        FakeApp.expect(
            FakeApp.element(containing: "This key is protected: enter its passphrase.", in: app),
            "that the file is under a passphrase"
        )
        let field = app.secureTextFields["passphrase"]
        field.tap()
        field.typeText(Self.passphrase + "\n")
        app.buttons["import-key-action"].tap()
        FakeApp.expect(app.navigationBars["Public key"], "the imported key's public half")
        FakeApp.expect(FakeApp.element(containing: fingerprint, in: app), "the exported key's fingerprint")
    }

    @MainActor
    internal func testAnExportWithoutAPassphraseWarnsAndAsksAgain() {
        let app = openExport()
        let unprotected = app.switches["export-unprotected"]
        FakeApp.expect(unprotected, "Export without a passphrase")
        let isOn = NSPredicate(format: "value == '1'")
        for _ in 0..<3 where unprotected.value as? String != "1" {
            unprotected.switches.firstMatch.press(forDuration: 0.6)
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: isOn, object: unprotected)], timeout: 3)
        }
        XCTAssertEqual(unprotected.value as? String, "1")
        FakeApp.expect(app.staticTexts["The exported key won't be encrypted"], "the warning")
        XCTAssertFalse(app.secureTextFields["export-passphrase"].exists)

        app.buttons["export-copy"].tap()
        FakeApp.expect(app.staticTexts["Export without a passphrase?"], "the last question")
        XCTAssertFalse(app.staticTexts["Copied"].exists)
        app.buttons["Export without a passphrase"].firstMatch.tap()
        FakeApp.expect(app.staticTexts["Copied"], "that the key was copied")

        // leaving the page forgets it: opened again, it asks for a passphrase and says nothing was copied
        app.navigationBars["Export private key"].buttons.element(boundBy: 0).tap()
        FakeApp.expect(app.navigationBars["Settings"], "Settings again")
        tapExport(in: app)
        FakeApp.expect(app.secureTextFields["export-passphrase"], "the passphrase field, the switch off again")
        XCTAssertEqual(unprotected.value as? String, "0")
        XCTAssertFalse(app.staticTexts["Copied"].exists, "the page still says Copied")
    }

    @MainActor
    internal func testADeviceWithNoPasscodeExportsNothing() {
        let app = openSettings(arguments: ["-ngterm-fake-no-passcode"])
        tapExport(in: app)
        FakeApp.expect(app.staticTexts["Set a passcode first"], "that a passcode is needed")
        app.buttons["OK"].tap()
        XCTAssertFalse(app.navigationBars["Export private key"].exists)
    }

    @MainActor
    internal func testTryAgainAfterAFailedCheckOpensTheExport() {
        let app = openSettings(arguments: ["-ngterm-fake-auth-fails-once"])
        tapExport(in: app)
        FakeApp.expect(app.staticTexts["Couldn't confirm it's you"], "that the check failed")
        XCTAssertFalse(app.navigationBars["Export private key"].exists)
        app.buttons["Try again"].tap()
        FakeApp.expect(app.navigationBars["Export private key"], "the export screen after Try again")
    }

    deinit {
        // nothing to release: XCTest owns the app it launched
    }
}
