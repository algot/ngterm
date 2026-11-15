import Foundation
import NgtermCore
import NgtermFeatures
import NgtermPlatform
import Testing

/// A key's export below the screen: the app's keys hand a kept key to the exporter, and the core writes an OpenSSH
/// private key file its own import reads back.
@MainActor
@Suite("a key's export")
internal struct KeyExportTests {
    private static let passphrase = "correct horse battery"

    private let directory = FileManager.default.temporaryDirectory.appending(
        path: "KeyExportTests-\(UUID().uuidString)"
    )
    private let vault = MemoryPrivateKeys()

    private func keys(maker: any KeyMaker) -> AppKeys {
        AppKeys(store: KeyStore(directory: directory), vault: vault, maker: maker, comment: "ngterm@test")
    }

    @Test("the core's export under a passphrase opens only with it, and gives the same key back")
    internal func coreRoundTrip() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = keys(maker: CoreKeyMaker())
        let made = try await keys.generate()
        var exported = try await keys.export(id: made.id, protection: .passphrase(passphrase: Self.passphrase))
        let text = try #require(String(bytes: exported, encoding: .utf8))
        #expect(text.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"))
        #expect(exported != vault.privateKey(keyId: made.id))
        var unopened = Data([UInt8](exported))
        await #expect(throws: KeyError.PassphraseRequired) {
            try await keys.importKey(privateKey: &unopened, passphrase: nil)
        }
        var wrong = Data([UInt8](exported))
        await #expect(throws: KeyError.WrongPassphrase) {
            try await keys.importKey(privateKey: &wrong, passphrase: "not the passphrase")
        }
        let back = try await keys.importKey(privateKey: &exported, passphrase: Self.passphrase)
        #expect(back.fingerprint == made.fingerprint)
        #expect(back.isImported)
        // the stored key stays where it was
        #expect(vault.keyIds == [made.id, back.id])
    }

    @Test("the core's export without a passphrase imports with none")
    internal func coreUnprotected() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = keys(maker: CoreKeyMaker())
        let made = try await keys.generate()
        var exported = try await keys.export(id: made.id, protection: .unprotected)
        let back = try await keys.importKey(privateKey: &exported, passphrase: nil)
        #expect(back.fingerprint == made.fingerprint)
    }

    @Test("the core refuses a passphrase under its minimum, counted as it counts")
    internal func coreMinimum() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = keys(maker: CoreKeyMaker())
        let made = try await keys.generate()
        let minimum = keys.exportPassphraseMinimum
        #expect(minimum == CoreKeys.exportPassphraseMinimum)
        #expect(minimum > 1)
        let short = String(repeating: "é", count: minimum - 1)
        #expect(keys.isExportPassphraseTooShort(short))
        #expect(!keys.isExportPassphraseTooShort(short + "é"))
        await #expect(throws: KeyError.PassphraseTooShort(minimum: UInt32(minimum))) {
            try await keys.export(id: made.id, protection: .passphrase(passphrase: short))
        }
    }

    @Test("a key the app doesn't keep is missing, and bytes that are no stored key are refused")
    internal func refusals() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = keys(maker: CoreKeyMaker())
        await #expect(throws: VaultError.Missing(keyId: "absent")) {
            try await keys.export(id: "absent", protection: .unprotected)
        }
        var junk = Data("not a key".utf8)
        vault.store(keyId: "junk", privateKey: &junk)
        await #expect(throws: KeyError.self) {
            try await keys.export(id: "junk", protection: .unprotected)
        }
    }
}
