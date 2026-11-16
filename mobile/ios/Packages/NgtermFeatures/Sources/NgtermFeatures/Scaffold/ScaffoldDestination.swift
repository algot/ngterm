/// Where a window is, as the log names it (mobile/android's destinations, with iOS's own columns).
public enum ScaffoldDestination: Sendable {
    /// The machines.
    case machines
    /// A session's view.
    case session
    /// A machine's sessions.
    case sessions
    /// Settings.
    case settings
}
