import Foundation
import NgtermCore

/// Makes, reads and exports ssh keys: the core's (``CoreKeyMaker``) in the app, a fake in its tests.
///
/// ``AppKeys`` calls it off the main actor: reading or writing a key under a passphrase takes a while on purpose.
public protocol KeyMaker: Sendable {
    /// How many characters an export's passphrase needs at least.
    var exportPassphraseMinimum: Int { get }

    /// A new ed25519 key, its public half commented `comment`.
    ///
    /// - Throws: ``KeyError/Invalid(reason:)`` when the key can't be made.
    func generate(comment: String) throws -> KeyPair

    /// The key in `privateKey`, opened with `passphrase` when it is encrypted.
    ///
    /// - Throws: ``KeyError/PassphraseRequired``, ``KeyError/WrongPassphrase`` or ``KeyError/Invalid(reason:)``.
    func importKey(privateKey: Data, passphrase: String?) throws -> KeyPair

    /// The stored key `privateKey` as an OpenSSH private key file, under `protection`.
    ///
    /// - Throws: ``KeyError/PassphraseTooShort(minimum:)`` or ``KeyError/Invalid(reason:)``.
    func exportKey(privateKey: Data, protection: ExportProtection) throws -> Data

    /// Whether an export refuses `passphrase` as too short, as the exporter counts it.
    func isExportPassphraseTooShort(_ passphrase: String) -> Bool
}
