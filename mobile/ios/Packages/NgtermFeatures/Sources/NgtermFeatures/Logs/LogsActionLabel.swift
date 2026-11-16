import NgtermDesign
import SwiftUI

/// The body of ``LogsActionLabelStyle``: the glyph's column, as wide as the text size makes it, then the words.
internal struct LogsActionLabel: View {
    // the glyph's column at the default text size, in points
    private static let glyphColumn: CGFloat = 28

    /// The label's glyph and words.
    internal let configuration: LabelStyleConfiguration
    @ScaledMetric(relativeTo: .subheadline)
    private var glyphWidth = Self.glyphColumn

    /// The body of the view.
    internal var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.medium) {
            configuration.icon
                .frame(width: glyphWidth)
            configuration.title
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                    dimensions[.leading]
                }
        }
    }
}
