import NgtermTerminal
import Testing

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
}
