#if DEBUG
    import NgtermPlatform

    /// The fake world's network: always online, so the UI tests do not follow the network of the Mac that runs the
    /// simulator.
    ///
    /// The simulator shares the Mac's network. When that network goes for a moment (a CI host lost its path for 2 s),
    /// the app shows its offline banner over the machines and a machine's sessions, and an audit or a tap that occurs
    /// then sees a different screen. The fake core needs no network.
    @MainActor
    internal final class FakeNetwork: PathSource {
        /// The path the source reports: Wi-Fi that can carry traffic.
        internal static let path = NetworkPath(isSatisfied: true, interfaces: ["en0"])

        internal init() {
            // the graph starts it
        }

        internal func start(_ update: @MainActor (NetworkPath) -> Void) {
            update(Self.path)
        }

        internal func stop() {
            // the path never changes: there is nothing to stop
        }

        deinit {
            // nothing to release
        }
    }
#endif
