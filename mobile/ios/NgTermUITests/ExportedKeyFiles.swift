import Foundation

/// The files the system's file screen saved a key export to, in the simulator's local file storage.
///
/// The simulator's processes share the host's files, so the storage is found from the test runner's own home.
internal enum ExportedKeyFiles {
    /// The name the real core's export is offered under (`KeyExportFiles.defaultName`).
    internal static let name = "ngterm-private-key"

    private static let opensshMagic = "openssh-key-v1"
    // the length of a string's length in the OpenSSH format
    private static let lengthBytes = 4

    /// The saved files whose name starts with ``name``.
    internal static func saved() -> [URL] {
        let home = NSHomeDirectory()
        guard let containers = home.range(of: "/data/Containers/") else {
            return []
        }
        let groups = URL(filePath: String(home[..<containers.upperBound]) + "Shared/AppGroup")
        let files = FileManager.default
        var found: [URL] = []
        for group in (try? files.contentsOfDirectory(at: groups, includingPropertiesForKeys: nil)) ?? [] {
            let storage = group.appending(path: "File Provider Storage")
            guard let all = files.enumerator(at: storage, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let file as URL in all where file.lastPathComponent.hasPrefix(name) {
                found.append(file)
            }
        }
        return found
    }

    /// Removes every saved file.
    internal static func removeAll() {
        for file in saved() {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// The cipher an OpenSSH private key file's text `file` names (`none` when it is in the clear), or nil when it
    /// isn't one.
    ///
    /// The body is base64 of the format's magic, a NUL, then the cipher's name as a string with a 4-byte length.
    internal static func cipher(of file: String) -> String? {
        let body = file.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: body) else {
            return nil
        }
        let bytes = [UInt8](data)
        let magic = opensshMagic.utf8.count
        let start = magic + 1
        guard bytes.count > start + lengthBytes, String(bytes: bytes[0..<magic], encoding: .utf8) == opensshMagic else {
            return nil
        }
        let length = bytes[start..<start + lengthBytes].reduce(0) { total, byte in total << UInt8.bitWidth | Int(byte) }
        let nameStart = start + lengthBytes
        guard bytes.count >= nameStart + length else {
            return nil
        }
        return String(bytes: bytes[nameStart..<nameStart + length], encoding: .utf8)
    }
}
