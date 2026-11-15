import NgtermDesign
import SwiftUI

/// What is said over a machine's sessions or its empty state while they stay usable: the device is offline, the last
/// refresh failed (with Retry), and why the machine's agterm lists nothing (no action: the fix is on the machine).
internal struct SessionsBanners: View {
    internal let isOffline: Bool
    internal let failure: String?
    internal let hint: String?
    internal let onRetry: @MainActor () -> Void

    /// Whether there is anything to say.
    internal var isShown: Bool {
        isOffline || failure != nil || hint != nil
    }

    internal var body: some View {
        VStack(spacing: Spacing.small) {
            if isOffline {
                Banner(
                    .offline,
                    message: String(localized: "You're offline"),
                    note: String(localized: "Connected machines reconnect when the network is back.")
                )
            }
            if let failure {
                Banner(
                    .failed,
                    message: String(localized: "The list may be out of date"),
                    note: failure,
                    action: RowAction(String(localized: "Retry"), perform: onRetry)
                )
            }
            if let hint {
                let (message, note) = Self.split(hint: hint)
                Banner(.attention, message: message, note: note)
            }
        }
    }

    /// The core's hint as a banner's message over its note: what is wrong, then what to change.
    internal static func split(hint: String) -> (message: String, note: String?) {
        guard let colon = hint.range(of: ": ") else {
            return (hint, nil)
        }
        let rest = hint[colon.upperBound...]
        return (String(hint[..<colon.lowerBound]), rest.prefix(1).uppercased() + rest.dropFirst())
    }
}
