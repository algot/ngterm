import NgtermDesign
import SwiftUI

/// One line: its time and component over what happened, a warning or an error named by its tone's badge.
internal struct LogRow: View {
    internal let line: LogLine

    internal var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            heading
            Text(verbatim: line.text)
                .font(Typography.address)
                .textSelection(.enabled)
        }
        .padding(.vertical, Spacing.xxSmall)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("log-line")
    }

    // the time quiet and the component strong, then a warning's or an error's badge, beside them where it fits
    private var heading: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
                stamp
                badge
            }
            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                stamp
                badge
            }
        }
    }

    private var stamp: Text {
        let time = Text(verbatim: line.time).font(Typography.address).foregroundStyle(Palette.secondaryText.color)
        let tag = Text(verbatim: line.tag).font(Typography.plateLabel)
        if line.time.isEmpty {
            return tag
        }
        return line.tag.isEmpty ? time : Text("\(time) \(tag)")
    }

    @ViewBuilder private var badge: some View {
        switch line.level {
        case .info:
            EmptyView()

        case .warning:
            StatusBadge(.attention, label: String(localized: "warning"))

        case .error:
            StatusBadge(.failed, label: String(localized: "error"))
        }
    }
}
