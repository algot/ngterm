#if DEBUG
    import NgtermCore
    import NgtermCoreFakes
    import NgtermPlatform

    /// The fake world's machine with a live session, for the session view's UI tests: `split` at `split.lan`
    /// (connecting at once), whose session `work` has two panes side by side.
    ///
    /// Its stream says, as an attach lands, that it is connected, its layout, an agent working, and that this device
    /// leads both panes; when asked, its origin then asks whether to deploy (``deployAsk``), and says what it does with
    /// the answer as the session's context ("Deploying to production", or "Deploy called off"); when asked, its first
    /// pane runs Claude Code (``FakeChatWorld``). Each pane's screen names it on its first line ("P1 ready"), so a test
    /// sees which pane shows, and echoes what it was typed after its prompt ("$ ls"), so a test sees which pane took
    /// the typing. With a companion, `split` also lists `notes`, a session of its own, and `review`, a companion of
    /// `work`, each with one pane, listed as the core lists them: parents first, companions after them.
    ///
    /// The first session made there (``copyId``: a Duplicate's first copy, or New session's first session) has one
    /// pane, `P1`, which another device leads as it is shown, and which this device leads once it takes control; when
    /// asked, the first Duplicate fails (``duplicateRefusal``).
    internal enum FakeSessionWorld {
        /// The machine's id in the store.
        internal static let machineId = "split"
        /// The session's id.
        internal static let sessionId = "work"
        /// The companion's id, when there is one.
        internal static let companionId = "review"
        /// The id of the session listed with the companion, between `work` and it.
        internal static let otherId = "notes"
        /// The id of a Duplicate's first copy, or of the first session New session makes, as the fake core names it.
        internal static let copyId = "fake-1"
        /// Why the first Duplicate fails, when the launch asks for it.
        internal static let duplicateRefusal = "split could not copy work"
        private static let paneIds = ["P1", "P2"]

        /// The question the origin asks when the launch asks for it.
        internal static let deployAsk = RemoteAsk(
            id: "deploy",
            title: "Deploy api to production?",
            message: "The tests passed on main.",
            buttons: [
                RemoteAskButton(id: "deploy", label: "Deploy", hotkey: nil),
                RemoteAskButton(id: "wait", label: "Not yet", hotkey: nil),
            ],
            defaultId: "deploy",
            destructiveId: nil,
            cancelId: "wait",
            style: "terminal",
            align: "right",
            width: nil,
            pane: nil,
            input: nil,
            choices: nil
        )

        private static var askEvent: MobileEvent {
            .ask(machineId: machineId, sessionId: sessionId, ask: deployAsk)
        }

        private static func attachEvents(
            of sessionId: String,
            panes: [String],
            role: PaneRole? = .leader
        ) -> [MobileEvent] {
            let layout = RemoteLayout(panes: panes, primary: panes[0], axis: "vertical", shown: true)
            let status = RemoteStatus(
                status: "working",
                blink: false,
                color: nil,
                shape: nil,
                pane: nil,
                changedAt: nil
            )
            var events: [MobileEvent] = [
                .sessionConnection(machineId: machineId, sessionId: sessionId, state: .connected),
                .sessionLayout(machineId: machineId, sessionId: sessionId, layout: layout),
                .sessionStatus(machineId: machineId, sessionId: sessionId, status: status, changed: false),
                .sessionContext(machineId: machineId, sessionId: sessionId, context: "Split the guide"),
            ]
            for paneId in layout.panes {
                let pane = PaneRef(machineId: machineId, sessionId: sessionId, paneId: paneId)
                if let role {
                    events.append(.paneLead(pane: pane, role: role, covered: false))
                }
            }
            return events
        }

        // the first session made (a Duplicate's copy, New session's): another device leads its pane as it is shown,
        // until this one takes control
        @MainActor
        private static func seedCopy(_ core: FakeMobileCore) {
            let pane = PaneRef(machineId: machineId, sessionId: copyId, paneId: "P1")
            core.attachEvents[copyId] = attachEvents(of: copyId, panes: [pane.paneId], role: nil)
            core.showEvents = [pane: [.paneLead(pane: pane, role: .follower, covered: false)]]
            core.takeLeadEvents = [pane: [.paneLead(pane: pane, role: .leader, covered: false)]]
        }

        private static func context(_ text: String) -> MobileEvent {
            .sessionContext(machineId: machineId, sessionId: sessionId, context: text)
        }

        /// Saves the machine in `machines`, signing in with `keyId`, and gives `core` its session, whose origin asks
        /// ``deployAsk`` when `asks`, and whose first pane runs Claude Code (``FakeChatWorld``) when there is a
        /// `chatCue`; and ``otherId`` and its companion ``companionId`` when `companion`.
        ///
        /// The agent's steps that a test looks at first wait for `chatCue`.
        @MainActor
        internal static func seed(
            _ machines: MachineStore,
            core: FakeMobileCore,
            keyId: String,
            asks: Bool,
            companion: Bool,
            chatCue: (@Sendable (FakeCues.Cue) async -> Void)?
        ) {
            let machine = StoredMachine(
                id: machineId,
                label: "split",
                host: "split.lan",
                port: StoredMachine.sshPort,
                user: "nick",
                keyId: keyId
            )
            try? machines.save(machine)
            core.sessions[machineId] = [
                fakeSession(id: sessionId, name: sessionId, paneCount: UInt32(paneIds.count))
            ]
            core.panes[sessionId] = Set(paneIds)
            if companion {
                let others = [(otherId, ["N1"], String?.none), (companionId, ["R1"], Optional(sessionId))]
                for (id, panes, parent) in others {
                    core.sessions[machineId, default: []].append(fakeSession(id: id, name: id, parent: parent))
                    core.panes[id] = Set(panes)
                    core.attachEvents[id] = attachEvents(of: id, panes: panes)
                }
            }
            seedCopy(core)
            let agent = chatCue.map { FakeChatWorld(core: core, pace: .real, cue: $0) }
            core.attachEvents[sessionId] =
                attachEvents(of: sessionId, panes: paneIds) + (asks ? [askEvent] : [])
                + (agent == nil ? [] : [FakeChatWorld.agentEvent])
            if agent != nil {
                core.chatEvents[FakeChatWorld.pane] = FakeChatWorld.catchUp
            }
            core.answerEvents = [
                FakeMobileCore.answerKey(askId: deployAsk.id, button: "deploy"): [context("Deploying to production")],
                FakeMobileCore.answerKey(askId: deployAsk.id, button: nil): [context("Deploy called off")],
            ]
            core.paneFactory = { [weak core] _, sessionId, paneId, _ in
                let echo = FakeEcho(PaneRef(machineId: machineId, sessionId: sessionId, paneId: paneId), core: core)
                let frames: FakePane.Frames = { since in echo.frames(since: since) }
                let isAgent = paneId == FakeChatWorld.pane.paneId
                let pane = (isAgent ? agent : nil)?.pane(frames: frames) ?? FakePane(paneId: paneId, frames: frames)
                pane.onInput = { input in echo.take(input) }
                return pane
            }
        }
    }
#endif
