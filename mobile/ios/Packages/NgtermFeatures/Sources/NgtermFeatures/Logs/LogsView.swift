import NgtermDesign
import SwiftUI

/// Settings' Logs page (mobile/android's `LogsScreen`): what the log holds and never holds, then Copy lines shown,
/// Share log (the whole log as a file, through the system's share sheet) and Clear logs (confirmed), then the newest
/// lines first under their day.
///
/// A line is its time, its component and what happened; a warning or an error says so with the tone's glyph and word.
/// The log is read again each time the page opens and the app comes back to the foreground.
public struct LogsView: View {
    private static var exportFailedWords: String {
        String(
            localized: """
                The log couldn't be written to a file to share. Free some storage and share again, or copy the lines \
                shown.
                """
        )
    }

    @Environment(\.scenePhase)
    private var scenePhase
    @State private var isConfirmingClear = false
    @State private var model: LogsModel

    /// The body of the view.
    public var body: some View {
        List {
            actions
            if model.isReading {
                Section {
                    LabeledContent(String(localized: "Reading the log")) {
                        ProgressView()
                    }
                    .foregroundStyle(Palette.secondaryText.color)
                }
            } else if model.lines.isEmpty {
                Section {
                    Text("Nothing is logged yet.")
                        .foregroundStyle(Palette.secondaryText.color)
                }
            } else {
                ForEach(LogDay.days(of: model.lines)) { day in
                    Section {
                        ForEach(day.lines) { line in
                            LogRow(line: line.line)
                        }
                    } header: {
                        FormHint(day.day, .header)
                            .accessibilityIdentifier("logs-day")
                    }
                }
            }
        }
        .accessibilityIdentifier("logs-list")
        .navigationTitle(String(localized: "Logs"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if model.exportFailed {
                Banner(.failed, message: Self.exportFailedWords) {
                    model.dismissExportFailure()
                }
                .padding(Spacing.large)
            }
        }
        .confirmingDestructive(
            String(localized: "Clear logs?"),
            isPresented: $isConfirmingClear,
            message: String(
                localized: """
                    Every line is deleted from this device. A problem that happened before now can no longer be read \
                    from the log.
                    """
            ),
            action: RowAction(String(localized: "Clear logs")) {
                Task {
                    await model.clear()
                }
            }
        )
        .task {
            await model.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await model.refresh()
                }
            }
        }
    }

    private var actions: some View {
        Section {
            LogsActions(model: model) {
                isConfirmingClear = true
            }
        } header: {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(LogsWords.holds)
                Text(LogsWords.never)
            }
            .font(.body)
            .foregroundStyle(.primary)
            .textCase(nil)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, Spacing.small)
            .accessibilityIdentifier("logs-about")
        } footer: {
            if !model.isReading {
                FormHint(LogsWords.extent(count: model.lines.count, bytes: model.totalBytes, isCut: model.isCut), .note)
                    .accessibilityIdentifier("logs-extent")
            }
        }
    }

    /// The page over `model`, kept for as long as the page shows.
    public init(model: LogsModel) {
        _model = State(initialValue: model)
    }
}
