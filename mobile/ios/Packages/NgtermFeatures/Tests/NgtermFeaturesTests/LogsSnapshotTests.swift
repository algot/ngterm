import Foundation
import NgtermCoreFakes
import SwiftUI
import Testing

@testable import NgtermFeatures

/// Goldens of the Logs page: lines over two days with a warning and an error, its actions at an accessibility text
/// size, and a Share that couldn't write its file.
@MainActor
@Suite("Logs snapshots")
internal struct LogsSnapshotTests {
    // a log written at fixed times: the evening before, then this morning
    private static func log() -> MemoryAppLog {
        let times = LogClock()
        let log = MemoryAppLog { times.next() }
        log.append(level: .info, tag: "app", message: "started version=0.2.5 ios=27.0 device=iPhone18,3")
        log.append(level: .error, tag: "app", message: "earlier crash class=EXC_BREAKPOINT signal=SIGTRAP")
        log.append(level: .info, tag: "link", message: "connect asked machine=m1 label=build-01 port=22")
        log.append(level: .warn, tag: "link", message: "reconnecting machine=m1 delay=4")
        log.append(level: .info, tag: "chat-ui", message: "action result=sent")
        log.append(level: .info, tag: "nav", message: "settings page=logs")
        return log
    }

    private static func page(_ model: LogsModel) -> some View {
        NavigationStack {
            LogsView(model: model)
        }
    }

    @Test("the log's lines under their days, newest first", arguments: ScreenVariant.allCases)
    internal func lines(variant: ScreenVariant) async {
        let model = LogsModel(log: Self.log(), exportDirectory: FileManager.default.temporaryDirectory)
        await model.refresh()
        ScreenSnapshot.check(Self.page(model), named: "logs", variant: variant)
    }

    // the actions at the largest text size the goldens take, with nothing above them: each wraps, none is cut
    @Test("the actions at an accessibility text size")
    internal func actions() async {
        let model = LogsModel(log: Self.log(), exportDirectory: FileManager.default.temporaryDirectory)
        await model.refresh()
        let page = NavigationStack {
            List {
                Section {
                    LogsActions(model: model) {
                        // the question isn't part of the golden
                    }
                }
            }
        }
        ScreenSnapshot.check(page, named: "logs-actions", variant: .accessibility)
    }

    @Test("a Share that couldn't write its file")
    internal func exportFailed() async {
        let log = Self.log()
        log.failsExport = true
        let model = LogsModel(log: log, exportDirectory: FileManager.default.temporaryDirectory)
        _ = try? await model.export()
        ScreenSnapshot.check(Self.page(model), named: "logs-export-failed", variant: .light)
    }
}
