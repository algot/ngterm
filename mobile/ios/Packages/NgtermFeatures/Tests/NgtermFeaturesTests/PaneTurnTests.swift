import NgtermDesign
import NgtermTerminal
import SwiftUI
import Testing
import UIKit

@testable import NgtermFeatures

/// A pane turned from its chat to its terminal (the toolbar's Show terminal) while the chat's prompt field has the
/// keyboard, in the session view: the terminal takes the keyboard from the field once the view update that shows it
/// is over, never inside it (a first responder moved inside the update has the hosting view read its graph mid-update,
/// which can spin for good), and the chat shown again takes it back.
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

    @Test("the terminal takes the prompt's keyboard after the view update, and the chat shown again takes it back")
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

        // the toolbar's Show terminal
        keyboard.handOver()
        world.graph.chats.pick(ChatWorld.pane, .terminal)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        #expect(terminal.drawsFocused, "the view update ran")
        #expect(!terminal.isFirstResponder, "the first responder moved inside the view update")
        await Wait.until { terminal.isFirstResponder }
        #expect(keyboard.target === terminal)
        #expect(terminal.softKeyboardWanted, "the field had the soft keyboard")

        // Show chat
        world.graph.chats.pick(ChatWorld.pane, .chat)
        await Wait.until { keyboard.chatField != nil && !terminal.isFirstResponder }
        #expect(keyboard.target == nil)
    }
}
