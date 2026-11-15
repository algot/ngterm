import Foundation
import NgtermCoreBindings

/// The core's key functions.
///
/// The app's keys are made, imported and exported in Rust, which hands back the OpenSSH form the ``KeyVault`` keeps.
public enum CoreKeys {
    /// How many characters an export's passphrase needs at least.
    public static var exportPassphraseMinimum: Int {
        Int(exportPassphraseMinChars())
    }

    /// A new ed25519 key, its public half commented `comment` (shown in the machine's `authorized_keys`).
    ///
    /// - Throws: ``KeyError/Invalid(reason:)`` when the key can't be made.
    public static func generate(comment: String) throws -> KeyPair {
        try generateKey(comment: comment)
    }

    /// A key the user imports, as the unencrypted OpenSSH key the app keeps.
    ///
    /// The key may be OpenSSH, PKCS#1 or PKCS#8 PEM, opened with `passphrase` when it is encrypted. The core wipes its
    /// copies of the bytes and the passphrase once read.
    ///
    /// - Throws: ``KeyError/PassphraseRequired``, ``KeyError/WrongPassphrase`` or ``KeyError/Invalid(reason:)``.
    public static func importKey(privateKey: Data, passphrase: String?) throws -> KeyPair {
        try NgtermCoreBindings.importKey(privateKey: privateKey, passphrase: passphrase)
    }

    /// A stored key as an OpenSSH private key file, which ``importKey(privateKey:passphrase:)`` reads back.
    ///
    /// It is encrypted under the passphrase of `protection`, or left as it is stored when the user chose none. The
    /// core wipes its copies of the key and the passphrase once used.
    ///
    /// - Throws: ``KeyError/PassphraseTooShort(minimum:)`` for a passphrase under ``exportPassphraseMinimum``
    ///   characters, ``KeyError/Invalid(reason:)`` for bytes that are not a stored key.
    public static func exportKey(privateKey: Data, protection: ExportProtection) throws -> Data {
        try NgtermCoreBindings.exportKey(privateKey: privateKey, protection: protection)
    }

    /// Whether an export refuses `passphrase` as too short, counted as the core counts it.
    public static func isExportPassphraseTooShort(_ passphrase: String) -> Bool {
        exportPassphraseTooShort(passphrase: passphrase)
    }
}
