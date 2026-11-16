import Foundation
import NgtermCore
import Observation

/// The Logs screen over the diagnostic log (mobile/android's `LogsViewModel`).
///
/// It reads the log's newest window (``windowBytes``, at most ``maxLines`` lines) off the main thread. Share writes
/// the whole log as ``exportName`` into a directory of its own under the export directory, each time the share sheet
/// asks (it asks more than once, and at the same time); the page deletes the exports of earlier pages as it opens,
/// never one a share sheet may still read. Clear empties the log. Its own lines go to the same log.
@preconcurrency
@MainActor
@Observable
public final class LogsModel {
    // what one read of the log found
    private struct Read: Sendable {
        let lines: [LogLine]
        let shown: String
        let totalBytes: UInt64
        let isCut: Bool
    }

    /// The most of the log's end the screen reads: 48 KiB.
    nonisolated public static let windowBytes: UInt32 = 49_152
    /// The most lines the screen shows.
    nonisolated public static let maxLines = 300
    /// The exported file's name.
    nonisolated public static let exportName = "ngterm-log.txt"

    /// Whether the log is being read for the first time.
    public private(set) var isReading = true
    /// The newest lines, newest first.
    public private(set) var lines: [LogLine] = []
    /// The same lines as the log wrote them, oldest first: what Copy takes.
    public private(set) var shown = ""
    /// The bytes the whole log holds.
    public private(set) var totalBytes: UInt64 = 0
    /// Whether the log holds more than is shown.
    public private(set) var isCut = false
    /// Whether the last Share couldn't write its file, until the log is read again or it is dismissed.
    public private(set) var exportFailed = false
    @ObservationIgnored private let log: any AppLogProtocol
    @ObservationIgnored private let exportDirectory: URL

    /// The screen over `log`, its exports written under `exportDirectory`.
    public init(log: any AppLogProtocol, exportDirectory: URL) {
        self.log = log
        self.exportDirectory = exportDirectory
    }

    @concurrent
    private static func read(_ source: any AppLogProtocol) async -> Read {
        let tail = source.tail(maxBytes: windowBytes)
        let total = source.size()
        let all = tail.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
        let kept = all.suffix(maxLines).map { "\($0)\n" }.joined()
        let cut = total > UInt64(tail.utf8.count) || all.count > maxLines
        return Read(lines: LogLine.parse(kept, limit: maxLines), shown: kept, totalBytes: total, isCut: cut)
    }

    @concurrent
    private static func write(_ source: any AppLogProtocol, under directory: URL) async throws -> URL {
        let files = FileManager.default
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: exportName, directoryHint: .notDirectory)
        let bytes = try source.export(path: file.path)
        source.append(level: .info, tag: LogTag.logs.rawValue, message: "exported bytes=\(bytes)")
        return file
    }

    @concurrent
    private static func removeExports(under directory: URL) async {
        try? FileManager.default.removeItem(at: directory)
    }

    @concurrent
    private static func clear(_ source: any AppLogProtocol) async {
        source.clear()
    }

    /// Reads the log again; the first time, as the page opens, it deletes the exports of earlier pages too.
    public func refresh() async {
        if isReading {
            await Self.removeExports(under: exportDirectory)
        }
        apply(await Self.read(log))
        exportFailed = false
    }

    /// The shown lines went to the clipboard.
    public func copied() async {
        log.append(level: .info, tag: LogTag.logs.rawValue, message: "copied the shown lines")
        apply(await Self.read(log))
    }

    /// Writes the whole log to a file of its own for the share sheet, and hands back where it is.
    ///
    /// No two shares share a file: an app that got an earlier share never reads a later log.
    public func export() async throws -> URL {
        do {
            let file = try await Self.write(log, under: exportDirectory)
            apply(await Self.read(log))
            exportFailed = false
            return file
        } catch {
            log.append(level: .warn, tag: LogTag.logs.rawValue, message: "export failed: the file could not be written")
            apply(await Self.read(log))
            exportFailed = true
            throw error
        }
    }

    /// The export's failure has been seen.
    public func dismissExportFailure() {
        exportFailed = false
    }

    /// Deletes every line; the log starts again with a line saying so.
    public func clear() async {
        await Self.clear(log)
        apply(await Self.read(log))
    }

    private func apply(_ read: Read) {
        lines = read.lines
        shown = read.shown
        totalBytes = read.totalBytes
        isCut = read.isCut
        isReading = false
    }

    deinit {
        // nothing to release: every read ends with its task
    }
}
