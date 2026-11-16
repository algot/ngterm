import SwiftUI

/// The diagnostic log's row, pushing Logs.
internal struct DiagnosticsSection: View {
    internal var body: some View {
        Section {
            NavigationLink(value: SettingsPage.logs) {
                Label(String(localized: "Logs"), systemImage: "doc.text.magnifyingglass")
            }
            .accessibilityIdentifier("settings-logs")
        } header: {
            FormHint(String(localized: "Diagnostics"), .header)
        } footer: {
            FormHint(
                String(
                    localized: """
                        What the app and its connections did, to find why something went wrong. Copy or share it when \
                        you report a problem.
                        """
                ),
                .note
            )
        }
    }
}
