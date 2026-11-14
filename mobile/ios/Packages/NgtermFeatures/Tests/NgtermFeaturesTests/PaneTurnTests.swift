import NgtermDesign
import NgtermTerminal
import SwiftUI
import Testing
import UIKit

@testable import NgtermFeatures

/// A pane turned from its chat to its terminal (the toolbar's Show terminal) while the chat's prompt field has the
/// keyboard, in the session view: the terminal, under the chat, takes the keyboard straight from the field before the
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

    @Test("the terminal takes the prompt's keyboard before the view changes, and the chat shown again takes it back")
    internal func turn() async throws {
        let world = ChatWorld()
        defer { world.remove() }
        try await world.open()
        await world.chat(
            ChatSamples.event("conv", ChatSamples.conversation),
            ChatSamples.event("u1", ChatSamples.user("Fix the install guide.")),
            ChatSamples.event("live", .live)
        )
        let chat = try #require(world.chat)
        await Wait.until { chat.snapshot.phase == .live }
        let keyboard = TerminalKeyboard(hardware: HardwareKeyboard(fixed: true))
        let host = UIHostingController(rootView: Self.screen(world.world, keyboard: keyboard))
        let made = (UIWindow.self as UIView.Type).init(frame: CGRect(origin: .zero, size: ScreenVariant.size))
        let window = try #require(made as? UIWindow)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await Wait.until { keyboard.chatField != nil }
        let terminal = try #require(Self.terminals(in: window).first)
        #expect(!terminal.drawsFocused, "under its chat")

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
}
