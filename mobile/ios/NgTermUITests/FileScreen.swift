import XCTest

/// The system's file screen that Import a key's Choose file opens.
///
/// The screen opens where it was last, often on Recents. Recents shows a new file only after the system indexes it,
/// so a file saved some seconds before can be missing there (ExportKeyTests on CI, phone and tablet). The export's
/// save puts its file in the device's own storage (On My iPhone, On My iPad), so a test opens that place itself.
internal enum FileScreen {
    // how often, and how many times at most, the screen is read until the file shows
    private static let beat: TimeInterval = 0.5
    private static let reads = 60
    // the device's own storage among the places: its sidebar row on an iPad, its row in a phone's Browse list
    private static let ownStorage = "identifier BEGINSWITH 'DOC.sidebar.item.On My ' OR label BEGINSWITH 'On My '"

    /// Opens the device's own storage, then taps the file whose name starts with `prefix` there.
    ///
    /// Each read finds the elements again. An iPad shows the places in its sidebar, where the open place is
    /// selected. A phone shows them under its Browse tab: once that tab is selected, its list shows the places, or
    /// the place it showed last.
    @MainActor
    internal static func choose(fileStartingWith prefix: String, in app: XCUIApplication) {
        let file = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
            .firstMatch
        let own = app.cells.matching(NSPredicate(format: ownStorage)).firstMatch
        let browse = app.tabBars.buttons["Browse"]
        var opened = false
        for _ in 0..<reads {
            if own.exists, own.isHittable {
                if own.isSelected {
                    opened = true
                } else {
                    own.tap()
                }
            } else if browse.exists, browse.isHittable {
                if browse.isSelected {
                    opened = true
                } else {
                    browse.tap()
                }
            }
            if opened, file.exists, file.isHittable {
                file.tap()
                return
            }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "a beat")], timeout: beat)
        }
        XCTFail("no file \(prefix) in the device's own storage of the system's file screen (opened: \(opened))")
    }
}
