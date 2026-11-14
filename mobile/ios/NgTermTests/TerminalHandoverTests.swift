import NgtermCoreFakes
import NgtermDesign
import NgtermTerminal
import Testing
import UIKit

/// The keyboard's focus following the session view's selection, in a window of the app's scene (the first responder
/// needs one): the terminal selected next takes the focus the last one had, with its soft keyboard, whether it is on
/// screen already (a split) or comes on as the other goes (a phone's one pane); with a hardware keyboard, a session
/// opened anew gives its selected terminal the focus, and so does one the system reports a keyboard to only after it
/// opened.
@MainActor
@Suite("the focus handed over between panes")
internal struct TerminalHandoverTests {
    private static let frame = CGRect(x: 0, y: 0, width: 200, height: 100)

    private static func window() throws -> UIWindow {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = UIWindow(windowScene: try #require(scenes.first))
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        window.makeKeyAndVisible()
        return window
    }

    private static func terminal(_ keyboard: TerminalKeyboard, focused: Bool) -> TerminalView {
        let view = TerminalView(pane: FakePane(), palette: .copper, textSize: 13, keyboard: keyboard)
        view.frame = frame
        view.drawsFocused = focused
        return view
    }

    @Test("in a split, the pane selected next takes the focus and the soft keyboard; a touch selects")
    internal func split() throws {
        let window = try Self.window()
        defer { window.isHidden = true }
        let keyboard = TerminalKeyboard(hardware: HardwareKeyboard(fixed: false))
        let first = Self.terminal(keyboard, focused: true)
        let second = Self.terminal(keyboard, focused: false)
        var selected: [String] = []
        first.onSelect = { selected.append("first") }
        second.onSelect = { selected.append("second") }
        window.addSubview(first)
        window.addSubview(second)

        first.focus(showingKeyboard: true)
        #expect(first.isFirstResponder)
        #expect(selected == ["first"], "taking the focus selects the pane")
        keyboard.handOver()
        first.drawsFocused = false
        second.drawsFocused = true
        #expect(second.isFirstResponder)
        #expect(second.softKeyboardWanted)
        #expect(keyboard.target === second)

        // with nothing focused, a new selection takes no focus
        _ = second.resignFirstResponder()
        keyboard.handOver()
        second.drawsFocused = false
        first.drawsFocused = true
        #expect(!first.isFirstResponder)
    }

    @Test("on a phone, the pane that comes on as the other goes takes the focus, without the soft keyboard if closed")
    internal func onePane() throws {
        let window = try Self.window()
        defer { window.isHidden = true }
        let keyboard = TerminalKeyboard(hardware: HardwareKeyboard(fixed: false))
        let first = Self.terminal(keyboard, focused: true)
        window.addSubview(first)
        first.focus()
        #expect(first.isFirstResponder)

        keyboard.handOver()
        let second = Self.terminal(keyboard, focused: true)
        first.removeFromSuperview()
        window.addSubview(second)
        #expect(second.isFirstResponder)
        #expect(!second.softKeyboardWanted)

        // taken once: a terminal coming on later takes nothing
        let third = Self.terminal(keyboard, focused: true)
        window.addSubview(third)
        #expect(!third.isFirstResponder)
    }

    @Test("with a hardware keyboard, a new session's selected terminal takes the focus as it comes on; without, none")
    internal func newSession() throws {
        let window = try Self.window()
        defer { window.isHidden = true }
        let attached = TerminalKeyboard(hardware: HardwareKeyboard(fixed: true))
        let other = Self.terminal(attached, focused: false)
        window.addSubview(other)
        #expect(!other.isFirstResponder, "a pane not selected takes nothing")
        let selected = Self.terminal(attached, focused: true)
        window.addSubview(selected)
        #expect(selected.isFirstResponder)
        #expect(!selected.softKeyboardWanted)
        #expect(attached.target === selected)

        let soft = TerminalKeyboard(hardware: HardwareKeyboard(fixed: false))
        let alone = Self.terminal(soft, focused: true)
        window.addSubview(alone)
        #expect(!alone.isFirstResponder, "without a hardware keyboard the soft one waits for a tap")
    }

    @Test("with a hardware keyboard, a new session's focus outlasts a layout change made before any terminal came on")
    internal func newSessionRelaid() throws {
        let window = try Self.window()
        defer { window.isHidden = true }
        let keyboard = TerminalKeyboard(hardware: HardwareKeyboard(fixed: true))
        keyboard.handOver()
        let selected = Self.terminal(keyboard, focused: true)
        window.addSubview(selected)
        #expect(selected.isFirstResponder)
        #expect(keyboard.target === selected)
    }

    @Test("a keyboard the system reports after the session opened gives its selected terminal the focus, now or later")
    internal func keyboardReportedLate() throws {
        let window = try Self.window()
        defer { window.isHidden = true }
        let hardware = HardwareKeyboard(fixed: false)
        let keyboard = TerminalKeyboard(hardware: hardware)
        let other = Self.terminal(keyboard, focused: false)
        let selected = Self.terminal(keyboard, focused: true)
        window.addSubview(other)
        window.addSubview(selected)
        #expect(!selected.isFirstResponder, "without a hardware keyboard the soft one waits for a tap")
        hardware.update(attached: true)
        #expect(selected.isFirstResponder)
        #expect(!selected.softKeyboardWanted)
        #expect(keyboard.target === selected)
        #expect(!other.isFirstResponder, "a pane not selected takes nothing")

        // a session whose terminal isn't on yet: it takes the focus as it comes on
        let later = HardwareKeyboard(fixed: false)
        let waiting = TerminalKeyboard(hardware: later)
        later.update(attached: true)
        let comesOn = Self.terminal(waiting, focused: true)
        window.addSubview(comesOn)
        #expect(comesOn.isFirstResponder)
    }

    @Test("a keyboard that comes while a terminal or a chat has the keyboard leaves the focus where it is")
    internal func keyboardComesToFocus() throws {
        let window = try Self.window()
        defer { window.isHidden = true }
        let hardware = HardwareKeyboard(fixed: false)
        let keyboard = TerminalKeyboard(hardware: hardware)
        let tapped = Self.terminal(keyboard, focused: true)
        window.addSubview(tapped)
        tapped.focus(showingKeyboard: true)
        hardware.update(attached: true)
        #expect(keyboard.target === tapped)
        #expect(!keyboard.takeChatHandover(), "nothing is left for the next pane")

        let chatHardware = HardwareKeyboard(fixed: false)
        let chatKeyboard = TerminalKeyboard(hardware: chatHardware)
        chatKeyboard.chatField = "P1"
        chatHardware.update(attached: true)
        #expect(!chatKeyboard.takeChatHandover(), "the chat's field keeps the keyboard")
    }

    @Test("the terminal with the focus leaves the handover to the pane selected next, though drawn focused again")
    internal func handoverOutlastsAnUpdate() throws {
        let window = try Self.window()
        defer { window.isHidden = true }
        let keyboard = TerminalKeyboard(hardware: HardwareKeyboard(fixed: true))
        let first = Self.terminal(keyboard, focused: true)
        let second = Self.terminal(keyboard, focused: false)
        window.addSubview(first)
        window.addSubview(second)
        #expect(first.isFirstResponder)

        keyboard.handOver()
        // the session view updates the pane it still draws selected before the selection reaches it
        first.drawsFocused = true
        first.drawsFocused = false
        second.drawsFocused = true
        #expect(second.isFirstResponder)
        #expect(keyboard.target === second)
    }

    @Test("a terminal with the focus that leaves its window hands it to what takes its pane's place")
    internal func leavingHandsOver() throws {
        let window = try Self.window()
        defer { window.isHidden = true }
        let keyboard = TerminalKeyboard(hardware: HardwareKeyboard(fixed: false))
        let first = Self.terminal(keyboard, focused: true)
        window.addSubview(first)
        first.focus(showingKeyboard: true)
        first.removeFromSuperview()
        let next = Self.terminal(keyboard, focused: true)
        window.addSubview(next)
        #expect(next.isFirstResponder)
        #expect(next.softKeyboardWanted, "the soft keyboard stays up")

        // a chat in its place takes it as well; a terminal without the focus that leaves hands nothing
        next.removeFromSuperview()
        #expect(keyboard.takeChatHandover())
        let unfocused = Self.terminal(keyboard, focused: true)
        window.addSubview(unfocused)
        #expect(!unfocused.isFirstResponder)
        unfocused.removeFromSuperview()
        #expect(!keyboard.takeChatHandover())
    }
}
