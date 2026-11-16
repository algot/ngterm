import Foundation
import NgtermCore
import NgtermCoreFakes
import Testing

@Suite("the diagnostic log")
internal struct CoreLogTests {
    @Test("the core's log keeps the app's lines in a directory out of backups, and writes them out to share")
    internal func opens() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "CoreLogTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = CoreLog.open(directory: directory)
        let marker = "marker-\(UUID().uuidString.prefix(8))"
        log.append(level: .warn, tag: "test", message: marker)
        #expect(log.tail(maxBytes: 4_096).contains(" W test: \(marker)"))
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let file = directory.appending(path: "shared.txt")
        let bytes = try log.export(path: file.path)
        #expect(bytes == UInt64(try Data(contentsOf: file).count))
        #expect(log.size() > 0)
    }

    @Test("the log in memory writes as the core does, keeps its rules, and clears")
    internal func memory() throws {
        let log = MemoryAppLog { Date(timeIntervalSince1970: 1_763_201_472.5) }
        log.append(level: .error, tag: "bad tag!", message: "two\nlines")
        #expect(log.lines == ["2025-11-15T10:11:12.500Z E app: two lines"])
        log.append(level: .info, tag: "chat-ui", message: String(repeating: "x", count: 400))
        #expect(log.lines.last?.hasSuffix(String(repeating: "x", count: 300)) == true)
        #expect(log.tail(maxBytes: 60).isEmpty)
        #expect(log.tail(maxBytes: 4_096) == log.text())
        log.failsExport = true
        #expect(throws: LogError.self) {
            try log.export(path: "/nowhere")
        }
        log.clear()
        #expect(log.lines == ["2025-11-15T10:11:12.500Z I log: log cleared"])
    }
}
