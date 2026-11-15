import Foundation
import NgtermCore
import NgtermPlatform
import Observation

/// Exporting one of the app's private keys (mobile/android's `ExportKeyViewModel` and its route).
///
/// Nothing leaves before the device's owner has proved it is them (``start(keyId:)``), and that proof lasts
/// ``unlockedFor`` or until ``close()``, which the screen calls as it is left: it also takes a copied key back off
/// the clipboard and removes a file still waiting to be placed. The exported bytes are zeroed once handed over; the
/// stored key never reaches this class.
///
/// What the last export said (Saved, Copied or why not) goes as soon as Save or Copy is tapped again, whether or not
/// that tap gets to write.
@preconcurrency
@MainActor
@Observable
public final class ExportKeyModel {
    /// How long the owner's proof lasts: five minutes.
    public static let unlockedFor = Duration.seconds(unlockedSeconds)
    private static let unlockedSeconds: Int64 = 300

    /// Where the export stands.
    public private(set) var work = ExportWork()
    /// Why the export didn't open, until ``dismissNotice()``.
    public private(set) var notice: ExportNotice?
    /// The export waiting on the user's last word that the key goes out unencrypted.
    public private(set) var confirming: ExportAction?
    /// Whether an export was tried, so what is wrong with the passphrase shows.
    public private(set) var hasTried = false
    /// What the screen holds while it is filled in.
    public var draft = ExportDraft()
    @ObservationIgnored private let keys: AppKeys
    @ObservationIgnored private let services: KeyExportServices
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant
    @ObservationIgnored private var unlockedAt: ContinuousClock.Instant?
    // which showing of the screen this is: an export begun under an earlier one delivers and says nothing
    @ObservationIgnored private var showing = 0

    /// How many characters the passphrase needs at least.
    public var passphraseMinimum: Int {
        keys.exportPassphraseMinimum
    }

    /// What is wrong with the passphrase, once an export was tried with it; nothing as soon as it is put right.
    public var passphraseProblem: PassphraseProblem? {
        hasTried ? draftProblem : nil
    }

    // what keeps the draft from being exported
    private var draftProblem: PassphraseProblem? {
        if draft.isUnprotected {
            return nil
        }
        if keys.isExportPassphraseTooShort(draft.passphrase) {
            return .short(minimum: passphraseMinimum)
        }
        return draft.passphrase == draft.again ? nil : .differs
    }

    /// The export of the private keys of `keys` through `services`, the owner's proof timed by `now`.
    @preconcurrency
    public init(
        keys: AppKeys,
        services: KeyExportServices,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.keys = keys
        self.services = services
        self.now = now
    }

    /// Export private key was tapped for the key `keyId`: only once its owner has proved it is them is it unlocked.
    ///
    /// A device with no passcode is told to set one; one that couldn't confirm says why; backing out of the prompt
    /// does nothing.
    public func start(keyId: String) async {
        notice = nil
        guard services.auth.isSecured else {
            notice = .noPasscode
            return
        }
        let reason = String(localized: "Confirm it's you to export the key ngterm signs in with")
        switch await services.auth.confirm(reason: reason) {
        case .confirmed:
            unlock(keyId)

        case .cancelled:
            break

        case .failed(let reason):
            notice = .authFailed(keyId: keyId, reason: reason)
        }
    }

    /// Asks the owner again, after the device couldn't confirm.
    public func retry() async {
        guard case .authFailed(let keyId, _) = notice else {
            return
        }
        await start(keyId: keyId)
    }

    /// The notice has been read.
    public func dismissNotice() {
        notice = nil
    }

    /// The export screen is left: nothing can be exported until the owner confirms again, what was typed is
    /// forgotten, a file still waiting to be placed is removed, and a key copied from the screen leaves the clipboard.
    public func close() {
        // with nothing unlocked there is nothing to lock: Settings calls this as any of its pages is left
        guard work.keyId != nil else {
            return
        }
        showing += 1
        if let staged = work.staged {
            services.files.discard(staged)
        }
        work = ExportWork()
        draft = ExportDraft()
        hasTried = false
        confirming = nil
        unlockedAt = nil
        services.clipboard.clearCopied()
    }

    /// Save or Copy was tapped: what the last export said no longer stands, and the key goes out as the draft says,
    /// once the draft is in order and, for a key that goes out unencrypted, the user has said so once more
    /// (``confirmUnprotected(_:)``).
    public func tap(_ action: ExportAction) async {
        work.done = nil
        work.problem = nil
        hasTried = true
        guard draftProblem == nil else {
            return
        }
        if draft.isUnprotected {
            confirming = action
            return
        }
        await export(to: action, under: draft.protection)
    }

    /// The user said the key goes out unencrypted: `action` exports it so.
    public func confirmUnprotected(_ action: ExportAction) async {
        confirming = nil
        await export(to: action, under: .unprotected)
    }

    /// The user took the unencrypted export back.
    public func declineUnprotected() {
        confirming = nil
    }

    /// The system's file screen placed the staged file, or said why it couldn't.
    public func placed(_ result: Result<URL, any Error>) {
        guard let staged = work.staged else {
            return
        }
        services.files.discard(staged)
        work.staged = nil
        work.isBusy = false
        switch result {
        case .success:
            work.done = .saved

        case .failure(let error):
            work.problem = .failed(reason: ErrorWords.of(error))
        }
    }

    /// The system's file screen was left without a place for the file: nothing was saved, and nothing says it was.
    public func placingCancelled() {
        guard let staged = work.staged else {
            return
        }
        services.files.discard(staged)
        work.staged = nil
        work.isBusy = false
    }

    // the owner confirmed it is them: `keyId` can be exported, and files an earlier run left staged are removed
    private func unlock(_ keyId: String) {
        showing += 1
        services.files.discardAll()
        unlockedAt = now()
        work = ExportWork()
        work.keyId = keyId
        draft = ExportDraft()
        hasTried = false
        confirming = nil
    }

    // whether an export may start: a key is unlocked, recently enough, and none is under way
    private func isReady() -> Bool {
        guard work.keyId != nil, !work.isBusy else {
            return false
        }
        guard let unlockedAt, now() - unlockedAt <= Self.unlockedFor else {
            work.problem = .expired
            return false
        }
        return true
    }

    private func export(to action: ExportAction, under protection: ExportProtection) async {
        guard isReady(), let keyId = work.keyId else {
            return
        }
        let begun = showing
        work.isBusy = true
        do {
            var exported = try await keys.export(id: keyId, protection: protection)
            defer {
                exported.resetBytes(in: exported.startIndex..<exported.endIndex)
            }
            // an export that ends after the screen was left delivers nothing, to that screen or to one opened since
            guard showing == begun else {
                return
            }
            try deliver(exported, to: action)
        } catch {
            if showing == begun {
                work.isBusy = false
                work.problem = ExportProblem(error)
            }
        }
    }

    // a copy is done at once; a save stays under way until the system's file screen has placed the staged file
    private func deliver(_ exported: Data, to action: ExportAction) throws {
        switch action {
        case .copy:
            guard let text = String(bytes: exported, encoding: .utf8) else {
                throw KeyError.Invalid(reason: "the exported key isn't text")
            }
            services.clipboard.copy(text)
            work.isBusy = false
            work.done = .copied

        case .save:
            work.staged = try services.files.stage(exported)
        }
    }

    deinit {
        // nothing to release: the keys are the graph's
    }
}
