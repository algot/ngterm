import Foundation
import NgtermCore
import NgtermCoreFakes
import Testing

@testable import NgtermFeatures

/// A program's clipboard reads over the fake core while an exported private key may be on the clipboard: the copied
/// key counts as a clip marked sensitive, so each read that would hand it over asks, and its answer is for that read.
@MainActor
@Suite("the clipboard reads while a key is copied")
internal struct ClipboardReadsKeyTests {
    private static let copied = ClipboardPart(mime: "text/plain", data: Data("copied text".utf8))

    private let test = TestGraph()
    private let pane = PaneRef(machineId: "m1", sessionId: "s1", paneId: "P1")

    private var reads: ClipboardReads {
        test.graph.clipboardReads
    }

    private func request(
        _ id: UInt64,
        pane: PaneRef? = nil,
        listOnly: Bool = false,
        granted: Bool = false,
        canRemember: Bool = false
    ) async {
        test.core.emit(
            .clipboardReadRequest(
                pane: pane ?? self.pane,
                readId: id,
                clipboard: .standard,
                listOnly: listOnly,
                mimes: listOnly ? [] : ["text/plain"],
                list: listOnly,
                granted: granted,
                canRemember: canRemember
            )
        )
        await test.settled()
    }

    private func allowed(_ contents: [ClipboardPart] = [], available: [String] = []) -> ClipboardReply {
        .allow(contents: contents, available: available, remember: false)
    }

    private func answers() -> [FakeCall] {
        test.core.calls.filter { $0.method == "answerClipboardRead" }
    }

    private func answer(_ id: UInt64, _ reply: ClipboardReply, pane: PaneRef? = nil) -> FakeCall {
        let reading = pane ?? self.pane
        return FakeCall("answerClipboardRead", [reading.machineId, reading.sessionId, reading.paneId, id, reply])
    }

    @Test("while an exported key may be on the clipboard, a trusted or granted read asks once; a listing doesn't")
    internal func exportedKey() async {
        defer { test.remove() }
        let key = "-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----\n"
        let sibling = PaneRef(machineId: "m1", sessionId: "s2", paneId: "P2")
        await request(1)
        reads.allowAlways(reads.pending[0])
        test.keyClipboard.copy(key)
        test.clipboard.held = key
        await request(2)
        await request(3, pane: sibling, granted: true, canRemember: true)
        await request(4, listOnly: true)
        #expect(reads.pending.map(\.readId) == [2, 3])
        #expect(answers() == [answer(1, allowed()), answer(4, allowed(available: ["text/plain"]))])
        // a copied key counts as a clip marked sensitive: its Allow is for the one read, the other read still asks
        #expect(reads.asksOnce(reads.pending[0]))
        // the prompt shows only that the key may be there, and its Allow hands over what was read
        let shown = reads.preview(reads.pending[0])
        #expect(shown.mayHoldKey)
        #expect(shown.contents == [ClipboardPart(mime: "text/plain", data: Data(key.utf8))])
        reads.allowAlways(reads.pending[0])
        #expect(reads.pending.map(\.readId) == [3])
        #expect(reads.asksOnce(reads.pending[0]))
        reads.allow(reads.pending[0], remember: true)
        let copiedKey = ClipboardPart(mime: "text/plain", data: Data(key.utf8))
        #expect(answers().last == answer(3, allowed([copiedKey]), pane: sibling), "the Allow keeps no grant")
        #expect(reads.pending.isEmpty)
        test.graph.exports.clipboard.clearCopied()
        test.clipboard.held = "copied text"
        await request(5)
        #expect(reads.pending.isEmpty)
        #expect(answers().last == answer(5, allowed([Self.copied])))
        await request(6, pane: PaneRef(machineId: "m2", sessionId: "s3", paneId: "P3"))
        #expect(!reads.preview(reads.pending[0]).mayHoldKey)
    }
}
