import NgtermCore

extension ChatModel {
    /// What a chat model reads besides its pane's events: the core, the pane's handle, whether the agent works on a
    /// turn, how many times the machine's link came back, what to do once the chat ended, and where it says why an
    /// action was not sent and what became of one that was.
    public struct Sources {
        /// The core.
        public let core: any MobileCoreClient
        /// The pane's handle while it is shown.
        public let handle: @MainActor () -> (any PaneClient)?
        /// Whether the session's agent status says the pane's agent works on a turn.
        public let isWorking: @MainActor () -> Bool
        /// How many times the pane's machine's link has come up.
        public let connects: @MainActor () -> Int
        /// The chat (the one given) ended, or never opened.
        public let onEnded: @MainActor (ChatModel) -> Void
        /// The diagnostic log's lines of the chat view.
        public let diagnostics: Diagnostics

        /// The sources given.
        @preconcurrency
        public init(
            core: any MobileCoreClient,
            handle: @escaping @MainActor () -> (any PaneClient)?,
            isWorking: @escaping @MainActor () -> Bool,
            connects: @escaping @MainActor () -> Int,
            onEnded: @escaping @MainActor (ChatModel) -> Void,
            diagnostics: Diagnostics = Diagnostics()
        ) {
            self.diagnostics = diagnostics
            self.core = core
            self.handle = handle
            self.isWorking = isWorking
            self.connects = connects
            self.onEnded = onEnded
        }
    }
}
