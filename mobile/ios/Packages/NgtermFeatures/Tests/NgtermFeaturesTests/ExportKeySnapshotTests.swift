import Foundation
import NgtermPlatform
import SwiftUI
import Testing

@testable import NgtermFeatures

/// Goldens of a key's export: as it opens, with what is wrong with the passphrase, without a passphrase, and once the
/// key was saved.
@MainActor
@Suite("key export snapshots")
internal struct ExportKeySnapshotTests {
    private let test = TestGraph()

    // the export of the app's key, its owner having unlocked it
    private func unlocked() async throws -> (ExportKeyModel, AppKey) {
        let key = try await test.seedKey()
        let model = ExportKeyModel(keys: test.graph.keys, services: test.graph.exports)
        await model.start(keyId: key.id)
        return (model, key)
    }

    private func page(_ model: ExportKeyModel, _ key: AppKey) -> some View {
        NavigationStack {
            ExportKeyView(model: model, key: key)
        }
    }

    @Test("the export as it opens", arguments: ScreenVariant.allCases)
    internal func fresh(variant: ScreenVariant) async throws {
        defer { test.remove() }
        let (model, key) = try await unlocked()
        ScreenSnapshot.check(page(model, key), named: "export-key", variant: variant)
    }

    @Test("a passphrase too short, said under its field once an export was tried")
    internal func shortPassphrase() async throws {
        defer { test.remove() }
        let (model, key) = try await unlocked()
        model.draft.passphrase = "seven77"
        model.draft.again = "seven77"
        await model.tap(.save)
        ScreenSnapshot.check(page(model, key), named: "export-key-short", variant: .light)
    }

    @Test("the export without a passphrase, with its warning", arguments: ScreenVariant.allCases)
    internal func unprotected(variant: ScreenVariant) async throws {
        defer { test.remove() }
        let (model, key) = try await unlocked()
        model.draft.isUnprotected = true
        ScreenSnapshot.check(page(model, key), named: "export-key-unprotected", variant: variant)
    }

    @Test("a saved key: what to do next", arguments: ScreenVariant.allCases)
    internal func saved(variant: ScreenVariant) async throws {
        defer { test.remove() }
        let (model, key) = try await unlocked()
        model.draft.passphrase = FakeKeyMaker.passphrase
        model.draft.again = FakeKeyMaker.passphrase
        await model.tap(.save)
        model.placed(.success(URL(filePath: "/placed/ngterm-private-key")))
        ScreenSnapshot.check(page(model, key), named: "export-key-saved", variant: variant)
    }
}
