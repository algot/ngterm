import Foundation
import NgtermPlatform
import Testing

@testable import NgtermFeatures

/// Exporting a key, as mobile/android's `ExportKeyViewModelTest` and `ExportKeyRouteTest` have it: nothing leaves
/// before the owner unlocks, a key goes to a file or the clipboard under its passphrase or, confirmed again, without
/// one, and what the last export said goes as soon as another is asked for (``ExportKeyRulesTests`` has the rest).
@MainActor
@Suite("exporting a key")
internal struct ExportKeyModelTests {
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

    @Test("nothing leaves before the owner unlocks the key")
    internal func lockedUntilConfirmed() async throws {
        defer { test.remove() }
        _ = try await test.seedKey()
        let model = model()
        model.draft.passphrase = FakeKeyMaker.passphrase
        model.draft.again = FakeKeyMaker.passphrase
        await model.tap(.copy)
        await model.tap(.save)
        #expect(model.work == ExportWork())
        #expect(test.keyClipboard.held == nil)
        #expect(staged().isEmpty)
        #expect(test.maker.exportedUnder.isEmpty)
    }

    @Test("a device with no passcode is told to set one and never asked")
    internal func noPasscode() async throws {
        defer { test.remove() }
        let key = try await test.seedKey()
        test.auth.isSecured = false
        let model = model()
        await model.start(keyId: key.id)
        #expect(model.notice == .noPasscode)
        #expect(test.auth.asked.isEmpty)
        #expect(model.work.keyId == nil)
        model.dismissNotice()
        #expect(model.notice == nil)
    }

    @Test("backing out of the prompt does nothing; a device that can't confirm says why and tries again")
    internal func cancelledAndFailed() async throws {
        defer { test.remove() }
        let key = try await test.seedKey()
        test.auth.next = [.cancelled, .failed(reason: "too many attempts")]
        let model = model()
        #expect(await !model.start(keyId: key.id))
        #expect(model.notice == nil)
        #expect(model.work.keyId == nil)
        #expect(await !model.start(keyId: key.id))
        #expect(model.notice == .authFailed(keyId: key.id, reason: "too many attempts"))
        #expect(model.notice?.message.contains("too many attempts") == true)
        #expect(model.work.keyId == nil)
        #expect(await model.retry())
        #expect(model.notice == nil)
        #expect(model.work.keyId == key.id)
        #expect(test.auth.asked.count == 3)
        // with no notice up there is nothing to try again
        #expect(await !model.retry())
        #expect(test.auth.asked.count == 3)
    }

    @Test("a key file an earlier run left staged is removed as the app's graph is made, before any unlock")
    internal func leftStagedAtLaunch() throws {
        defer { test.remove() }
        let left = try KeyExportFiles(directory: staging).stage(Data("-----BEGIN OPENSSH PRIVATE KEY-----\n".utf8))
        #expect(FileManager.default.fileExists(atPath: left.path))
        _ = TestGraph(directory: test.directory)
        #expect(staged().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: left.path))
    }

    @Test("Export tapped again locks what an earlier unlock opened, before it asks; backing out leaves it locked")
    internal func startLocksFirst() async throws {
        defer { test.remove() }
        let (model, key) = try await unlocked()
        await model.tap(.copy)
        #expect(test.keyClipboard.held != nil)
        test.auth.next = [.cancelled]
        #expect(await !model.start(keyId: key.id))
        #expect(model.work.keyId == nil)
        #expect(model.draft == ExportDraft())
        #expect(test.keyClipboard.held == nil)
        #expect(await model.start(keyId: key.id))
        test.auth.next = [.failed(reason: "too many attempts")]
        #expect(await !model.start(keyId: key.id))
        #expect(model.work.keyId == nil)
        model.draft.passphrase = FakeKeyMaker.passphrase
        model.draft.again = FakeKeyMaker.passphrase
        await model.tap(.copy)
        #expect(test.keyClipboard.held == nil)
        #expect(test.maker.exportedUnder.count == 1)
    }

    @Test("an unlocked key is copied under its passphrase, and Import a key reads it back")
    internal func copy() async throws {
        defer { test.remove() }
        let (model, key) = try await unlocked()
        await model.tap(.copy)
        #expect(model.work.done == .copied)
        #expect(!model.work.isBusy)
        #expect(test.maker.exportedUnder == [.passphrase(passphrase: FakeKeyMaker.passphrase)])
        var copied = Data(try #require(test.keyClipboard.held).utf8)
        let back = try await test.graph.keys.importKey(privateKey: &copied, passphrase: FakeKeyMaker.passphrase)
        #expect(back.fingerprint == key.fingerprint)
    }

    @Test("an unlocked key is saved into the file the system's screen places, and nothing stays staged")
    internal func save() async throws {
        defer { test.remove() }
        let (model, _) = try await unlocked()
        await model.tap(.save)
        let file = try #require(model.work.staged)
        #expect(model.work.isBusy)
        #expect(model.work.done == nil)
        #expect(file.lastPathComponent == KeyExportFiles.defaultName)
        #expect(try Data(contentsOf: file) == Data(FakeKeyMaker.encryptedKey.utf8))
        // one export at a time: a tap while the file screen is up starts nothing
        await model.tap(.copy)
        #expect(test.keyClipboard.held == nil)
        model.placed(.success(URL(filePath: "/placed/ngterm-private-key")))
        #expect(model.work.done == .saved)
        #expect(model.work.staged == nil)
        #expect(!model.work.isBusy)
        #expect(staged().isEmpty)
        // a second answer for the same file changes nothing
        model.placed(.failure(CocoaError(.fileWriteNoPermission)))
        #expect(model.work.done == .saved)
    }

    @Test("a save the system's screen couldn't place, or that couldn't be staged, says why and leaves nothing")
    internal func saveFails() async throws {
        defer { test.remove() }
        let (model, _) = try await unlocked()
        await model.tap(.save)
        model.placed(.failure(CocoaError(.fileWriteNoPermission)))
        guard case .failed = model.work.problem else {
            Issue.record("no problem said: \(String(describing: model.work.problem))")
            return
        }
        #expect(model.work.done == nil)
        #expect(!model.work.isBusy)
        #expect(staged().isEmpty)
        // a file where the staging directory should be: nothing can be staged
        try FileManager.default.removeItem(at: staging)
        try Data().write(to: staging)
        await model.tap(.save)
        guard case .failed = model.work.problem else {
            Issue.record("no problem said: \(String(describing: model.work.problem))")
            return
        }
        #expect(model.work.staged == nil)
        #expect(!model.work.isBusy)
    }

    @Test("a second save left without a file no longer says the first one saved")
    internal func cancelledSaveSaysNothing() async throws {
        defer { test.remove() }
        let (model, _) = try await unlocked()
        await model.tap(.save)
        model.placed(.success(URL(filePath: "/placed/ngterm-private-key")))
        #expect(model.work.done == .saved)
        await model.tap(.save)
        #expect(model.work.done == nil)
        model.placingCancelled()
        #expect(model.work.done == nil)
        #expect(model.work.problem == nil)
        #expect(!model.work.isBusy)
        #expect(staged().isEmpty)
        // with no file waiting, a cancel has nothing to take back
        model.placingCancelled()
        #expect(model.work.staged == nil)
        #expect(!model.work.isBusy)
    }

    @Test("what the last export said goes when another is asked for, whether or not that one gets to write")
    internal func staleOutcome() async throws {
        defer { test.remove() }
        let (model, _) = try await unlocked()
        await model.tap(.copy)
        #expect(model.work.done == .copied)
        // a passphrase the next tap refuses
        model.draft.again = "something else"
        await model.tap(.save)
        #expect(model.work.done == nil)
        #expect(model.passphraseProblem == .differs)
        // a failure, then a save left without a file
        model.draft.again = FakeKeyMaker.passphrase
        test.maker.exportFailure = .Invalid(reason: "not a stored key")
        await model.tap(.copy)
        #expect(model.work.problem == .failed(reason: "not a stored key"))
        test.maker.exportFailure = nil
        await model.tap(.save)
        #expect(model.work.problem == nil)
        model.placingCancelled()
        #expect(model.work.problem == nil)
        #expect(model.work.done == nil)
    }

    @Test("a copy declined at its last question no longer says the key was saved")
    internal func declinedUnprotected() async throws {
        defer { test.remove() }
        let (model, _) = try await unlocked()
        await model.tap(.save)
        model.placed(.success(URL(filePath: "/placed/ngterm-private-key")))
        model.draft.isUnprotected = true
        await model.tap(.copy)
        #expect(model.confirming == .copy)
        #expect(model.work.done == nil)
        model.declineUnprotected()
        #expect(model.confirming == nil)
        #expect(model.work.done == nil)
        #expect(test.keyClipboard.held == nil)
        #expect(test.maker.exportedUnder == [.passphrase(passphrase: FakeKeyMaker.passphrase)])
    }

    @Test("a key goes out unencrypted only once that is said again, and Import a key reads it with no passphrase")
    internal func unprotected() async throws {
        defer { test.remove() }
        let (model, key) = try await unlocked()
        model.draft = ExportDraft()
        model.draft.isUnprotected = true
        // no passphrase is asked of an export without one
        await model.tap(.copy)
        #expect(model.passphraseProblem == nil)
        #expect(test.keyClipboard.held == nil)
        let action = try #require(model.confirming)
        await model.confirmUnprotected(action)
        #expect(model.confirming == nil)
        #expect(model.work.done == .copied)
        #expect(test.maker.exportedUnder == [.unprotected])
        var copied = Data(try #require(test.keyClipboard.held).utf8)
        let back = try await test.graph.keys.importKey(privateKey: &copied, passphrase: "")
        #expect(back.fingerprint == key.fingerprint)
    }
}
