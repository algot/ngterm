/// Whether a session's panes running an agent show as a chat, and how to set it for that session alone.
public struct ChatViewChoice {
    /// Whether they show as a chat: the session's own choice, else Settings' Agent chat view; never in a session whose
    /// app has none.
    public let isOn: Bool
    /// The name of the app without a chat view that the session is one of ("agterm"), or `nil` when its app has one.
    public let noChatOn: String?
    /// Sets the session's own choice; one equal to Settings' follows Settings again.
    public let set: @MainActor (Bool) -> Void

    /// The choice `isOn`, set through `set`, in a session whose app has no chat view when `noChatOn` names it.
    @preconcurrency
    public init(isOn: Bool, noChatOn: String? = nil, set: @escaping @MainActor (Bool) -> Void) {
        self.isOn = isOn && noChatOn == nil
        self.noChatOn = noChatOn
        self.set = set
    }
}
