import Foundation
import NgtermCore
import NgtermFeatures
import Synchronization
import UIKit

/// The process's diagnostic log: opened before the core, with the line every later one is read against, and the
/// crashes it records (an Objective-C exception as it ends the process, and the crashes of earlier runs the system
/// reports as the app starts).
internal enum AppLogs {
    // where an uncaught exception's line goes: the handler is a C function, which captures nothing
    private static let crashes = Mutex(Diagnostics())

    /// The device's model identifier (`iPhone17,3`), the simulated one's on a simulator.
    internal static var deviceModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: system.machine) { bytes in
            String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) ?? "unknown"
        }
    }

    // an Objective-C exception no one catches is a line as it ends the process
    private static func catchExceptions(to diagnostics: Diagnostics) {
        crashes.withLock { $0 = diagnostics }
        NSSetUncaughtExceptionHandler { exception in
            let line = CrashLines.exception(
                name: exception.name.rawValue,
                thread: Thread.isMainThread ? "main" : "other",
                symbols: exception.callStackSymbols
            )
            Self.crashes.withLock { $0 }.error(.app, line)
        }
    }

    /// Opens the log in `directory`, says the app started, and records its crashes from now on.
    @MainActor
    internal static func open(in directory: URL) -> any AppLogProtocol {
        let log = CoreLog.open(directory: directory)
        let diagnostics = Diagnostics(log: log)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        diagnostics.started(
            version: version ?? "unknown",
            system: UIDevice.current.systemVersion,
            device: deviceModel
        )
        catchExceptions(to: diagnostics)
        CrashReports.shared.start(diagnostics)
        return log
    }
}
