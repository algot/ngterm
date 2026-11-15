import Foundation
import NgtermCore
import NgtermTerminal
import Testing
import UIKit

/// The system's clipboard as the terminal uses it: text for the user's copy and paste, and every type a program's
/// clipboard reads and writes reach, on a pasteboard of the test's own (the general one for the text round trip).
@MainActor
@Suite("the system clipboard", .serialized)
internal struct SystemClipboardTests {
    private static let text = ClipboardPart(mime: "text/plain", data: Data("Ghostty multipart clipboard".utf8))
    private static let html = ClipboardPart(mime: "text/html", data: Data("<b>Ghostty</b> multipart clipboard".utf8))
    private static let png = ClipboardPart(mime: "image/png", data: ClipboardFixtures.redPNG)
    private static let arbitrary = ClipboardPart(
        mime: "application/octet-stream",
        data: Data((0..<2_048).map { UInt8($0 % 256) })
    )

    private func withPasteboard(_ body: (SystemClipboard, UIPasteboard) -> Void) {
        let pasteboard = UIPasteboard(name: UIPasteboard.Name("ngterm-tests-\(UUID().uuidString)"), create: true)
        defer { UIPasteboard.remove(withName: pasteboard?.name ?? UIPasteboard.Name("")) }
        guard let pasteboard else {
            Issue.record("no pasteboard of the test's own")
            return
        }
        body(SystemClipboard(pasteboard), pasteboard)
    }

    @Test("what the terminal copies is on the general pasteboard, and an empty copy empties it")
    internal func roundTrip() {
        let clipboard = SystemClipboard()
        clipboard.write("ngterm copied this")
        #expect(clipboard.hasText)
        #expect(UIPasteboard.general.hasStrings)
        clipboard.write(nil)
        #expect(!clipboard.hasText)
        #expect(!UIPasteboard.general.hasStrings)
    }

    @Test("a program's text, HTML and image are kept as one item and read back by type, in the order asked")
    internal func multipart() {
        withPasteboard { clipboard, pasteboard in
            #expect(clipboard.write([Self.text, Self.html, Self.png, Self.arbitrary]) == .done)
            #expect(pasteboard.numberOfItems == 1)
            // iOS puts RTF beside the HTML on its own
            #expect(Set(clipboard.types()).isSuperset(of: ["text/plain", "text/html", "image/png"]))
            #expect(!clipboard.types().contains("application/octet-stream"))
            let read = clipboard.read(["image/png", "application/octet-stream", "text/plain", "text/html"])
            #expect(read == [Self.png, Self.text, Self.html])
            #expect(clipboard.text() == "Ghostty multipart clipboard")
        }
    }

    @Test("an image alone is a write, not a clear; only an empty write clears")
    internal func imageOnly() {
        withPasteboard { clipboard, pasteboard in
            #expect(clipboard.write([Self.png]) == .done)
            #expect(!clipboard.hasText)
            #expect(clipboard.types() == ["image/png"])
            #expect(clipboard.read(["image/png", "text/plain"]) == [Self.png])
            #expect(clipboard.write([]) == .done)
            #expect(pasteboard.numberOfItems == 0)
            #expect(clipboard.types().isEmpty)
        }
    }

    @Test("a value with no type the clipboard keeps is unsupported and leaves it as it was")
    internal func unsupported() {
        withPasteboard { clipboard, _ in
            clipboard.write("kept")
            #expect(clipboard.write([Self.arbitrary]) == .unsupported)
            #expect(clipboard.text() == "kept")
        }
    }

    @Test("a copy its app marked concealed reads as sensitive with its data; another doesn't")
    internal func concealed() {
        withPasteboard { clipboard, pasteboard in
            pasteboard.setItems([["public.utf8-plain-text": "hunter2", SystemClipboard.concealedType: Data()]])
            #expect(clipboard.isSensitive)
            let taken = clipboard.take(["text/plain"], list: true)
            #expect(taken.sensitive)
            #expect(taken.contents == [ClipboardPart(mime: "text/plain", data: Data("hunter2".utf8))])
            #expect(taken.types == ["text/plain"])

            pasteboard.string = "ls -la"
            #expect(!clipboard.isSensitive)
            let plain = clipboard.take(["text/plain"], list: false)
            let listing = ClipboardPart(mime: "text/plain", data: Data("ls -la".utf8))
            #expect(plain == ClipboardTake(contents: [listing], types: [], sensitive: false))
            #expect(!clipboard.take([], list: false).sensitive)
        }
    }

    @Test("a clipboard that changes under a read is read again, and one that keeps changing reads as sensitive")
    internal func changing() {
        let once = ChangingClipboard(changes: 1)
        #expect(once.take(["text/plain"], list: false).sensitive == false)
        #expect(once.reads == 2)
        let always = ChangingClipboard(changes: .max)
        let taken = always.take(["text/plain"], list: false)
        #expect(taken.sensitive)
        #expect(taken.contents == [ClipboardPart(mime: "text/plain", data: Data("clip".utf8))])
        #expect(always.reads == 3)
    }

    @Test("another app's HTML is listed and read under its MIME type")
    internal func foreignHTML() {
        withPasteboard { clipboard, pasteboard in
            pasteboard.setItems([["public.html": Data("<i>hi</i>".utf8), "public.utf8-plain-text": "hi"]])
            #expect(Set(clipboard.types()).isSuperset(of: ["text/html", "text/plain"]))
            #expect(clipboard.read(["text/html"]) == [ClipboardPart(mime: "text/html", data: Data("<i>hi</i>".utf8))])
        }
    }
}
