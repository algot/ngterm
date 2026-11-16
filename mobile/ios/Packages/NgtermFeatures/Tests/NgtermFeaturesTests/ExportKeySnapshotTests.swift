import Foundation
import NgtermPlatform
import SwiftUI
import Testing

@testable import NgtermFeatures

/// Goldens of a key's export: as it opens, with what is wrong with the passphrase, its passphrases shown, without a
/// passphrase, once the key was saved, and covered while the screen is recorded.
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

    // the page in front of the user, its screen captured or not
    private func page(
        _ model: ExportKeyModel,
        _ key: AppKey,
        isPassphraseShown: Bool = false,
        captured: Bool = false
    ) -> some View {
        NavigationStack {
            ExportKeyView(model: model, key: key, isPassphraseShown: isPassphraseShown)
        }
        .environment(\.scenePhase, .active)
        .environment(\.isSceneCaptured, captured)
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

    @Test("Show writes out what was typed under each secure field")
    internal func shownPassphrase() async throws {
        defer { test.remove() }
        let (model, key) = try await unlocked()
        model.draft.passphrase = FakeKeyMaker.passphrase
        model.draft.again = "not the same"
        ScreenSnapshot.check(
            page(model, key, isPassphraseShown: true),
            named: "export-key-shown",
            variant: .light
        )
    }

    @Test("a recorded or shared screen shows a plain cover in place of the page")
    internal func captured() async throws {
        defer { test.remove() }
        let (model, key) = try await unlocked()
        model.draft.passphrase = FakeKeyMaker.passphrase
        model.draft.again = FakeKeyMaker.passphrase
        ScreenSnapshot.check(
            page(model, key, isPassphraseShown: true, captured: true),
            named: "export-key-captured",
            variant: .light
        )
    }

    @Test("the page is covered whenever the app isn't in front, and while the screen is captured")
    internal func coveredWhen() {
        defer { test.remove() }
        #expect(!ExportKeyView.isCovered(phase: .active, captured: false))
        #expect(ExportKeyView.isCovered(phase: .active, captured: true))
        #expect(ExportKeyView.isCovered(phase: .inactive, captured: false))
        #expect(ExportKeyView.isCovered(phase: .background, captured: false))
    }
}
