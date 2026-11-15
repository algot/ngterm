import Foundation
import NgtermCore
import NgtermPlatform
import Observation
import Synchronization
import Testing

@testable import NgtermFeatures

/// The rules around a key's export, as mobile/android's `ExportKeyViewModelTest` has them: the passphrase's, the
/// unlock running out, leaving the screen, an export that ends late, and every failure in words.
@MainActor
@Suite("a key export's rules")
internal struct ExportKeyRulesTests {
    private let test = TestGraph()
    private let ticker = Ticker()

    private var staging: URL {
        TestGraph.staging(in: test.directory)
    }

    private func model() -> ExportKeyModel {
        let clock = ticker
        return ExportKeyModel(keys: test.graph.keys, services: test.graph.exports) { clock.now }
    }

    // a model whose owner has unlocked the app's key, the passphrase typed twice
    private func unlocked() async throws -> (ExportKeyModel, AppKey) {
        let key = try await test.seedKey()
        let model = model()
        await model.start(keyId: key.id)
        model.draft.passphrase = FakeKeyMaker.passphrase
        model.draft.again = FakeKeyMaker.passphrase
        return (model, key)
    }

    // the files staged for the system's file screen
    private func staged() -> [String] {
        (try? FileManager.default.subpathsOfDirectory(atPath: staging.path)) ?? []
    }

    @Test("a short or differing passphrase is said once an export was tried, and goes as soon as it is put right")
    internal func passphraseProblems() async throws {
        defer { test.remove() }
        let (model, _) = try await unlocked()
        model.draft = ExportDraft()
        #expect(model.passphraseProblem == nil)
        #expect(model.passphraseMinimum == FakeKeyMaker.exportMinimum)
        model.draft.passphrase = "seven77"
        model.draft.again = "seven77"
        await model.tap(.save)
        #expect(model.passphraseProblem == .short(minimum: FakeKeyMaker.exportMinimum))
        #expect(model.work.staged == nil)
        model.draft.passphrase = FakeKeyMaker.passphrase
        #expect(model.passphraseProblem == .differs)
        await model.tap(.copy)
        #expect(test.keyClipboard.held == nil)
        model.draft.again = FakeKeyMaker.passphrase
        #expect(model.passphraseProblem == nil)
        #expect(test.maker.exportedUnder.isEmpty)
    }

    @Test("the unlock runs out after five minutes, and leaving locks at once")
    internal func expiry() async throws {
        defer { test.remove() }
        let (model, key) = try await unlocked()
        ticker.advance(by: ExportKeyModel.unlockedFor)
        await model.tap(.copy)
        #expect(model.work.done == .copied)
        ticker.advance(by: .seconds(1))
        await model.tap(.save)
        #expect(model.work.problem == .expired)
        #expect(model.work.done == nil)
        #expect(model.work.staged == nil)
        model.close()
        #expect(model.work == ExportWork())
        #expect(model.draft == ExportDraft())
        await model.tap(.copy)
        #expect(model.work == ExportWork())
        // unlocked again, it exports again
        await model.start(keyId: key.id)
        model.draft.passphrase = FakeKeyMaker.passphrase
        model.draft.again = FakeKeyMaker.passphrase
        await model.tap(.copy)
        #expect(model.work.done == .copied)
    }

    @Test("leaving the screen clears the copied key from the clipboard and removes a file still waiting")
    internal func closing() async throws {
        defer { test.remove() }
        let (model, key) = try await unlocked()
        await model.tap(.copy)
        #expect(test.keyClipboard.held != nil)
        model.close()
        #expect(test.keyClipboard.held == nil)
        #expect(test.keyClipboard.clears == 1)
        await model.start(keyId: key.id)
        model.draft.passphrase = FakeKeyMaker.passphrase
        model.draft.again = FakeKeyMaker.passphrase
        await model.tap(.save)
        #expect(!staged().isEmpty)
        model.close()
        #expect(staged().isEmpty)
        #expect(model.work == ExportWork())
        // the file screen's late answer reaches a screen that is gone
        model.placed(.success(URL(filePath: "/placed/ngterm-private-key")))
        #expect(model.work == ExportWork())
    }

    @Test("leaving any of Settings' pages with nothing unlocked changes nothing a screen shows")
    internal func closingLocked() async throws {
        defer { test.remove() }
        _ = try await test.seedKey()
        let model = model()
        let changed = Mutex(false)
        withObservationTracking {
            _ = (model.work, model.draft, model.hasTried, model.confirming)
        } onChange: {
            changed.withLock { $0 = true }
        }
        model.close()
        #expect(!changed.withLock { $0 })
        #expect(test.keyClipboard.clears == 0)
    }

    @Test("an export that ends after the screen was left says nothing and delivers nothing, to a new screen either")
    internal func lateExport() async throws {
        defer { test.remove() }
        let (model, key) = try await unlocked()
        let held = test.maker.holdExports()
        let first = Task { await model.tap(.copy) }
        await Wait.until { model.work.isBusy }
        // one at a time: a second tap starts nothing
        await model.tap(.save)
        model.close()
        await model.start(keyId: key.id)
        held.signal()
        await first.value
        #expect(test.keyClipboard.held == nil)
        #expect(staged().isEmpty)
        #expect(model.work.keyId == key.id)
        #expect(model.work.done == nil)
        #expect(!model.work.isBusy)
        #expect(test.maker.exportedUnder.count == 1)
    }

    @Test("a passphrase the core finds too short is said with its minimum")
    internal func coreFindsShort() async throws {
        defer { test.remove() }
        let (model, _) = try await unlocked()
        test.maker.exportFailure = .PassphraseTooShort(minimum: 12)
        await model.tap(.copy)
        #expect(model.work.problem == .shortPassphrase(minimum: 12))
        #expect(model.work.problem?.message == "Use at least 12 characters.")
        #expect(!model.work.isBusy)
    }

    @Test("a key the device lost, or one its vault can't read, is a problem in words")
    internal func lostKey() async throws {
        defer { test.remove() }
        let (model, key) = try await unlocked()
        test.vault.delete(keyId: key.id)
        await model.tap(.copy)
        #expect(model.work.problem == .gone)
        #expect(test.keyClipboard.held == nil)
        let locked = ExportProblem(VaultError.Unavailable(reason: "the Keychain is locked"))
        #expect(locked == .failed(reason: "the Keychain is locked"))
        #expect(ExportProblem(CocoaError(.fileNoSuchFile)).message.hasPrefix("The key couldn't be exported: "))
    }

    @Test("every outcome, problem and notice has its words")
    internal func words() {
        #expect(ExportDone.saved.words.message == "Saved")
        #expect(ExportDone.copied.words.message == "Copied")
        #expect(ExportProblem.expired.message == "It's been a while since you unlocked. Go back and export again.")
        #expect(ExportProblem.gone.message == "This key is no longer on this device.")
        #expect(PassphraseProblem.short(minimum: 8).message == "Use at least 8 characters.")
        #expect(PassphraseProblem.differs.message == "The two passphrases differ.")
        #expect(ExportNotice.noPasscode.title == "Set a passcode first")
        #expect(ExportNotice.noPasscode.message.contains("it has no passcode"))
        let failed = ExportNotice.authFailed(keyId: "k1", reason: "")
        #expect(failed.title == "Couldn't confirm it's you")
        #expect(failed.message == "The device didn't confirm it's you, so the key stays here.")
    }
}
