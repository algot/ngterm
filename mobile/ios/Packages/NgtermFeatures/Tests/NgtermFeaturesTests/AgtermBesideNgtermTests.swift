import NgtermCore
import NgtermCoreFakes
import Testing

@testable import NgtermFeatures

/// A Mac that runs agterm beside ngterm (mobile/android's `ConnectionsTest` and the screens' cases of one): the machine
/// is ngterm's, each agterm session has its own app, its badge and no chat view, and the ngterm sessions keep theirs.
@MainActor
@Suite("agterm beside ngterm on one machine")
internal struct AgtermBesideNgtermTests {
    private static let agterm = SessionKey(machineId: "m1", sessionId: "s2")

    private let world = SessionWorld()

    private var test: TestGraph {
        world.test
    }

    private var connections: Connections {
        world.test.connections
    }

    // `api` (s1) is ngterm's and s2 agterm's; `attach` of them attached
    private func both(attach: [String] = []) async throws {
        try await world.attach(attach, of: ["s1", "s2"]) { $0 == "s2" ? .agterm : .ngterm }
    }

    // the machine's sessions listed anew, as `peers` names each (`nil`: the listing doesn't say)
    private func listed(_ peers: [String: PeerKind?]) async {
        test.core.sessions["m1"] = peers.keys.sorted().map { fakeSession(id: $0, peer: peers[$0, default: nil]) }
        await connections.listSessions(machineId: "m1")
        await test.settled()
    }

    @Test("the machine is ngterm's, and only its agterm session has an app of its own")
    internal func learned() async throws {
        defer { world.remove() }
        try await both()
        #expect(connections.peers["m1"]?.kind == .ngterm)
        #expect(connections.sessionPeers.mapValues(\.kind) == [Self.agterm: .agterm])
    }

    @Test("each listing names the sessions' apps anew; the machine is agterm's only when every session is")
    internal func relisted() async throws {
        defer { world.remove() }
        try await both()
        await listed(["s2": .agterm, "s3": .agterm])
        #expect(connections.peers["m1"]?.kind == .agterm)
        #expect(Set(connections.sessionPeers.keys.map(\.sessionId)) == ["s2", "s3"])
        await listed(["s1": .ngterm, "s3": .agterm])
        #expect(connections.peers["m1"]?.kind == .ngterm)
        #expect(Set(connections.sessionPeers.keys.map(\.sessionId)) == ["s3"], "s2 is gone, s3 stays agterm's")
        await listed(["s3": .agterm, "s4": nil])
        #expect(connections.peers["m1"]?.kind == .ngterm, "a listing that doesn't say every session's keeps it")
        #expect(Set(connections.sessionPeers.keys.map(\.sessionId)) == ["s3"])
        await listed([:])
        #expect(connections.peers["m1"]?.kind == .ngterm, "an empty listing says nothing")
        #expect(connections.sessionPeers.isEmpty, "an empty listing has no session")
    }

    @Test("a disconnect and an edit to another host forget the sessions' apps")
    internal func forgotten() async throws {
        defer { world.remove() }
        try await both()
        var moved = TestGraph.machine(keyId: "k1").core
        moved.host = "mini.lan"
        let connecting = connections.connect(moved)
        #expect(connections.sessionPeers.isEmpty)
        await connecting.value
        await test.settled()
        #expect(connections.sessionPeers.mapValues(\.kind) == [Self.agterm: .agterm], "its listing named it again")
        connections.disconnect(machineId: "m1")
        #expect(connections.peers["m1"] == nil)
        #expect(connections.sessionPeers.isEmpty)
    }

    @Test("Chat view is off on the agterm session, in its More and in the machine's list, and on for ngterm's")
    internal func chatViews() async throws {
        defer { world.remove() }
        try await both(attach: ["s1", "s2"])
        #expect(test.graph.chats.noChatOn(Self.agterm) == "agterm")
        #expect(test.graph.chats.noChatOn(SessionWorld.key) == nil)
        let agtermMore = SessionModel(graph: test.graph, key: Self.agterm).chatView
        #expect(!agtermMore.isOn)
        #expect(agtermMore.noChatOn == "agterm")
        let ngtermMore = SessionModel(graph: test.graph, key: SessionWorld.key).chatView
        #expect(ngtermMore.isOn)
        #expect(ngtermMore.noChatOn == nil)
        let sessions = SessionsModel(graph: test.graph, machineId: "m1", windows: SessionWindows())
        #expect(sessions.chatView(sessionId: "s2").noChatOn == "agterm")
        #expect(!sessions.chatView(sessionId: "s2").isOn)
        #expect(sessions.chatView(sessionId: "s1").isOn)
        #expect(sessions.chatView(sessionId: "s1").noChatOn == nil)
    }

    @Test("an agent's pane in the agterm session keeps its terminal; the ngterm session's shows its chat")
    internal func panes() async throws {
        defer { world.remove() }
        try await world.attach(["s1", "s2"], of: ["s1", "s2"]) { $0 == "s1" ? .agterm : .ngterm }
        await world.stream(SessionWorld.layout(["P1"], axis: nil, shown: true))
        await world.emit(
            .paneAgent(machineId: "m1", sessionId: "s1", paneId: "P1", agent: "claude", conversationId: "c1"),
            .paneAgent(machineId: "m1", sessionId: "s2", paneId: "P1", agent: "claude", conversationId: "c2")
        )
        let chats = test.graph.chats
        let agtermPane = SessionWorld.pane("P1")
        let ngtermPane = PaneRef(machineId: "m1", sessionId: "s2", paneId: "P1")
        #expect(chats.view(of: agtermPane) == nil)
        #expect(chats.view(of: ngtermPane) == .chat)
    }

    @Test("the screens: no machine badge, the agterm row's badge and the list's note, the session's own badge")
    internal func screens() async throws {
        defer { world.remove() }
        try await both(attach: ["s1", "s2"])
        let item = MachinesModel(graph: test.graph).items.first { $0.id == "m1" }
        #expect(item?.peer?.isForeign == false)
        let state = try #require(SessionsModel(graph: test.graph, machineId: "m1", windows: SessionWindows()).state)
        #expect(state.sessionPeers.mapValues(\.kind) == ["s2": .agterm])
        #expect(state.peerNote?.contains("the agent chat view") == true)
        guard case .sessions(let attached, _, _) = SessionsBody(state) else {
            Issue.record("no sessions listed")
            return
        }
        #expect(attached.map(\.id) == ["s1", "s2"])
        #expect(attached.map { $0.peer?.badge } == [nil, "agterm"])
        #expect(test.graph.attachedSessions.session(Self.agterm)?.peer?.kind == .agterm)
        #expect(test.graph.attachedSessions.session(SessionWorld.key)?.peer == nil)
    }

    @Test("on a machine whose sessions are all agterm's, the title's badge says it and the rows have none")
    internal func allAgterm() async throws {
        defer { world.remove() }
        try await world.attach([], of: ["s1", "s2"], peer: .agterm)
        let state = try #require(SessionsModel(graph: test.graph, machineId: "m1", windows: SessionWindows()).state)
        #expect(state.peer?.kind == .agterm)
        guard case .sessions(_, let others, _) = SessionsBody(state) else {
            Issue.record("no sessions listed")
            return
        }
        #expect(others.allSatisfy { $0.peer == nil })
    }

    @Test("a machine of ngterm's alone has no session app, no badge and no note")
    internal func ngtermAlone() async throws {
        defer { world.remove() }
        try await world.attach([], of: ["s1", "s2"], peer: .ngterm)
        #expect(connections.sessionPeers.isEmpty)
        let state = try #require(SessionsModel(graph: test.graph, machineId: "m1", windows: SessionWindows()).state)
        #expect(state.peerNote == nil)
    }
}
