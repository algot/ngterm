import SwiftUI

/// A session in a list: its name with its app's ``PeerBadge`` (`peer`: only where its machine's own app is another)
/// and the Attached mark, its line, and its status.
///
/// The badge and the mark follow the name; with a badge they go under it at an accessibility size rather than cutting
/// it short. The line is the context, the working directory, or "Companion of …"; the status an
/// ``AgentStatusBadge``, or an ``UnderWayLabel`` while the session is being ended ("Ending") or duplicated
/// ("Duplicating"). A companion sits indented under its parent. It reads no app state; its list adds the selection, swipe actions and the context menu.
public struct SessionRow<Status: View>: View {
    @Environment(\.dynamicTypeSize)
    private var typeSize

    private let name: String
    private let line: String?
    private let isCompanion: Bool
    private let isAttached: Bool
    private let isEnding: Bool
    private let isDuplicating: Bool
    private let peer: String?
    private let status: Status

    /// The body of the view.
    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            let heading =
                typeSize.isAccessibilitySize && peer != nil
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xSmall))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Spacing.small))
            heading {
                Text(name)
                    .font(Typography.sessionName)
                    .lineLimit(Spacing.rowLines)
                if let peer {
                    PeerBadge(peer)
                }
                if isAttached {
                    AttachedMark()
                }
            }
            if let line {
                Text(line)
                    .font(Typography.detail)
                    .rowForeground(Palette.secondaryText.color)
                    .lineLimit(Spacing.rowLines)
            }
            if isEnding {
                UnderWayLabel(String(localized: "Ending", bundle: .module))
            } else if isDuplicating {
                UnderWayLabel(String(localized: "Duplicating", bundle: .module))
            } else {
                status
            }
        }
        .padding(.leading, isCompanion ? Spacing.xLarge : 0)
        .padding(.vertical, Spacing.xSmall)
        .frame(minHeight: Spacing.hitTarget)
        .accessibilityElement(children: .combine)
    }

    /// A session named `name` with its `line`, a companion or not, attached by this app or not, being ended or
    /// duplicated or not, the app it is a session of (`peer`, an app's name; `nil` for none to say), and its
    /// `status`.
    public init(
        name: String,
        line: String?,
        isCompanion: Bool = false,
        isAttached: Bool = false,
        isEnding: Bool = false,
        isDuplicating: Bool = false,
        peer: String? = nil,
        @ViewBuilder status: () -> Status
    ) {
        self.name = name
        self.line = line
        self.isCompanion = isCompanion
        self.isAttached = isAttached
        self.isEnding = isEnding
        self.isDuplicating = isDuplicating
        self.peer = peer
        self.status = status()
    }
}
