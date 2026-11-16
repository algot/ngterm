/// The app's own components in the log, as Android names them.
public enum LogTag: String, Sendable {
    /// The process: started, on screen or not, the network, a crash.
    case app = "app"
    /// The chat view's own decisions about a message.
    case chatUI = "chat-ui"
    /// The Logs screen's actions.
    case logs = "logs"
    /// Where the user went.
    case nav = "nav"
}
