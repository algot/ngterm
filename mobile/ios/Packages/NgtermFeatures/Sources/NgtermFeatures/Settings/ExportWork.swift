import Foundation

/// Where exporting a key stands (mobile/android's `ExportWork`).
public struct ExportWork: Hashable, Sendable {
    /// The key being exported, once its owner has confirmed it is them; none otherwise.
    public var keyId: String?
    /// An export is under way: being written, or waiting in the system's file screen.
    public var isBusy = false
    /// Where the last export went, if it went.
    public var done: ExportDone?
    /// Why the last export didn't happen.
    public var problem: ExportProblem?
    /// The file the system's screen is asked to place, while it is up.
    public var staged: URL?

    /// Nothing unlocked, nothing under way.
    public init() {
        // every part starts at its default
    }
}
