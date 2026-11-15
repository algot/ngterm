/// Where the last export went (mobile/android's `ExportDone`).
public enum ExportDone: Hashable, Sendable {
    /// Onto the clipboard.
    case copied
    /// Into the file the user placed.
    case saved

    /// What the screen says, and what to do next.
    public var words: (message: String, note: String) {
        switch self {
        case .saved:
            (String(localized: "Saved"), String(localized: "Delete the file once you've imported the key."))

        case .copied:
            (
                String(localized: "Copied"),
                String(
                    localized: """
                        Paste it where it's going: ngterm clears it from the clipboard when you close this screen.
                        """
                )
            )
        }
    }
}
