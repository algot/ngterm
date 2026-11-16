import Foundation
import NgtermCore
import NgtermCoreFakes
import Testing

@testable import NgtermFeatures

/// The Logs page's model over a log in memory (mobile/android's `LogsViewModelTest`): the newest window, newest first,
/// Copy's lines and its own line, Share's file of its own each time and its failure, and Clear.
@MainActor
@Suite("the Logs page's model")
internal struct LogsModelTests {
    private let directory = FileManager.default.temporaryDirectory.appending(
        path: "LogsModelTests-\(UUID().uuidString)"
    )
    private let log = MemoryAppLog()

    private var exports: URL {
        directory.appending(path: "export")
    }

    private func model() -> LogsModel {
        LogsModel(log: log, exportDirectory: exports)
    }

    private func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("the log reads newest first, Copy takes the same lines oldest first, and the extent says so")
    internal func reads() async {
        defer { remove() }
        log.append(level: .info, tag: "link", message: "connect asked label=build-01")
        log.append(level: .warn, tag: "link", message: "reconnecting delay=4")
        let model = model()
        #expect(model.isReading)
        await model.refresh()
        #expect(!model.isReading)
        #expect(model.lines.map(\.text) == ["reconnecting delay=4", "connect asked label=build-01"])
        #expect(model.lines.first?.level == .warning)
        #expect(model.shown == log.text())
        #expect(model.totalBytes == UInt64(log.text().utf8.count))
        #expect(!model.isCut)
    }

    @Test("a log longer than the page reads is cut to its newest lines, and says so")
    internal func cut() async {
        defer { remove() }
        for index in 0..<(LogsModel.maxLines + 5) {
            log.append(level: .info, tag: "pane", message: "show result=ok n=\(index)")
        }
        let model = model()
        await model.refresh()
        #expect(model.lines.count == LogsModel.maxLines)
        #expect(model.lines.first?.text == "show result=ok n=\(LogsModel.maxLines + 4)")
        #expect(model.isCut)
        #expect(model.shown.split(separator: "\n").count == LogsModel.maxLines)
    }

    @Test("Copy writes its own line, which the page then shows on top")
    internal func copied() async {
        defer { remove() }
        let model = model()
        await model.refresh()
        await model.copied()
        #expect(model.lines.first?.tag == "logs")
        #expect(model.lines.first?.text == "copied the shown lines")
    }

    @Test("each Share writes the whole log to a file of its own, at the same time too, and the next page deletes them")
    internal func export() async throws {
        defer { remove() }
        log.append(level: .info, tag: "app", message: "started version=0.2.5")
        let model = model()
        await model.refresh()
        let first = try await model.export()
        #expect(first.lastPathComponent == LogsModel.exportName)
        let written = try String(contentsOf: first, encoding: .utf8)
        #expect(written.contains("started version=0.2.5"))
        #expect(model.lines.first?.text == "exported bytes=\(written.utf8.count)")
        // the share sheet asks for the file more than once, and at the same time: each ask gets a file of its own
        async let second = model.export()
        async let third = model.export()
        let files = try await [first, second, third]
        #expect(Set(files).count == files.count)
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "a share sheet's file went")
        #expect(!model.exportFailed)
        let next = self.model()
        await next.refresh()
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "an earlier page's export stays")
    }

    @Test("a Share that can't write its file says so until it is dismissed or the log is read again")
    internal func exportFails() async throws {
        defer { remove() }
        log.failsExport = true
        let model = model()
        await #expect(throws: LogError.self) {
            try await model.export()
        }
        #expect(model.exportFailed)
        #expect(model.lines.first?.level == .warning)
        #expect(model.lines.first?.text == "export failed: the file could not be written")
        model.dismissExportFailure()
        #expect(!model.exportFailed)
        await #expect(throws: LogError.self) {
            try await model.export()
        }
        await model.refresh()
        #expect(!model.exportFailed)
    }

    @Test("Clear deletes every line, and the log starts again saying so")
    internal func clear() async {
        defer { remove() }
        log.append(level: .info, tag: "link", message: "machine connected")
        let model = model()
        await model.clear()
        #expect(model.lines.map(\.text) == ["log cleared"])
    }

    @Test("a line in the log's format is cut to its day, time, level, component and text; another keeps it all")
    internal func parse() {
        let line = LogLine(parsing: "2026-11-15T10:11:12.345Z E app: uncaught exception class=NSRangeException")
        #expect(
            line
                == LogLine(
                    day: "2026-11-15",
                    time: "10:11:12",
                    level: .error,
                    tag: "app",
                    text: "uncaught exception class=NSRangeException"
                )
        )
        #expect(LogLine(parsing: "2026-11-15T10:11:12.345Z I nav: settings page=logs").level == .info)
        let loose = LogLine(day: "", time: "", level: .info, tag: "", text: "not a log line")
        #expect(LogLine(parsing: "not a log line") == loose)
        let lines = LogLine.parse("a\n\n  \nb\nc\n", limit: 2)
        #expect(lines.map(\.text) == ["c", "b"])
    }

    @Test("the lines go under their days, newest first; a line with no day stays under the one before")
    internal func days() {
        let lines = [
            LogLine(day: "2026-11-15", time: "10:00:02", level: .info, tag: "a", text: "x"),
            LogLine(day: "", time: "", level: .info, tag: "", text: "loose"),
            LogLine(day: "2026-11-15", time: "10:00:01", level: .info, tag: "a", text: "y"),
            LogLine(day: "2026-11-14", time: "23:59:59", level: .info, tag: "a", text: "z"),
        ]
        let days = LogDay.days(of: lines)
        #expect(days.map(\.day) == ["2026-11-15", "2026-11-14"])
        #expect(days.map { $0.lines.map(\.line.text) } == [["x", "loose", "y"], ["z"]])
        #expect(days.flatMap { $0.lines.map(\.id) } == [0, 1, 2, 3])
        #expect(LogDay.days(of: []).isEmpty)
    }

    @Test("the extent says how many lines of how much, and when cut that Share sends the whole log")
    internal func extent() {
        #expect(LogsWords.extent(count: 1, bytes: 60, isCut: false).hasPrefix("1 line, "))
        #expect(LogsWords.extent(count: 9, bytes: 1_100, isCut: false).hasPrefix("9 lines, "))
        #expect(LogsWords.extent(count: 300, bytes: 900_000, isCut: true).contains("Share sends the whole log"))
        #expect(LogsWords.never.contains("passphrases"))
        #expect(LogsWords.holds.contains("connecting and signing in"))
    }
}
