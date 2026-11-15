/// Where an exported key is copied to: the system's pasteboard (``SystemKeyClipboard``) in the app, memory in its
/// tests.
@preconcurrency
@MainActor
public protocol KeyClipboard: AnyObject {
    /// Puts the exported key `text` on the clipboard, for this device only and for a while only.
    func copy(_ text: String)

    /// Takes the key last copied back off the clipboard, if it is still what the clipboard holds.
    func clearCopied()
}
