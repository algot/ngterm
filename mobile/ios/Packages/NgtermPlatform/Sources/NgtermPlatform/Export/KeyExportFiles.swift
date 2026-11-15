import Foundation

/// The file an exported key waits in while the system's screen asks where it goes.
///
/// iOS moves a file, not bytes, so the export is written once into a directory of its own under the app's temporary
/// directory, protected while the device is locked; the system then moves it to the place the user picks, and
/// ``discard(_:)`` removes what is left. ``discardAll()`` removes everything an earlier run left behind.
public struct KeyExportFiles: Sendable {
    /// The name the exported file is offered under.
    public static let defaultName = "ngterm-private-key"

    private let directory: URL
    private let name: String

    /// The files under `directory` (the app's temporary directory unless a test gives its own), each named `name`.
    public init(directory: URL? = nil, name: String = Self.defaultName) {
        self.directory =
            directory
            ?? FileManager.default.temporaryDirectory.appending(path: "key-export", directoryHint: .isDirectory)
        self.name = name
    }

    /// Writes `key` into a new file of its own and says where it is.
    ///
    /// - Throws: the file system's error; nothing is left behind then.
    public func stage(_ key: Data) throws -> URL {
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name, directoryHint: .notDirectory)
        do {
            try key.write(to: file, options: [.completeFileProtection, .withoutOverwriting])
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return file
    }

    /// Removes the staged `file` and its directory, whether the system moved the file away or not; a file that isn't
    /// one of these is left alone.
    public func discard(_ file: URL) {
        let folder = file.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path else {
            return
        }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes every staged file.
    public func discardAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
