/// Where an export goes.
public enum ExportAction: Hashable, Sendable {
    /// To the clipboard.
    case copy
    /// To a file the user places.
    case save
}
