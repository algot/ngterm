/// What exporting a key needs of the platform: the owner's proof, the clipboard, and the staged file.
@preconcurrency
@MainActor
public struct KeyExportServices {
    /// Asks the device's owner to prove it is them.
    public let auth: any DeviceAuth
    /// Where a copied key goes.
    public let clipboard: any KeyClipboard
    /// Where a key waits for the system's file screen.
    public let files: KeyExportFiles

    /// The system's: LocalAuthentication, the general pasteboard, the app's temporary directory.
    public init() {
        self.init(auth: SystemDeviceAuth(), clipboard: SystemKeyClipboard(), files: KeyExportFiles())
    }

    /// The services given (a test's, the fake world's).
    public init(auth: any DeviceAuth, clipboard: any KeyClipboard, files: KeyExportFiles) {
        self.auth = auth
        self.clipboard = clipboard
        self.files = files
    }
}
