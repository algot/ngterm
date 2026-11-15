#if DEBUG
    import Foundation
    import NgtermCore
    import NgtermCoreFakes
    import NgtermFeatures
    import NgtermPlatform
    import NgtermTerminal
    import UIKit

    /// The world the app sees on the fake core (the UI tests): stores in a directory of the launch's own, keys and
    /// pins in memory, and hosts that ask what the tests walk through.
    ///
    /// - `build-01.lan` offers ``buildHostKey``, which the first connect asks to trust;
    /// - `signin.lan` offers ``signInHostKey`` and asks to sign in as Tailscale SSH does;
    /// - any other host connects at once;
    ///
    /// and, when asked, a program in `docs-site` on `build-01` asks to read the clipboard as the app starts (from a
    /// pasteboard of the launch's own holding a command, so no paste question of iOS's comes up), and one in `notes`
    /// after it: its question shows only once the first is answered; and, when asked, a machine `split`
    /// (`split.lan`) is saved already, with a session `work` of two panes side by side (``FakeSessionWorld``), whose
    /// origin asks a question as it is attached, and whose first pane runs Claude Code (``FakeChatWorld``), each when
    /// asked too, its first Duplicate failing when asked; and, when asked, each Duplicate held until the test's cue
    /// (``FakeCues/Cue/duplicateLands``); and, when asked, a Mac running agterm, `studio` (``FakeAgtermWorld``); and,
    /// when asked, a Mac running agterm beside ngterm, `duo` (``FakeAgtermWorld/seedBeside(_:core:keyId:)``).
    ///
    /// The network is always online (``FakeNetwork``), whatever the simulator's is.
    ///
    /// The device's owner confirms a key's export at once (``FakeDeviceAuth``), unless the launch leaves the device
    /// without a passcode; the exported file is offered under the name the launch gives.
    ///
    /// Notifications go to memory (``FakeNotices``), and the question about notifying counts as asked unless the
    /// launch asks for it. The diagnostic log is the core's own, in the launch's directory or the one it names.
    internal enum FakeWorld {
        /// The host key `build-01.lan` offers (made up).
        internal static let buildHostKey = "SHA256:fAkEbU1Ld01h0sTkEyF0rUiTeStS0nLyN0tArEaLkEy00"
        /// The host key `signin.lan` offers (made up).
        internal static let signInHostKey = "SHA256:fAkEs1GnInh0sTkEyF0rUiTeStS0nLyN0tArEaLkEy000"
        // a key as the first run would leave it (made up: the fake core never loads it)
        private static let key = AppKey(
            id: "fake-key",
            authorizedKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForUiTestsOnlyNotARealKey0000000000"
                + " ngterm@fake",
            fingerprint: "SHA256:q0Gm4d1Xb7pKc2yT9wVZ5eRj8sHnLfA3uMiO6tYvB1E",
            isImported: false
        )

        /// The app's graph over the fake core, as the launch arguments ask.
        ///
        /// The `arguments` are ``CoreChoice``'s: a key already, two programs asking to read the clipboard, `split` with
        /// its session, its question, its agent and its companion, `studio` running agterm, `duo` running both, the
        /// question about notifying left to ask, each Duplicate held until its cue. The scripted steps wait for the
        /// cues that a UI test posts (``FakeCues``).
        @MainActor
        internal static func graph(arguments: [String]) -> AppGraph {
            let cues = FakeCues()
            return graph(arguments: arguments) { await cues.next($0) }
        }

        /// The app's graph over the fake core, as the launch arguments ask.
        ///
        /// Each scripted step that a test looks at first waits for `cue`.
        @MainActor
        internal static func graph(
            arguments: [String],
            cue: @escaping @Sendable (FakeCues.Cue) async -> Void
        ) -> AppGraph {
            let directory = FileManager.default.temporaryDirectory.appending(
                path: "ngterm-fake-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            let pins = MemoryHostKeyPins()
            let core = FakeMobileCore(hosts: pins)
            core.hostKeys = ["build-01.lan": buildHostKey, "signin.lan": signInHostKey]
            core.signIns = ["signin.lan": .tailscale]
            let keys = KeyStore(directory: directory)
            if arguments.contains(CoreChoice.fakeKeyArgument) {
                try? keys.add(key)
            }
            let machines = MachineStore(directory: directory)
            if arguments.contains(CoreChoice.fakeSessionArgument) {
                FakeSessionWorld.seed(
                    machines,
                    core: core,
                    keyId: key.id,
                    asks: arguments.contains(CoreChoice.fakeAskArgument),
                    companion: arguments.contains(CoreChoice.fakeCompanionArgument),
                    chatCue: arguments.contains(CoreChoice.fakeChatArgument) ? cue : nil
                )
                if arguments.contains(CoreChoice.fakeDuplicateFailsArgument) {
                    core.failNext("duplicateSession", with: .Remote(reason: FakeSessionWorld.duplicateRefusal))
                }
            }
            if arguments.contains(CoreChoice.fakeAgtermArgument) {
                FakeAgtermWorld.seed(machines, core: core, keyId: key.id)
            }
            if arguments.contains(CoreChoice.fakeAgtermNotLiveArgument) {
                FakeAgtermWorld.seedNotLive(machines, core: core, keyId: key.id)
            }
            if arguments.contains(CoreChoice.fakeAgtermBesideArgument) {
                FakeAgtermWorld.seedBeside(machines, core: core, keyId: key.id)
            }
            if arguments.contains(CoreChoice.fakeDuplicateSlowArgument) {
                holdDuplicates(core, cue: cue)
            }
            let stores = GraphStores(directory: directory)
            if !arguments.contains(CoreChoice.fakeNotificationQuestionArgument) {
                try? stores.notificationPrefs.markPermissionAsked()
            }
            let logs = logDirectory(arguments: arguments) ?? directory
            let graph = AppGraph(
                machines: machines,
                settings: SettingsStore(directory: directory),
                keys: AppKeys(store: keys, vault: MemoryPrivateKeys(), maker: CoreKeyMaker(), comment: "ngterm@fake"),
                pins: pins,
                stores: stores,
                core: core,
                notices: FakeNotices(),
                pathSource: FakeNetwork(),
                clipboard: clipboard(arguments: arguments),
                exports: exports(arguments: arguments),
                log: AppLogs.open(in: logs.appending(path: "log", directoryHint: .isDirectory)),
                logExports: logs.appending(path: "export", directoryHint: .isDirectory)
            )
            if arguments.contains(CoreChoice.fakeClipboardReadArgument) {
                let pane = PaneRef(machineId: "build-01", sessionId: "docs-site", paneId: "P1")
                core.emit(read(pane: pane, canRemember: true))
                // another pane's first read, shown once the first is answered, so a test sees that it was
                let next = PaneRef(machineId: "build-01", sessionId: "notes", paneId: "P2")
                core.emit(read(pane: next, canRemember: false))
            }
            return graph
        }

        // the directory the launch asks the log to be kept in, if any
        private static func logDirectory(arguments: [String]) -> URL? {
            guard let flag = arguments.firstIndex(of: CoreChoice.fakeLogArgument), arguments.indices.contains(flag + 1)
            else {
                return nil
            }
            return URL(filePath: arguments[flag + 1], directoryHint: .isDirectory)
        }

        // holds each Duplicate under way until the cue `duplicateLands` comes, so a test sees what shows meanwhile: the
        // source's "Duplicating", and New session and every Duplicate taking no tap. A clock would let a slow simulator
        // end the hold before the test looks. The first hold is in place at launch.
        @MainActor
        private static func holdDuplicates(
            _ core: FakeMobileCore,
            cue: @escaping @Sendable (FakeCues.Cue) async -> Void
        ) {
            let first = core.hold("duplicateSession")
            Task {
                var gate = first
                while !Task.isCancelled {
                    await gate.reached()
                    await cue(.duplicateLands)
                    gate.open()
                    gate = core.hold("duplicateSession")
                }
            }
        }

        // a device whose owner confirms at once (or one with no passcode, when asked), the general pasteboard, and
        // the exported file under the name the launch gives, if it gives one
        @MainActor
        private static func exports(arguments: [String]) -> KeyExportServices {
            let named = arguments.firstIndex(of: CoreChoice.fakeExportNameArgument).map { $0 + 1 }
            let name = named.flatMap { arguments.indices.contains($0) ? arguments[$0] : nil }
            return KeyExportServices(
                auth: FakeDeviceAuth(isSecured: !arguments.contains(CoreChoice.fakeNoPasscodeArgument)),
                clipboard: SystemKeyClipboard(),
                files: KeyExportFiles(name: name ?? KeyExportFiles.defaultName)
            )
        }

        // a pasteboard of the launch's own holding a command, when programs ask to read the clipboard; else none
        @MainActor
        private static func clipboard(arguments: [String]) -> (any TerminalClipboard)? {
            guard arguments.contains(CoreChoice.fakeClipboardReadArgument),
                let pasteboard = UIPasteboard(name: UIPasteboard.Name("ngterm-fake-\(UUID().uuidString)"), create: true)
            else {
                return nil
            }
            if arguments.contains(CoreChoice.fakeClipboardSensitiveArgument) {
                let marked: [String: Any] = [
                    "public.utf8-plain-text": "npm run deploy -- --prod",
                    SystemClipboard.concealedType: Data(),
                ]
                pasteboard.setItems([marked])
            } else {
                pasteboard.string = "npm run deploy -- --prod"
            }
            return SystemClipboard(pasteboard)
        }

        // a program's read of the clipboard's text
        private static func read(pane: PaneRef, canRemember: Bool) -> MobileEvent {
            .clipboardReadRequest(
                pane: pane,
                readId: 1,
                clipboard: .standard,
                listOnly: false,
                mimes: ["text/plain"],
                list: false,
                granted: false,
                canRemember: canRemember
            )
        }
    }
#endif
