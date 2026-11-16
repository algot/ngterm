import UIKit

/// The view of ``WindowPresence``.
///
/// It is empty, and it says each time it joins or leaves a window.
internal final class WindowPresenceView: UIView {
    /// Called with whether the view is now in a window.
    internal var onChange: (@MainActor (Bool) -> Void)?

    override internal init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable, message: "made in code")
    internal required init?(coder _: NSCoder) {
        nil
    }

    override internal func didMoveToWindow() {
        super.didMoveToWindow()
        onChange?(window != nil)
    }

    deinit {
        // nothing to release: SwiftUI drops the view with the form
    }
}
