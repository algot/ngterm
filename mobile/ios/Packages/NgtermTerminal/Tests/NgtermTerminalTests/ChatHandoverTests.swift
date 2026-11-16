import NgtermCoreFakes
import NgtermTerminal
import Testing
import UIKit

/// The keyboard's handover from a chat's prompt field: the session view moving the selection hands the keyboard on from
/// a chat as from a terminal, and only once; a session opened with a hardware keyboard attached hands its selected pane
/// the focus as it comes on.
@MainActor
@Suite("the keyboard handed on from a chat")
internal struct ChatHandoverTests {
    @Test("a chat's field with the keyboard hands it on once; with no terminal or chat holding it, nothing is handed")
    internal func handover() {
        let keyboard = TerminalKeyboard(hardware: HardwareKeyboard(fixed: false))
        keyboard.handOver()
        #expect(!keyboard.takeChatHandover(), "nothing had the keyboard")
        keyboard.chatField = "P1"
        keyboard.handOver()
        #expect(keyboard.takeChatHandover())
        #expect(!keyboard.takeChatHandover(), "taken once")
        keyboard.chatField = nil
        keyboard.handOver()
        #expect(!keyboard.takeChatHandover(), "a chat that let its field go hands nothing on")
    }

    @Test("a session opened with a hardware keyboard attached gives its selected chat the focus, once")
    internal func newSession() {
        let keyboard = TerminalKeyboard(hardware: HardwareKeyboard(fixed: true))
        keyboard.handOver()
        #expect(keyboard.takeChatHandover(), "a handover with nothing holding the keyboard keeps the session's own")
        #expect(!keyboard.takeChatHandover(), "taken once")
    }

    @Test("a pane turned to its terminal gives it the chat field's keyboard at once; with no terminal yet, it waits")
    internal func turnedToTerminal() throws {
        let window = try TestWindow.make(CGRect(x: 0, y: 0, width: 390, height: 400))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let keyboard = TerminalKeyboard(hardware: HardwareKeyboard(fixed: false))
        let terminals = (0..<2).map { _ in
            let view = TerminalView(
                pane: FakePane(),
                palette: .copper,
                textSize: TerminalRig.textSize,
                keyboard: keyboard
            )
            view.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
            view.drawsFocused = false
            window.addSubview(view)
            return view
        }
        let under = terminals[0]

        keyboard.chatField = "prompt"
        keyboard.handOver(to: under.pane)
        #expect(under.isFirstResponder, "the terminal under the chat, before it is drawn focused")
        #expect(under.softKeyboardWanted, "the field had the soft keyboard")
        #expect(keyboard.target === under)
        #expect(!terminals[1].isFirstResponder)
        #expect(keyboard.chatField == nil, "the terminal has the keyboard now, not the field")
        #expect(!keyboard.takeChatHandover(), "taken once")
        under.insertText("l")
        let pane = try #require(under.pane as? FakePane)
        #expect(pane.inputs.contains(.typed("l")), "a key typed before the view draws it focused went nowhere")

        // the pane's terminal isn't on screen yet: the handover waits for it
        _ = under.resignFirstResponder()
        keyboard.chatField = "prompt"
        keyboard.handOver(to: FakePane())
        #expect(keyboard.target == nil)
        #expect(keyboard.takeChatHandover(), "left for the terminal as it comes on")
    }
}
