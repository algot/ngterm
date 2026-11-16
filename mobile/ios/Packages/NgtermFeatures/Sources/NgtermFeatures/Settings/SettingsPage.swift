/// A screen Settings pushes.
internal enum SettingsPage: Hashable {
    /// Importing a key.
    case importKey
    /// The diagnostic log.
    case logs
    /// The public half of the key with this id, and switching the machines to it.
    case publicKey(String)

    /// The page's name in the log: never the key's id.
    internal var logName: String {
        switch self {
        case .importKey:
            "import"

        case .logs:
            "logs"

        case .publicKey:
            "key"
        }
    }
}
