import NgtermCoreFakes
import NgtermPlatform
import SwiftUI
import Testing

@testable import NgtermFeatures

/// The app's own lines of the diagnostic log (mobile/android's `DiagnosticsTest` and the lines its screens write):
/// the start, the foreground and the network, where the user went, and why a chat action was not sent and what became
/// of one that was; each a fixed word or class, never what the user typed.
@MainActor
@Suite("the app's lines of the diagnostic log")
internal struct AppLogLinesTests {
    private let test = TestGraph()

    @Test("each level is written under the component's tag; with no log nothing is")
    internal func levels() {
        defer { test.remove() }
        let diagnostics = Diagnostics(log: test.log)
        diagnostics.info(.app, "one")
        diagnostics.warn(.chatUI, "two")
        diagnostics.error(.logs, "three")
        diagnostics.started(version: "0.2.5", system: "27.0", device: "iPhone17,3")
        Diagnostics().info(.nav, "nowhere")
        let written = test.log.lines.map { $0.split(separator: " ", maxSplits: 1).last.map(String.init) ?? "" }
        #expect(
            written == [
                "I app: one", "W chat-ui: two", "E logs: three",
                "I app: started version=0.2.5 ios=27.0 device=iPhone17,3",
            ]
        )
    }

    @Test("the network going and coming back is a line each, the first path's too; a new path alone is none")
    internal func network() {
        defer { test.remove() }
        test.graph.network.start()
        test.path.send(NetworkPath(isSatisfied: true, interfaces: ["en0"]))
        test.path.send(NetworkPath(isSatisfied: true, interfaces: ["pdp_ip0"]))
        test.path.send(NetworkPath(isSatisfied: false, interfaces: []))
        test.path.send(NetworkPath(isSatisfied: true, interfaces: ["en0"]))
        #expect(test.logged("app") == ["app: network online", "app: network offline", "app: network online"])
    }

    @Test("the app coming to the foreground and leaving it is a line each, whatever its windows do between")
    internal func foreground() {
        defer { test.remove() }
        let life = AppLifecycle(graph: test.graph, grace: TestGrace(), scheduler: TestScheduler())
        let first = ObjectIdentifier(Int.self)
        let second = ObjectIdentifier(String.self)
        life.lifecycle.sceneEntered(first)
        life.lifecycle.sceneEntered(second)
        life.lifecycle.sceneLeft(first)
        life.lifecycle.sceneLeft(second)
        life.lifecycle.sceneLeft(second)
        #expect(test.logged("app") == ["app: in the foreground", "app: in the background"])
    }

    @Test("a window's destination is a line as it changes: the columns of a compact stack, a regular width, Settings")
    internal func destinations() {
        defer { test.remove() }
        let model = ScaffoldModel(windows: SessionWindows(), diagnostics: test.graph.diagnostics)
        model.isCompact = true
        model.show(machine: "m1")
        _ = model.open(SessionWindowID(SessionKey(machineId: "m1", sessionId: "s1")))
        model.compactColumn = .content
        model.isSettingsPresented = true
        model.isSettingsPresented = false
        model.isCompact = false
        model.close()
        #expect(
            test.logged("nav") == [
                "nav: destination=machines", "nav: destination=sessions", "nav: destination=session",
                "nav: destination=sessions", "nav: destination=settings", "nav: destination=sessions",
                "nav: destination=session", "nav: destination=sessions",
            ]
        )
    }

    @Test("Settings' pages are a line each as they are set, before they show, and never name a key")
    internal func settingsPages() {
        defer { test.remove() }
        let navigation = SettingsNavigation(diagnostics: test.graph.diagnostics)
        navigation.shown()
        navigation.path.append(.importKey)
        navigation.path = [.publicKey("k-secret-id")]
        navigation.path = [.publicKey("k-secret-id")]
        navigation.path.append(.exportKey("k-secret-id"))
        navigation.path = []
        navigation.path.append(.logs)
        #expect(
            test.logged("nav") == [
                "nav: settings page=home", "nav: settings page=import", "nav: settings page=key",
                "nav: settings page=export", "nav: settings page=home", "nav: settings page=logs",
            ]
        )
        navigation.shown()
        #expect(test.logged("nav").last == "nav: settings page=logs", "Settings shown again says where it is")
        #expect(!test.log.text().contains("k-secret-id"))
    }

    @Test("Settings offers the log only when the app keeps one")
    internal func settingsOffersTheLog() {
        defer { test.remove() }
        let model = SettingsModel(graph: test.graph)
        #expect(model.hasLog)
        #expect(model.makeLogs() != nil)
        let bare = AppGraph(
            machines: test.graph.machines,
            settings: test.graph.settings,
            keys: test.graph.keys,
            pins: test.pins,
            stores: GraphStores(directory: test.directory),
            core: test.core,
            notices: test.notices,
            pathSource: TestPathSource(),
            clipboard: test.clipboard
        )
        #expect(!SettingsModel(graph: bare).hasLog)
        #expect(SettingsModel(graph: bare).makeLogs() == nil)
    }

    @Test("every chat problem has its class in the log, and a refusal's reason stays out")
    internal func problemNames() {
        let names: [(ChatProblem, String)] = [
            (.closed, "Closed"), (.dialogOpen, "DialogOpen"), (.leadRefused, "LeadRefused"),
            (.notOnScreen, "NotOnScreen"), (.notReading, "NotReading"), (.refused(reason: "typed secret"), "Refused"),
            (.unconfirmed, "Unconfirmed"),
        ]
        for (problem, name) in names {
            #expect(problem.logName == name)
        }
    }

    @Test("a chat action that was not sent says why, and one that was says how it went, never the message")
    internal func chatLines() async throws {
        let world = ChatWorld()
        defer { world.remove() }
        try await world.open()
        await world.chat(ChatSamples.event("conv", ChatSamples.conversation), ChatSamples.event("live", .live))
        let chat = try #require(world.chat)
        let pane = try #require(world.fakePane)
        chat.send()
        chat.composer.edit("qa-secret-mk1 fix it")
        pane.outcome = .dialogOpen
        let gate = FakeGate<Void>()
        pane.gate = gate
        chat.send()
        // the field emptied as the message went: Stop is what meets the action on its way
        chat.stop()
        gate.open()
        await Wait.until { !chat.snapshot.isBusy }
        pane.outcome = .sent
        chat.send()
        await Wait.until { !chat.snapshot.isBusy }
        #expect(
            world.world.test.logged("chat-ui") == [
                "chat-ui: message not sent: the field is empty",
                "chat-ui: action not sent: another one is on its way",
                "chat-ui: action result=DialogOpen",
                "chat-ui: action result=sent",
            ]
        )
        #expect(!world.world.test.log.text().contains("qa-secret-mk1"))
    }
}
