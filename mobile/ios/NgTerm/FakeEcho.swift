#if DEBUG
    import Foundation
    import NgtermCore
    import NgtermCoreFakes
    import Synchronization

    /// A fake pane's screen as a shell keeps it, for the session view's UI tests (``FakeSessionWorld``).
    ///
    /// Its first line names the pane ("P1 ready"), its second shows what it was typed after the prompt ("$ ls"), so a
    /// test sees which pane took the typing. Each input tells the app the pane changed, as the shell's echo would.
    internal final class FakeEcho: Sendable {
        nonisolated private static let columns = 40
        nonisolated private static let rows = 12

        private let ref: PaneRef
        private weak let core: FakeMobileCore?
        private let typed = Mutex("")

        /// The screen of the pane `ref`, whose input `core` reports.
        internal init(_ ref: PaneRef, core: FakeMobileCore?) {
            self.ref = ref
            self.core = core
        }

        /// The screen's bytes for the frame after `since`.
        internal func frames(since: UInt64) -> Data {
            RowBufferWriter(columns: Self.columns, rows: Self.rows, seq: since + 1)
                .text(0, "\(ref.paneId) ready")
                .text(1, "$ " + typed.withLock { $0 })
                .bytes()
        }

        /// Keeps typed text for the screen and reports that the pane changed.
        internal func take(_ input: FakeInput) {
            if case .typed(let text) = input {
                typed.withLock { $0 += text }
            }
            core?.emit(.paneDirty(pane: ref))
        }

        deinit {
            // nothing to release
        }
    }
#endif
