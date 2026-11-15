import Foundation
import NgtermPlatform
import Testing

/// The file an exported key waits in for the system's file screen: written once, removed however the screen ends.
@Suite("an exported key's staged file")
internal struct KeyExportFilesTests {
    private static let key = Data("-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n".utf8)

    @Test("a staged key is a file of its own under the name it is offered by, and discarding removes it")
    internal func stageThenDiscard() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let files = KeyExportFiles(directory: directory.url)
        let first = try files.stage(Self.key)
        let second = try files.stage(Self.key)
        #expect(first.lastPathComponent == KeyExportFiles.defaultName)
        #expect(first != second)
        #expect(try Data(contentsOf: first) == Self.key)
        files.discard(first)
        #expect(!FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
        #expect(try Data(contentsOf: second) == Self.key)
        #expect(try directory.names().count == 1)
    }

    @Test("a file the system moved away leaves nothing behind once discarded")
    internal func movedAway() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let files = KeyExportFiles(directory: directory.file("staging"), name: "run-key")
        let staged = try files.stage(Self.key)
        #expect(staged.lastPathComponent == "run-key")
        try FileManager.default.moveItem(at: staged, to: directory.file("placed"))
        files.discard(staged)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.file("staging").path).isEmpty)
        #expect(try Data(contentsOf: directory.file("placed")) == Self.key)
    }

    @Test("a file that isn't a staged one is left alone, and discarding all removes every staged file")
    internal func othersStay() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let files = KeyExportFiles(directory: directory.file("staging"))
        let other = directory.file("the user's own")
        try Self.key.write(to: other)
        files.discard(other)
        #expect(FileManager.default.fileExists(atPath: other.path))
        _ = try files.stage(Self.key)
        _ = try files.stage(Self.key)
        files.discardAll()
        #expect(!FileManager.default.fileExists(atPath: directory.file("staging").path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test("a key that can't be staged throws and leaves nothing")
    internal func unwritable() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        // a file where the staging directory should be
        try Data().write(to: directory.file("staging"))
        #expect(throws: (any Error).self) {
            try KeyExportFiles(directory: directory.file("staging")).stage(Self.key)
        }
        #expect(try directory.names() == ["staging"])
    }
}
