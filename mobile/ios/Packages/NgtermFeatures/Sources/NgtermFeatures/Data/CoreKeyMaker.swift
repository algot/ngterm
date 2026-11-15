import Foundation
import NgtermCore

/// The core's key functions (``CoreKeys``): the app's ``KeyMaker``.
public struct CoreKeyMaker: KeyMaker {
    /// How many characters the core wants of an export's passphrase.
    public var exportPassphraseMinimum: Int {
        CoreKeys.exportPassphraseMinimum
    }

    /// The core's key functions.
    public init() {
        // nothing to hold: the functions are the core's
    }

    /// A new ed25519 key from the core.
    public func generate(comment: String) throws -> KeyPair {
        try CoreKeys.generate(comment: comment)
    }

    /// The key the user brought, read by the core.
    public func importKey(privateKey: Data, passphrase: String?) throws -> KeyPair {
        try CoreKeys.importKey(privateKey: privateKey, passphrase: passphrase)
    }

    /// The stored key as an OpenSSH private key file, written by the core.
    public func exportKey(privateKey: Data, protection: ExportProtection) throws -> Data {
        try CoreKeys.exportKey(privateKey: privateKey, protection: protection)
    }

    /// Whether the core refuses `passphrase` as too short.
    public func isExportPassphraseTooShort(_ passphrase: String) -> Bool {
        CoreKeys.isExportPassphraseTooShort(passphrase)
    }
}
