import Foundation
import UIKit
import UniformTypeIdentifiers

/// The system's pasteboard as an exported key's clipboard.
///
/// The key is a local-only item (Universal Clipboard never carries it to another device) that the system drops after
/// ``lifetime``, marked concealed (``concealedType``) so a program's clipboard read asks before it takes the key;
/// ``clearCopied()`` empties the pasteboard sooner, unless something else was copied since. ``mayHoldKey`` reads no
/// data, so it never brings up iOS's paste question.
@preconcurrency
@MainActor
public final class SystemKeyClipboard: KeyClipboard {
    /// How long a copied key stays on the pasteboard at most: 10 minutes.
    public static let lifetime: TimeInterval = 600
    /// The type that marks an item as a secret (nspasteboard.org's convention, which password managers follow).
    public static let concealedType = "org.nspasteboard.ConcealedType"

    private let pasteboard: UIPasteboard
    private let now: @MainActor () -> Date
    // the pasteboard's change count right after the app's own copy: another copy since moves it on
    private var copiedChange: Int?

    /// Whether the pasteboard still holds the key copied last, or an item marked concealed: a key that an earlier run
    /// of the app copied carries that mark too.
    public var mayHoldKey: Bool {
        pasteboard.changeCount == copiedChange || pasteboard.types.contains(Self.concealedType)
    }

    /// The clipboard over `pasteboard` (the general one unless a test gives its own), its items expiring by `now`.
    @preconcurrency
    public init(_ pasteboard: UIPasteboard = .general, now: @escaping @MainActor () -> Date = { Date() }) {
        self.pasteboard = pasteboard
        self.now = now
    }

    /// Puts `text` on the pasteboard as a local-only, concealed item that expires after ``lifetime``.
    public func copy(_ text: String) {
        pasteboard.setItems(
            [[UTType.utf8PlainText.identifier: text, Self.concealedType: Data()]],
            options: [.localOnly: true, .expirationDate: now().addingTimeInterval(Self.lifetime)]
        )
        copiedChange = pasteboard.changeCount
    }

    /// Empties the pasteboard if it still holds the key copied last; what was copied since stays.
    public func clearCopied() {
        guard let copiedChange else {
            return
        }
        self.copiedChange = nil
        if pasteboard.changeCount == copiedChange {
            pasteboard.items = []
        }
    }

    deinit {
        // nothing to release: the pasteboard is the system's
    }
}
