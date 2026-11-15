/// A screen Settings pushes.
internal enum SettingsPage: Hashable {
    /// Exporting the private half of the key with this id, once its owner has unlocked it.
    case exportKey(String)
    /// Importing a key.
    case importKey
    /// The diagnostic log.
    case logs
    /// The public half of the key with this id, and switching the machines to it.
    case publicKey(String)

    /// The page's name in the log: never the key's id.
    internal var logName: String {
        switch self {
        case .exportKey:
            "export"

        case .importKey:
            "import"

        case .logs:
            "logs"

        case .publicKey:
            "key"
        }
    }

    /// Whether it is a key's export.
    internal var isExport: Bool {
        if case .exportKey = self {
            return true
        }
        return false
    }
}
