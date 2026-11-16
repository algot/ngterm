import NgtermCoreFakes
import NgtermDesign
import NgtermTerminal
import Testing
import UIKit

/// The keyboard's focus following the session view's selection, in a window of the app's scene (the first responder
/// needs one): the terminal selected next takes the focus the last one had, with its soft keyboard, whether it is on
/// screen already (a split) or comes on as the other goes (a phone's one pane); with a hardware keyboard, a session
/// opened anew gives its selected terminal the focus, and so does one the system reports a keyboard to only after it
/// opened, unless a text field of a sheet over it has the keyboard, whether its terminal or its chat is on yet or not.
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

    @Test("a hardware keyboard that goes before a new session's terminal came on leaves it to wait for a tap")
    internal func keyboardGoesBeforeTerminal() throws {
        let window = try Self.window()
        defer { window.isHidden = true }
        let hardware = HardwareKeyboard(fixed: true)
        let keyboard = TerminalKeyboard(hardware: hardware)
        hardware.update(attached: false)
        let selected = Self.terminal(keyboard, focused: true)
        window.addSubview(selected)
        #expect(!selected.isFirstResponder)
        #expect(keyboard.target == nil)

        hardware.update(attached: true)
        #expect(selected.isFirstResponder, "a keyboard that comes again gives the focus again")
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

    @Test("a keyboard that comes while a sheet's text field has the keyboard leaves the field its focus")
    internal func keyboardComesToAField() throws {
        let window = try Self.window()
        defer { window.isHidden = true }
        let hardware = HardwareKeyboard(fixed: false)
        let keyboard = TerminalKeyboard(hardware: hardware)
        let selected = Self.terminal(keyboard, focused: true)
        window.addSubview(selected)
        selected.focus()
        // a field of a sheet over the session takes the keyboard from the terminal
        let field = UITextField(frame: Self.frame)
        window.addSubview(field)
        #expect(field.becomeFirstResponder())
        #expect(keyboard.target == nil)
        hardware.update(attached: true)
        #expect(field.isFirstResponder, "the field keeps the keyboard")
        #expect(!selected.isFirstResponder)
        #expect(!keyboard.takeChatHandover(), "nothing is left for the chat or the pane selected next")
    }

    @Test("a terminal that comes on under a sheet's text field with the keyboard leaves the field its focus")
    internal func terminalComesUnderAField() throws {
        let window = try Self.window()
        defer { window.isHidden = true }
        // a session opened with a hardware keyboard, its first pane still loading as a sheet's field takes the keyboard
        let opened = TerminalKeyboard(hardware: HardwareKeyboard(fixed: true))
        let field = UITextField(frame: Self.frame)
        window.addSubview(field)
        #expect(field.becomeFirstResponder())
        let first = Self.terminal(opened, focused: true)
        window.addSubview(first)
        #expect(field.isFirstResponder, "the field keeps the keyboard")
        #expect(!first.isFirstResponder)

        // the system reports the keyboard after the session opened, its pane still loading
        let hardware = HardwareKeyboard(fixed: false)
        let late = TerminalKeyboard(hardware: hardware)
        hardware.update(attached: true)
        let second = Self.terminal(late, focused: true)
        window.addSubview(second)
        #expect(field.isFirstResponder, "the field keeps the keyboard")
        #expect(!second.isFirstResponder)
        #expect(!late.takeChatHandover(), "nothing is left for the chat or the pane selected next")
    }

    @Test("a chat that comes on under a sheet's text field with the keyboard leaves the field its focus")
    internal func chatComesUnderAField() throws {
        let window = try Self.window()
        defer { window.isHidden = true }
        let field = UITextField(frame: Self.frame)
        window.addSubview(field)
        #expect(field.becomeFirstResponder())
        // a session opened with a hardware keyboard, its first pane coming on in its chat over its hidden terminal
        let opened = TerminalKeyboard(hardware: HardwareKeyboard(fixed: true))
        window.addSubview(Self.terminal(opened, focused: false))
        #expect(!opened.takeChatHandover(), "the field keeps the keyboard")
        let later = Self.terminal(opened, focused: true)
        window.addSubview(later)
        #expect(!later.isFirstResponder, "taken once")

        // the system reports the keyboard after the session opened, before its pane came on
        let hardware = HardwareKeyboard(fixed: false)
        let late = TerminalKeyboard(hardware: hardware)
        hardware.update(attached: true)
        window.addSubview(Self.terminal(late, focused: false))
        #expect(!late.takeChatHandover(), "the field keeps the keyboard")
        #expect(field.isFirstResponder)
    }

    @Test("a terminal's focus without the soft keyboard goes to its chat only while a hardware keyboard is attached")
    internal func chatTakesFocusWithHardware() throws {
        let window = try Self.window()
        defer { window.isHidden = true }
        let hardware = HardwareKeyboard(fixed: false)
        let keyboard = TerminalKeyboard(hardware: hardware)
        let terminal = Self.terminal(keyboard, focused: true)
        window.addSubview(terminal)
        terminal.focus()
        // its pane turns to its chat, the soft keyboard closed
        terminal.drawsFocused = false
        #expect(!keyboard.takeChatHandover(), "the chat's field would open the soft keyboard")
        #expect(!terminal.isFirstResponder, "the hidden terminal lets the focus and its extra keys go")
        #expect(keyboard.target == nil)
        #expect(!keyboard.takeChatHandover(), "taken once")

        hardware.update(attached: true)
        terminal.drawsFocused = true
        terminal.focus()
        terminal.drawsFocused = false
        #expect(keyboard.takeChatHandover())
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

    @Test("a terminal with the focus drawn unfocused leaves the keyboard to what is drawn focused next, its chat too")
    internal func unfocusedHandsOver() throws {
        let window = try Self.window()
        defer { window.isHidden = true }
        let keyboard = TerminalKeyboard(hardware: HardwareKeyboard(fixed: false))
        let first = Self.terminal(keyboard, focused: true)
        let next = Self.terminal(keyboard, focused: false)
        window.addSubview(first)
        window.addSubview(next)
        first.focus(showingKeyboard: true)
        first.drawsFocused = false
        next.drawsFocused = true
        #expect(next.isFirstResponder)
        #expect(next.softKeyboardWanted, "the soft keyboard stays up")

        // its pane turned to its chat, the chat shown over it takes the keyboard
        next.drawsFocused = false
        #expect(keyboard.takeChatHandover())
        // a terminal without the keyboard drawn unfocused leaves nothing
        first.drawsFocused = true
        #expect(!first.isFirstResponder)
        first.drawsFocused = false
        #expect(!keyboard.takeChatHandover())
    }
}
