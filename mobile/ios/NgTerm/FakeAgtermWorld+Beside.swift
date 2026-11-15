#if DEBUG
    import NgtermCore
    import NgtermCoreFakes
    import NgtermPlatform

    /// The fake world's Mac that runs agterm beside ngterm, for the UI tests of a machine of both apps: `duo` at
    /// `duo.lan` (connecting at once), whose listing has ngterm's session `build` first, then agterm's `journal`.
    ///
    /// As an attach lands, each session's stream says it is connected, its one pane, that Claude Code runs in it and
    /// that this device leads it; the pane's screen says `duo-build$` or `duo-journal$`. `build`'s pane shows its chat
    /// (a prompt and its reply); `journal`'s keeps showing its terminal, as agterm has no agent chat view, and the fake
    /// core refuses its chat calls as the core does.
    extension FakeAgtermWorld {
        /// The machine's id in the store.
        internal static let besideId = "duo"
        /// ngterm's session on it.
        internal static let ngtermSessionId = "build"
        /// agterm's session on it.
        internal static let agtermSessionId = "journal"
        nonisolated private static let besideColumns = 40
        nonisolated private static let besideRows = 12
        private static let besidePaneId = "P1"

        private static var catchUp: [ChatEvent] {
            [
                ChatEvent(
                    id: "conv",
                    cursor: 0,
                    parent: nil,
                    body: .conversation(agent: "claude", conversationId: "b1", cwd: "~/build", model: nil)
                ),
                ChatEvent(id: "u0", cursor: 0, parent: nil, body: .user(text: "Run the release build", images: 0)),
                ChatEvent(id: "a0", cursor: 0, parent: nil, body: .assistant(text: "The release build passed.")),
                ChatEvent(id: "live", cursor: 0, parent: nil, body: .live),
            ]
        }

        private static func besideEvents(of sessionId: String) -> [MobileEvent] {
            let layout = RemoteLayout(panes: [besidePaneId], primary: besidePaneId, axis: nil, shown: true)
            let pane = PaneRef(machineId: besideId, sessionId: sessionId, paneId: besidePaneId)
            return [
                .sessionConnection(machineId: besideId, sessionId: sessionId, state: .connected),
                .sessionLayout(machineId: besideId, sessionId: sessionId, layout: layout),
                .paneAgent(
                    machineId: besideId,
                    sessionId: sessionId,
                    paneId: besidePaneId,
                    agent: "claude",
                    conversationId: sessionId == ngtermSessionId ? "b1" : "j1"
                ),
                .paneLead(pane: pane, role: .leader, covered: false),
            ]
        }

        /// Saves `duo` in `machines`, signing in with `keyId`, and gives `core` its two sessions, its other machines'
        /// panes left to the factory it had.
        @MainActor
        internal static func seedBeside(_ machines: MachineStore, core: FakeMobileCore, keyId: String) {
            let machine = StoredMachine(
                id: besideId,
                label: besideId,
                host: "duo.lan",
                port: StoredMachine.sshPort,
                user: "nick",
                keyId: keyId
            )
            try? machines.save(machine)
            core.sessions[besideId] = [
                fakeSession(id: ngtermSessionId, name: ngtermSessionId, peer: .ngterm),
                fakeSession(id: agtermSessionId, name: agtermSessionId, peer: .agterm),
            ]
            for sessionId in [ngtermSessionId, agtermSessionId] {
                core.panes[sessionId] = [besidePaneId]
                core.attachEvents[sessionId] = besideEvents(of: sessionId)
            }
            let chatPane = PaneRef(machineId: besideId, sessionId: ngtermSessionId, paneId: besidePaneId)
            core.chatEvents[chatPane] = catchUp
            core.catalogs[chatPane] = []
            let others = core.paneFactory
            let duo = besideId
            core.paneFactory = { machine, session, pane, size in
                guard machine == duo else {
                    return others(machine, session, pane, size)
                }
                let frames: FakePane.Frames = { since in
                    RowBufferWriter(columns: besideColumns, rows: besideRows, seq: since + 1)
                        .text(0, "attached \(session)")
                        .text(1, "duo-\(session)$ ")
                        .bytes()
                }
                return FakePane(paneId: pane, frames: frames)
            }
        }
    }
#endif
