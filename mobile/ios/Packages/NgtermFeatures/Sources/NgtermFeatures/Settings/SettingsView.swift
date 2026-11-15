import NgtermDesign
import SwiftUI

/// Settings (mobile/android's `SettingsRoute`), a sheet with a `Form`: the terminal (a live sample over its text size,
/// font and colors, and keeping the screen on), the appearance, the extra keys, the agents' chat view, the
/// notifications, the machines trusted with the clipboard, the keys, and the loaded core's version; Done closes it.
///
/// It pushes a key's public half (with Use for every machine under it), the import, and, once the device's owner has
/// unlocked it, a key's export, which locks again however its screen is left. A key just made or brought
/// opens its public half in place of where Settings was. Whether the app may notify is read again each time the app
/// comes back to the foreground, so a change in the system's settings shows. A change the stores couldn't keep shows
/// as a banner at the sheet's foot until it is dismissed.
public struct SettingsView: View {
    @Environment(\.dismiss)
    private var dismiss
    @Environment(\.scenePhase)
    private var scenePhase

    private let coreVersion: String
    @State private var model: SettingsModel
    @State private var navigation: SettingsNavigation

    /// The body of the view.
    public var body: some View {
        NavigationStack(path: pages) {
            Form {
                TerminalSection(model: model)
                ChoiceSections(model: model)
                AgentsSection(model: model)
                NotificationsSection(model: model)
                ClipboardSection(model: model)
                KeysSection(model: model) { keyId in
                    navigation.path.append(.publicKey(keyId))
                } onExport: { keyId in
                    Task {
                        await model.export.start(keyId: keyId)
                        showExport()
                    }
                } onImport: {
                    model.startImport()
                    navigation.path.append(.importKey)
                }
                if model.hasLog {
                    DiagnosticsSection()
                }
                AboutSection(coreVersion: coreVersion)
            }
            .accessibilityIdentifier("settings-form")
            .modifier(ExportNotices(model: model.export, onUnlocked: showExport))
            .navigationTitle(String(localized: "Settings"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("settings-done")
                }
            }
            .navigationDestination(for: SettingsPage.self) { page in
                destination(page)
            }
        }
        .ngtermTheme()
        .safeAreaInset(edge: .bottom) {
            if let failure = model.failure {
                Banner(.failed, message: failure) {
                    model.dismissFailure()
                }
                .padding(Spacing.large)
            }
        }
        .onAppear {
            navigation.shown()
        }
        .task {
            await model.readPermission()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await model.readPermission()
                }
            }
        }
        .onDisappear {
            model.export.close()
        }
        .onChange(of: model.newKey) { _, keyId in
            if let keyId {
                navigation.path = [.publicKey(keyId)]
                model.newKeyShown()
            }
        }
    }

    // the pushed pages, as the stack changes them: leaving the export locks it
    private var pages: Binding<[SettingsPage]> {
        Binding {
            navigation.path
        } set: { pages in
            navigation.path = pages
            if !pages.contains(where: \.isExport) {
                model.export.close()
            }
        }
    }

    // the import over Settings' model
    private var importWork: ImportKeyWork {
        let settings = model
        return ImportKeyWork {
            (settings.work.isImporting, settings.work.importProblem)
        } importKey: { bytes, passphrase in
            await settings.importKey(privateKey: &bytes, passphrase: passphrase)
        } unreadable: {
            settings.unreadable()
        }
    }

    /// Settings over `graph`, saying `coreVersion` is the loaded core's.
    public init(graph: AppGraph, coreVersion: String) {
        self.init(model: SettingsModel(graph: graph), coreVersion: coreVersion)
    }

    /// Settings over `model` (a test's, read ahead), saying `coreVersion` is the loaded core's.
    internal init(model: SettingsModel, coreVersion: String) {
        self.coreVersion = coreVersion
        _model = State(initialValue: model)
        _navigation = State(initialValue: SettingsNavigation(diagnostics: model.diagnostics))
    }

    // pushes the export once its owner has unlocked a key
    private func showExport() {
        if let keyId = model.export.work.keyId, !navigation.path.contains(where: \.isExport) {
            navigation.path.append(.exportKey(keyId))
        }
    }

    @ViewBuilder
    private func destination(_ page: SettingsPage) -> some View {
        switch page {
        case .importKey:
            ImportKeyView(work: importWork)

        case .exportKey(let keyId):
            if let item = model.keys.first(where: { $0.id == keyId }), model.export.work.keyId == keyId {
                ExportKeyView(model: model.export, key: item.key)
            } else {
                // the key is locked again, or gone: there is nothing to show
                Color(uiColor: .systemGroupedBackground)
            }

        case .publicKey(let keyId):
            if let item = model.keys.first(where: { $0.id == keyId }) {
                PublicKeyView(key: item.key) {
                    SwitchMachines(item: item) {
                        model.useEverywhere(keyId)
                    }
                }
            } else {
                // the key is gone: there is nothing to show
                Color(uiColor: .systemGroupedBackground)
            }

        case .logs:
            if let logs = model.makeLogs() {
                LogsView(model: logs)
            }
        }
    }
}
