import Foundation
import NgtermCore
import NgtermCoreFakes
import NgtermFeatures
import Testing

@testable import NgTerm

/// The fake world's agterm Macs, which the agterm UI tests rely on: `studio`, which runs agterm alone, and `duo`, which
/// runs it beside ngterm, each with its sessions, their attach events and their panes' screens.
@MainActor
@Suite("the fake world's agterm Macs")
internal struct FakeAgtermWorldTests {
    private static let size = PaneSize(cols: 40, rows: 12, cellWidth: 8, cellHeight: 16)

    private let graph = FakeWorld.graph(arguments: [
        CoreChoice.fakeArgument, CoreChoice.fakeKeyArgument, CoreChoice.fakeAgtermArgument,
        CoreChoice.fakeAgtermBesideArgument,
    ])

    private func core() throws -> FakeMobileCore {
        try #require(graph.connections.core as? FakeMobileCore)
    }

    // whether the pane P1 of `sessionId` on `machineId` shows `text` first (a pane with no screen shows nothing)
    private func shows(_ machineId: String, _ sessionId: String, _ text: String) throws -> Bool {
        let pane = try core().paneFactory(machineId, sessionId, "P1", Self.size)
        return (try? pane.frame(sinceSeq: 0))?.contains(Data(text.utf8)) == true
    }

    @Test("both Macs are saved, signing in with the one fake key")
    internal func saved() throws {
        let duo = try #require(graph.machines.machine(id: FakeAgtermWorld.besideId))
        let studio = try #require(graph.machines.machine(id: FakeAgtermWorld.machineId))
        #expect(duo.host == "duo.lan")
        #expect(studio.host == "studio.lan")
        #expect(!duo.keyId.isEmpty)
        #expect(duo.keyId == studio.keyId)
    }

    @Test("duo lists ngterm's session first, then agterm's; studio its agterm session")
    internal func listed() throws {
        let core = try core()
        let duo = core.sessions[FakeAgtermWorld.besideId] ?? []
        #expect(duo.map(\.id) == [FakeAgtermWorld.ngtermSessionId, FakeAgtermWorld.agtermSessionId])
        #expect(duo.map(\.peer) == [.ngterm, .agterm])
        #expect(core.sessions[FakeAgtermWorld.machineId]?.map(\.peer) == [.agterm])
    }

    @Test("each of duo's sessions attaches connected, with Claude Code in its pane, led here; only build has a chat")
    internal func attached() throws {
        let core = try core()
        for sessionId in [FakeAgtermWorld.ngtermSessionId, FakeAgtermWorld.agtermSessionId] {
            let events = core.attachEvents[sessionId] ?? []
            let pane = PaneRef(machineId: FakeAgtermWorld.besideId, sessionId: sessionId, paneId: "P1")
            let connected = MobileEvent.sessionConnection(
                machineId: pane.machineId,
                sessionId: sessionId,
                state: .connected
            )
            #expect(events.first == connected)
            #expect(events.last == .paneLead(pane: pane, role: .leader, covered: false))
            #expect(core.panes[sessionId] == ["P1"])
        }
        let build = PaneRef(
            machineId: FakeAgtermWorld.besideId,
            sessionId: FakeAgtermWorld.ngtermSessionId,
            paneId: "P1"
        )
        let journal = PaneRef(
            machineId: FakeAgtermWorld.besideId,
            sessionId: FakeAgtermWorld.agtermSessionId,
            paneId: "P1"
        )
        #expect(core.chatEvents[build]?.map(\.id) == ["conv", "u0", "a0", "live"])
        #expect(core.catalogs[build]?.isEmpty == true)
        #expect(core.chatEvents[journal] == nil)
    }

    @Test("each Mac's panes show its prompt; another machine's are left to the factory before them")
    internal func screens() throws {
        #expect(try shows(FakeAgtermWorld.besideId, FakeAgtermWorld.ngtermSessionId, "duo-build$"))
        #expect(try shows(FakeAgtermWorld.besideId, FakeAgtermWorld.agtermSessionId, "duo-journal$"))
        #expect(try shows(FakeAgtermWorld.machineId, FakeAgtermWorld.sessionId, "agterm$"))
        #expect(try !shows("elsewhere", "s1", "duo-"))
        #expect(try !shows("elsewhere", "s1", "agterm$"))
    }
}
