import Foundation
import NgtermPlatform
import Testing
import UIKit

/// An exported key's clipboard on a pasteboard of the test's own: the key lands as text, and leaves again only while
/// it is still what the pasteboard holds.
@MainActor
@Suite("an exported key's clipboard", .serialized)
internal struct SystemKeyClipboardTests {
    private static let key = "-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----\n"

    private func withPasteboard(_ body: (SystemKeyClipboard, UIPasteboard) -> Void) {
        let pasteboard = UIPasteboard(name: UIPasteboard.Name("ngterm-tests-\(UUID().uuidString)"), create: true)
        defer { UIPasteboard.remove(withName: pasteboard?.name ?? UIPasteboard.Name("")) }
        guard let pasteboard else {
            Issue.record("no pasteboard of the test's own")
            return
        }
        body(SystemKeyClipboard(pasteboard), pasteboard)
    }

    @Test("a copied key is the pasteboard's text, and clearing takes it back")
    internal func copyThenClear() {
        withPasteboard { clipboard, pasteboard in
            clipboard.copy(Self.key)
            #expect(pasteboard.string == Self.key)
            #expect(pasteboard.numberOfItems == 1)
            #expect(pasteboard.types.contains(SystemKeyClipboard.concealedType))
            clipboard.clearCopied()
            #expect(!pasteboard.hasStrings)
            #expect(pasteboard.numberOfItems == 0)
        }
    }

    @Test("what was copied since the key stays on the pasteboard")
    internal func laterCopyStays() {
        withPasteboard { clipboard, pasteboard in
            clipboard.copy(Self.key)
            pasteboard.string = "something the user copied since"
            clipboard.clearCopied()
            #expect(pasteboard.string == "something the user copied since")
        }
    }

    @Test("with no key copied, or one already cleared, the pasteboard is left alone")
    internal func nothingToClear() {
        withPasteboard { clipboard, pasteboard in
            pasteboard.string = "the user's own"
            clipboard.clearCopied()
            #expect(pasteboard.string == "the user's own")
            clipboard.copy(Self.key)
            clipboard.clearCopied()
            pasteboard.string = "the user's own again"
            clipboard.clearCopied()
            #expect(pasteboard.string == "the user's own again")
        }
    }

    @Test("the pasteboard may hold a key while it holds the copy, or an item marked concealed an earlier run left")
    internal func mayHoldKey() {
        withPasteboard { clipboard, pasteboard in
            #expect(!clipboard.mayHoldKey)
            clipboard.copy(Self.key)
            #expect(clipboard.mayHoldKey)
            pasteboard.string = "something the user copied since"
            #expect(!clipboard.mayHoldKey)
            clipboard.copy(Self.key)
            clipboard.clearCopied()
            #expect(!clipboard.mayHoldKey)
            pasteboard.setItems([["public.utf8-plain-text": Self.key, SystemKeyClipboard.concealedType: Data()]])
            #expect(clipboard.mayHoldKey)
        }
    }
}
