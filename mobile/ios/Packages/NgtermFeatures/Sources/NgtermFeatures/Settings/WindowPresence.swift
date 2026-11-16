import SwiftUI

/// Tells `onChange` whether the view it sits behind is in a window: true as it joins one, false as it leaves it.
///
/// A pushed page takes the page under it out of the window until Back; this is how a SwiftUI view learns that.
internal struct WindowPresence: UIViewRepresentable {
    internal let onChange: @MainActor (Bool) -> Void

    internal func makeUIView(context _: Context) -> WindowPresenceView {
        let view = WindowPresenceView(frame: .zero)
        view.onChange = onChange
        return view
    }

    internal func updateUIView(_ view: WindowPresenceView, context _: Context) {
        view.onChange = onChange
    }
}
