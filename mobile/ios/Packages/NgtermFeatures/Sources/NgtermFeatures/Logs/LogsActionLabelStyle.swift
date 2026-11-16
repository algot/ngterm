import SwiftUI

/// A Logs action's label: its glyph in a column of its own, its words beside it wrapping at the row's width.
///
/// At the largest text sizes the words wrap in full, where a list row's own label lays them out at a width they no
/// longer fit and cuts them. The row's separator starts under the words, as a list row's own label has it.
internal struct LogsActionLabelStyle: LabelStyle {
    internal func makeBody(configuration: Configuration) -> some View {
        LogsActionLabel(configuration: configuration)
    }
}
