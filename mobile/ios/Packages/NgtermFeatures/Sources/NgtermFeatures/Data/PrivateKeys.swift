import Foundation
import NgtermPlatform

/// Where ``AppKeys`` keeps the private halves of the app's keys: the Keychain (``KeychainKeyVault``) in the app, memory
/// (``MemoryPrivateKeys``) in the tests and on the fake core.
public protocol PrivateKeys: Sendable {
    /// Keeps `privateKey` (OpenSSH form) as `keyId`, then wipes `privateKey`, whether it was kept or not.
    func store(keyId: String, privateKey: inout Data) throws

    /// The private key `keyId` (OpenSSH form), for an export.
    ///
    /// - Throws: the core's `VaultError`: missing when it isn't kept, unavailable when it can't be read.
    func load(keyId: String) throws -> Data

    /// Forgets `keyId`; nothing happens when it isn't kept.
    func delete(keyId: String) throws
}

extension KeychainKeyVault: PrivateKeys {}
