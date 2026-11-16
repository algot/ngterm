import NgtermCore

/// Where the app writes its own lines of the diagnostic log (the core writes its own); with no log (a test that gives
/// none), nowhere.
///
/// A line says what happened in the app (a screen opened, the app left the screen, a message was not sent and why),
/// never what the user typed, a message's text, terminal output, a key or a passphrase: a call site passes fixed words
/// and classes only.
public struct Diagnostics: Sendable {
    /// The process's log, if any.
    public let log: (any AppLogProtocol)?

    /// Lines written to `log`, or nowhere without one.
    public init(log: (any AppLogProtocol)? = nil) {
        self.log = log
    }

    /// Writes an ordinary event of the component `tag`.
    public func info(_ tag: LogTag, _ message: String) {
        log?.append(level: .info, tag: tag.rawValue, message: message)
    }

    /// Writes something that went wrong but the app went on from.
    public func warn(_ tag: LogTag, _ message: String) {
        log?.append(level: .warn, tag: tag.rawValue, message: message)
    }

    /// Writes the line every later one is read against.
    ///
    /// It names the app's `version`, the `system`'s and the `device`'s model.
    public func started(version: String, system: String, device: String) {
        info(.app, "started version=\(version) ios=\(system) device=\(device)")
    }

    /// Writes a failure.
    public func error(_ tag: LogTag, _ message: String) {
        log?.append(level: .error, tag: tag.rawValue, message: message)
    }
}
