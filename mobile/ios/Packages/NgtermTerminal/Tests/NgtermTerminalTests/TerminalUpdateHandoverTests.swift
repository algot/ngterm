import NgtermCoreFakes
import NgtermTerminal
import SwiftUI
import Testing
import UIKit

/// The keyboard's handover to a terminal SwiftUI draws focused or puts in a window: it takes the first responder once
/// the view update is over, never inside it.
///
/// UIKit tells the hosting view of a first responder's change at once, and the hosting view then reads its graph: in
/// the middle of that graph's update the read is a cycle, which can spin for good (the session view stopped answering
/// as a pane turned from its chat to its terminal).
@MainActor
@Suite("the focus handed over to a terminal in a view update")
internal struct TerminalUpdateHandoverTests {
    private struct Slot: View {
        let terminal: TerminalViewRepresentable?

        var body: some View {
            if let terminal {
                terminal
            } else {
                Color.clear
            }
        }
    }

    private static let frame = CGRect(x: 0, y: 0, width: 390, height: 200)
    private static let waitSeconds = 10

    private static func terminals(in view: UIView) -> [TerminalView] {
        ((view as? TerminalView).map { [$0] } ?? []) + view.subviews.flatMap(terminals)
    }

    private static func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(waitSeconds)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test("a terminal a view update draws focused takes the focus handed over after the update, with the soft keyboard")
    internal func afterUpdate() async throws {
        let keyboard = TerminalKeyboard(hardware: HardwareKeyboard(fixed: false))
        let pane = FakePane()
        let feed = TerminalFeed()
        let terminal: (Bool) -> TerminalViewRepresentable = { focused in
            TerminalViewRepresentable(
                pane: pane,
                feed: feed,
                palette: .copper,
                textSize: TerminalRig.textSize,
                focused: focused
            )
            .keyboard(keyboard)
        }
        let host = UIHostingController(rootView: terminal(false))
        let window = try TestWindow.make(Self.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.layoutIfNeeded()
        let view = try #require(Self.terminals(in: host.view).first)
        #expect(!view.drawsFocused)

        // a chat's prompt field had the keyboard as the pane turned to its terminal
        keyboard.chatField = "prompt"
        keyboard.handOver()
        keyboard.chatField = nil
        host.rootView = terminal(true)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        #expect(view.drawsFocused, "the view update ran")
        #expect(!view.isFirstResponder, "the first responder moved inside the view update")
        await Self.until { view.isFirstResponder }
        #expect(view.isFirstResponder)
        #expect(view.softKeyboardWanted)
        #expect(keyboard.target === view)
    }

    @Test("a terminal a view update puts in a window takes the focus handed over after the update")
    internal func mounted() async throws {
        let keyboard = TerminalKeyboard(hardware: HardwareKeyboard(fixed: false))
        let terminal = TerminalViewRepresentable(
            pane: FakePane(),
            feed: TerminalFeed(),
            palette: .copper,
            textSize: TerminalRig.textSize
        )
        .keyboard(keyboard)
        let host = UIHostingController(rootView: Slot(terminal: nil))
        let window = try TestWindow.make(Self.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.layoutIfNeeded()
        #expect(Self.terminals(in: host.view).isEmpty)

        // another pane's chat had the keyboard as the selection came to a pane whose terminal is built now
        keyboard.chatField = "prompt"
        keyboard.handOver()
        keyboard.chatField = nil
        host.rootView = Slot(terminal: terminal)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let view = try #require(Self.terminals(in: host.view).first)
        #expect(view.window != nil, "the view update put it in the window")
        #expect(!view.isFirstResponder, "the first responder moved inside the view update")
        await Self.until { view.isFirstResponder }
        #expect(view.isFirstResponder)
        #expect(view.softKeyboardWanted)
        #expect(keyboard.target === view)
    }
}
