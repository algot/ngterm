import NgtermDesign
import SwiftUI

/// The Logs page's actions, each a row: Copy lines shown, Share log (the whole log as a file, through the system's
/// share sheet) and Clear logs, which asks first.
internal struct LogsActions: View {
    /// The page's model: the log, the lines shown and the exports.
    internal let model: LogsModel
    /// Clear logs was tapped: the page asks first.
    internal let onClear: @MainActor () -> Void

    /// The body of the view.
    internal var body: some View {
        Group {
            CopyButton(model.shown, title: String(localized: "Copy lines shown")) {
                Task {
                    await model.copied()
                }
            }
            .disabled(model.shown.isEmpty)
            .accessibilityIdentifier("logs-copy")
            ShareLink(item: LogExport(model: model), preview: SharePreview(String(localized: "ngterm log"))) {
                Label(String(localized: "Share log"), systemImage: "square.and.arrow.up")
                    .font(Typography.detail.weight(.semibold))
                    .frame(minHeight: Spacing.hitTarget)
            }
            .accessibilityIdentifier("logs-share")
            Button(action: onClear) {
                Label(String(localized: "Clear logs"), systemImage: "trash")
                    .font(Typography.detail.weight(.semibold))
                    .foregroundStyle(Palette.failed.color)
                    .frame(minHeight: Spacing.hitTarget)
            }
            .accessibilityIdentifier("logs-clear")
        }
        // a list row's own label cuts the words at the largest text sizes
        .labelStyle(LogsActionLabelStyle())
    }
}
