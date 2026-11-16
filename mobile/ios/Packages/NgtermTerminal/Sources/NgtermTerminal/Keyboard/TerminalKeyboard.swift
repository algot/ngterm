import NgtermCore
import UIKit

/// The keyboard's side of the terminals on screen (mobile/android's `TerminalKeyboard`).
///
/// What the soft keyboard types, the extra keys and a hardware keyboard's keys go to the ``target`` and nowhere else,
/// and only while it is drawn focused (the selected pane), with the extra keys' sticky Ctrl and Alt held for the next
/// key. One keyboard serves every terminal on screen, so
/// the sticky modifiers stay as the focus moves. The target is the terminal that is the first responder. A key from
/// elsewhere than the soft keyboard (an extra key, a sticky tap) commits the composition waiting in the target first,
/// so the program gets the text before the key, in the order it was typed.
@preconcurrency
@MainActor
public final class TerminalKeyboard {
    private static let enter = "enter"

    private var madeBar: ExtraKeysBar?
    private let terminals = NSHashTable<TerminalView>.weakObjects()
    // the focus the terminal or chat that had it left when the selection moved on, or a session opened with a hardware
    // keyboard gives its selected pane: the pane selected next takes it
    private var handingOver: Handover?
    // a SwiftUI view update is changing a terminal now, and whether the take put off for after it is on its way
    private var isUpdatingViews = false
    private var takesAfterUpdate = false

    /// The moves' actions, which the session view sets.
    public var shortcuts: TerminalShortcuts
    /// Whether a hardware keyboard is attached.
    public let hardware: HardwareKeyboard
    /// The sticky Ctrl.
    public private(set) var control = Sticky.off
    /// The sticky Alt.
    public private(set) var alt = Sticky.off
    /// The terminal every key goes to: the one that became the first responder last, if it still is.
    ///
    /// No chat's field has the keyboard a terminal took (``chatField``), though its chat went before it could say so.
    public weak var target: TerminalView? {
        didSet {
            if target != nil {
                chatField = nil
            }
        }
    }
    /// Which chat's prompt field has the keyboard, if one does: the session view's chats say so, as a terminal says
    /// it is the ``target``, so a move of the selection hands the keyboard on from a chat too.
    public var chatField: AnyHashable?

    /// The extra keys, over the soft keyboard.
    public var bar: ExtraKeysBar {
        if let madeBar {
            return madeBar
        }
        let made = ExtraKeysBar(keyboard: self)
        madeBar = made
        return made
    }

    /// How the extra keys lay out, as Settings sets it: the terminal with the focus shows a change at once.
    ///
    /// Hiding them lets go of the sticky Ctrl and Alt, whose keys go with them.
    public var layout = ExtraKeysLayout.fit {
        didSet {
            guard layout != oldValue else {
                return
            }
            if layout == .hidden {
                set(.control, .off)
                set(.alt, .off)
            }
            madeBar?.setNeedsLayout()
            target?.reloadInputViews()
        }
    }

    /// Whether the extra keys show: not while a hardware keyboard is attached, which has every key they have, nor
    /// when Settings hides them.
    public var showsExtraKeys: Bool {
        !hardware.isAttached && layout != .hidden
    }

    /// A keyboard running `shortcuts`, the extra keys standing aside while `hardware` says a keyboard is attached (the
    /// system's by default).
    ///
    /// A session opened while a hardware keyboard is attached gives its selected pane the focus as it comes on, so
    /// typing and the chords go on there without a tap (Android's `FollowFocus`); the soft keyboard still waits for
    /// one. So does a session a hardware keyboard comes to while none of its terminals or chats has the keyboard: the
    /// system reports a keyboard attached all along only after the first session opened. In both, a text field of a
    /// sheet over the session that has the keyboard then keeps it.
    public init(shortcuts: TerminalShortcuts = TerminalShortcuts(), hardware: HardwareKeyboard? = nil) {
        self.shortcuts = shortcuts
        self.hardware = hardware ?? HardwareKeyboard()
        if self.hardware.isAttached {
            handingOver = .focus
        }
        self.hardware.onChange = { [weak self] in
            self?.hardwareChanged()
        }
    }

    /// Where `modifier` stands.
    public func sticky(_ modifier: StickyModifier) -> Sticky {
        switch modifier {
        case .control:
            control

        case .alt:
            alt
        }
    }

    /// A tap on the key of `modifier`, returning where it stands now: off to once, once to locked, locked to off.
    ///
    /// What the target composes was typed before the tap, so it goes first, under the modifiers as they stood.
    @discardableResult
    public func toggle(_ modifier: StickyModifier) -> Sticky {
        target?.commitComposition()
        let next = sticky(modifier).next
        set(modifier, next)
        return next
    }

    /// An extra key's text for the target, after its composition: as ``type(_:to:)``.
    public func type(_ text: String) {
        guard let target else {
            return
        }
        target.commitComposition()
        type(text, to: target)
    }

    /// Presses and lets go of the key Ghostty names `name` on the target, with the sticky modifiers, after its
    /// composition (an extra key).
    public func press(_ name: String) {
        guard let target else {
            return
        }
        target.commitComposition()
        press(name, to: target)
    }

    /// Text for `view`: line breaks go as Enter, the rest as typed text; with a sticky modifier held, the first
    /// character goes as the key that types it, with the modifier.
    ///
    /// A view not drawn focused takes nothing.
    public func type(_ text: String, to view: TerminalView) {
        guard view.drawsFocused else {
            return
        }
        var rest = Substring(text)
        if control != .off || alt != .off, let first = rest.first, first != "\n" {
            view.pressKey(KeyMapping.forText(String(first), mods: takeSticky()))
            rest = rest.dropFirst()
        }
        for (index, line) in rest.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 {
                press(Self.enter, to: view)
            }
            if !line.isEmpty {
                view.send(text: String(line))
            }
        }
    }

    /// Presses and lets go of the key Ghostty names `name` on `view`, with the sticky modifiers; a view not drawn
    /// focused takes nothing.
    public func press(_ name: String, to view: TerminalView) {
        guard view.drawsFocused else {
            return
        }
        view.pressKey(KeyMapping.named(name, mods: takeSticky()))
    }

    /// The sticky modifiers' bits for a key pressed now; a modifier armed once lets go with it.
    public func takeSticky() -> UInt8 {
        var bits: UInt8 = 0
        for modifier in StickyModifier.allCases {
            let state = sticky(modifier)
            if state != .off {
                bits |= modifier.bit
            }
            if state == .once {
                set(modifier, .off)
            }
        }
        return bits
    }

    /// The session view moves the selection to another pane, or builds the selected one anew (another layout).
    ///
    /// When a terminal has the focus now, the one drawn focused next in a window takes it, with the soft keyboard if
    /// this one had it open (Android's `FollowFocus`). A chat's prompt field with the keyboard (``chatField``) hands it
    /// on the same way, with the soft keyboard. With neither, a handover not taken yet waits for the pane selected
    /// next.
    public func handOver() {
        if let target {
            handingOver = target.softKeyboardWanted ? .withKeyboard : .focus
        } else if chatField != nil {
            handingOver = .withKeyboard
        }
    }

    /// The session view shows the terminal of `pane` in its chat's place.
    ///
    /// As ``handOver()``, and that terminal, laid out under the chat, takes the keyboard at once, before the view
    /// changes, so the soft keyboard goes from the chat's prompt field straight to it. A pane with no terminal in a
    /// window leaves the handover for it.
    public func handOver(to pane: any PaneClient) {
        handOver()
        terminals.allObjects.first { $0.pane === pane }?.takeHandover(comingOn: true)
    }

    /// Whether ``handOver()`` left the keyboard for the chat selected next, which takes its prompt field's focus;
    /// taken once.
    ///
    /// The focus without the soft keyboard goes to the chat only while a hardware keyboard is attached, and not while
    /// a text field of a sheet over the session has the keyboard: the field taking it opens the soft keyboard, which
    /// the terminal handing it over had closed. Without one, that terminal, no longer drawn focused, lets the focus go,
    /// its extra keys with it.
    public func takeChatHandover() -> Bool {
        switch takeHandover() {
        case .withKeyboard:
            return true

        case .focus:
            if hardware.isAttached {
                return !otherHoldsKeyboard()
            }
            if let target, !target.drawsFocused {
                _ = target.resignFirstResponder()
            }
            return false

        case nil:
            return false
        }
    }

    /// What ``handOver()`` left for the terminal selected next in `window`, taken once: the focus alone is dropped
    /// while a text field of a sheet there has the keyboard, which a terminal coming on under it leaves there.
    ///
    /// Nothing is taken inside a SwiftUI view update (``duringViewUpdate(_:)``): the handover waits for its end.
    internal func takeHandover(in window: UIWindow) -> Handover? {
        guard !isUpdatingViews else {
            return nil
        }
        let handover = takeHandover()
        return handover == .focus && otherHoldsKeyboard(in: window) ? nil : handover
    }

    /// Runs `update`, a SwiftUI view update's changes to a terminal: the handover it would take then (it is drawn
    /// focused) is taken once the update is over.
    ///
    /// A first responder that moves inside the update has UIKit tell the hosting view at once, which reads its graph
    /// in the middle of that graph's update: a cycle, which can spin for good.
    internal func duringViewUpdate(_ update: () -> Void) {
        isUpdatingViews = true
        update()
        isUpdatingViews = false
        takeAfterViewUpdate()
    }

    /// The terminals drawn focused take the handover waiting once the SwiftUI view update running now is over: what
    /// ``duringViewUpdate(_:)`` puts off, and a terminal the update puts in a window, for the same reason.
    internal func takeAfterViewUpdate() {
        guard handingOver != nil, !takesAfterUpdate else {
            return
        }
        takesAfterUpdate = true
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            takesAfterUpdate = false
            for terminal in terminals.allObjects {
                terminal.takeHandover()
            }
        }
    }

    /// `terminal` types through this keyboard, so it hears of a hardware keyboard that comes.
    internal func serve(_ terminal: TerminalView) {
        terminals.add(terminal)
    }

    /// Shows the extra keys as things stand now: the sticky modifiers, and whether the soft keyboard is open.
    internal func refreshBar() {
        madeBar?.refresh()
    }

    // a keyboard came or went: the extra keys show or stand aside, and one that came with nothing holding the keyboard
    // gives the selected pane the focus, now or as it comes on (a chat takes it as it sees the keyboard come); a text
    // field of the app's own, a sheet's over the session, keeps it, and no pane takes it from there later; one that
    // went before a pane took that focus takes it back, so the pane waits for a tap
    private func hardwareChanged() {
        target?.reloadInputViews()
        guard target == nil, chatField == nil else {
            return
        }
        guard hardware.isAttached else {
            if handingOver == .focus {
                handingOver = nil
            }
            return
        }
        guard !otherHoldsKeyboard() else {
            handingOver = nil
            return
        }
        handingOver = handingOver ?? .focus
        for terminal in terminals.allObjects {
            terminal.takeHandover()
        }
    }

    // what handOver() left, taken once
    private func takeHandover() -> Handover? {
        defer { handingOver = nil }
        return handingOver
    }

    // whether a view other than a terminal is the first responder in a window the terminals are in, a hidden one
    // under a chat too: a sheet's field over the session, which tells this keyboard nothing
    private func otherHoldsKeyboard() -> Bool {
        Set(terminals.allObjects.compactMap(\.window)).contains(where: otherHoldsKeyboard(in:))
    }

    private func otherHoldsKeyboard(in window: UIWindow) -> Bool {
        firstResponder(in: window).map { !($0 is TerminalView) } ?? false
    }

    private func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder {
            return view
        }
        for subview in view.subviews {
            if let found = firstResponder(in: subview) {
                return found
            }
        }
        return nil
    }

    private func set(_ modifier: StickyModifier, _ state: Sticky) {
        switch modifier {
        case .control:
            control = state

        case .alt:
            alt = state
        }
        madeBar?.refresh()
    }

    deinit {
        // the hardware keyboard's change runs through a weak reference
    }
}
