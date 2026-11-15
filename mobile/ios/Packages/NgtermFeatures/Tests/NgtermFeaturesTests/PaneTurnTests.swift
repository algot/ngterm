import NgtermDesign
import NgtermTerminal
import SwiftUI
import Testing
import UIKit

@testable import NgtermFeatures

/// A pane turned from its chat to its terminal (the toolbar's Show terminal, the chat's own Answer in terminal) while
/// the chat's prompt field has the keyboard, in the session view: the terminal, under the chat, takes the keyboard straight from the field before the
/// view changes, so the soft keyboard stays up and no first responder moves inside the view update (which has the
/// hosting view read its graph mid-update, and can spin for good); the chat shown again takes it back.
@MainActor
@Suite("a pane turning between its chat and its terminal")
internal struct PaneTurnTests {
    private static func screen(_ world: SessionWorld, keyboard: TerminalKeyboard) -> some View {
        NavigationStack {
            SessionScreen(
                graph: world.graph,
                session: SessionWorld.key,
                actions: SessionActions(
                    close: {
                        // the session stays open
                    },
                    open: { _ in
                        // no other session opens
                    },
                    openInNewWindow: nil
                ),
                keyboard: keyboard
            )
        }
        .ngtermTheme()
        .environment(\.horizontalSizeClass, .compact)
    }

    private static func terminals(in view: UIView) -> [TerminalView] {
        ((view as? TerminalView).map { [$0] } ?? []) + view.subviews.flatMap(terminals)
    }

    // every accessibility element under `object`, SwiftUI's among them
    private static func elements(under object: NSObject) -> [NSObject] {
        let listed = object.accessibilityElements?.compactMap { $0 as? NSObject } ?? []
        let children = listed + ((object as? UIView)?.subviews ?? [])
        return children + children.flatMap(elements)
    }

    // `world`'s session view in a window, its chat live and its prompt field with the keyboard: the window and the
    // pane's terminal, under the chat
    private static func open(_ world: ChatWorld, keyboard: TerminalKeyboard) async throws -> (UIWindow, TerminalView) {
        try await world.open()
        await world.chat(
            ChatSamples.event("conv", ChatSamples.conversation),
            ChatSamples.event("u1", ChatSamples.user("Fix the install guide.")),
            ChatSamples.event("live", .live)
        )
        let chat = try #require(world.chat)
        await Wait.until { chat.snapshot.phase == .live }
        let host = UIHostingController(rootView: Self.screen(world.world, keyboard: keyboard))
        let made = (UIWindow.self as UIView.Type).init(frame: CGRect(origin: .zero, size: ScreenVariant.size))
        let window = try #require(made as? UIWindow)
        window.rootViewController = host
        window.makeKeyAndVisible()
        await Wait.until { keyboard.chatField != nil }
        let terminal = try #require(Self.terminals(in: window).first)
        #expect(!terminal.drawsFocused, "under its chat")
        return (window, terminal)
    }

    @Test("the terminal takes the prompt's keyboard before the view changes, and the chat shown again takes it back")
    internal func turn() async throws {
        let world = ChatWorld()
        defer { world.remove() }
        let keyboard = TerminalKeyboard(hardware: HardwareKeyboard(fixed: true))
        let (window, terminal) = try await Self.open(world, keyboard: keyboard)
        defer { window.isHidden = true }

        let model = SessionModel(graph: world.graph, key: SessionWorld.key, keyboard: keyboard)
        model.showTerminal(of: ChatWorld.pane.paneId)
        #expect(terminal.isFirstResponder, "the keyboard goes from the field straight to the terminal")
        #expect(keyboard.target === terminal)
        #expect(terminal.softKeyboardWanted, "the field had the soft keyboard")
        await Wait.until { terminal.drawsFocused }
        #expect(terminal.isFirstResponder)
        await Wait.until { keyboard.chatField == nil }

        model.pick(ChatWorld.pane.paneId, .chat)
        await Wait.until { keyboard.chatField != nil && !terminal.isFirstResponder }
        #expect(keyboard.target == nil)
    }

    @Test("the chat's own Answer in terminal gives the terminal the prompt's keyboard before the view changes")
    internal func answerInTerminal() async throws {
        let world = ChatWorld()
        defer { world.remove() }
        let keyboard = TerminalKeyboard(hardware: HardwareKeyboard(fixed: true))
        let (window, terminal) = try await Self.open(world, keyboard: keyboard)
        defer { window.isHidden = true }

        let chat = try #require(world.chat)
        chat.snapshot.problem = .unconfirmed
        let title = "Answer in terminal"
        await Wait.until { Self.elements(under: window).contains { $0.accessibilityLabel == title } }
        let answer = try #require(Self.elements(under: window).first { $0.accessibilityLabel == title })
        #expect(answer.accessibilityActivate())
        #expect(terminal.isFirstResponder, "the keyboard goes from the field straight to the terminal")
        #expect(keyboard.target === terminal)
        #expect(terminal.softKeyboardWanted, "the field had the soft keyboard")
        await Wait.until { terminal.drawsFocused }
        #expect(terminal.isFirstResponder)
    }
}
