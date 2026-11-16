import Foundation
import MetricKit
import NgtermFeatures
import Synchronization

/// Writes the crashes of earlier runs the system reports (MetricKit's diagnostics, delivered as the app starts) to
/// the log: each one's class, signal and top frame, never its reason.
internal final class CrashReports: NSObject, MXMetricManagerSubscriber, Sendable {
    /// The one subscriber, for as long as the app runs.
    internal static let shared = CrashReports()

    private let diagnostics = Mutex(Diagnostics())

    /// Starts writing what the system reports to `diagnostics`.
    internal func start(_ diagnostics: Diagnostics) {
        self.diagnostics.withLock { $0 = diagnostics }
        MXMetricManager.shared.add(self)
    }

    internal func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let log = diagnostics.withLock { $0 }
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                log.error(
                    .app,
                    CrashLines.reported(
                        exceptionType: crash.exceptionType?.intValue,
                        signal: crash.signal?.intValue,
                        callStacks: crash.callStackTree.jsonRepresentation(),
                        time: payload.timeStampBegin
                    )
                )
            }
        }
    }

    deinit {
        // the subscriber lives as long as the app
    }
}
