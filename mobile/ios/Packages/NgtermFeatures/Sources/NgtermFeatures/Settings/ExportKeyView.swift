import NgtermDesign
import NgtermPlatform
import SwiftUI

/// Exporting a private key for another install, which Import a key reads back (mobile/android's `ExportKeyScreen`).
///
/// It shows only once the device's owner has unlocked (``ExportKeyModel/start(keyId:)``).
/// What the key is and who can use it, the key's fingerprint, the passphrase typed twice (what is wrong with it under
/// the field it is about, once an export was tried), the choice to export without one (confirmed again), Save to a
/// file (the system's screen places the file) and Copy to the clipboard, then how it went.
internal struct ExportKeyView: View {
    @Bindable internal var model: ExportKeyModel
    internal let key: AppKey
    @State private var isPassphraseShown = false
    @State private var isPlacing = false

    internal var body: some View {
        let work = model.work
        // a scroll view, not a Form: every part stays laid out, so each grows with the text size (as the import's)
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xLarge) {
                Banner(
                    .attention,
                    message: String(localized: "This is the key your machines trust"),
                    note: String(
                        localized: """
                            Whoever has the exported key and its passphrase can sign in to them as you. Keep it where \
                            only you can reach it, and delete it once it's imported.
                            """
                    )
                )
                ValuePlate(String(localized: "Key to export"), value: key.fingerprint)
                protection
                actions(work)
                outcome(work)
            }
            .frame(maxWidth: OnboardingLayout.width, alignment: .leading)
            .padding(.horizontal, Spacing.xLarge)
            .padding(.vertical, Spacing.large)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColor: .systemGroupedBackground))
        .disabled(work.isBusy)
        .accessibilityIdentifier("export-key-page")
        .navigationTitle(String(localized: "Export private key"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmingDestructive(
            String(localized: "Export without a passphrase?"),
            isPresented: isConfirming,
            message: String(
                localized: """
                    The exported key won't be encrypted. Anyone who gets the file or reads the clipboard can sign in \
                    to your machines as you.
                    """
            ),
            action: unprotectedAction
        )
        .onChange(of: work.staged) { _, staged in
            isPlacing = staged != nil
        }
        .fileMover(isPresented: $isPlacing, file: work.staged) { result in
            model.placed(result)
        } onCancellation: {
            model.placingCancelled()
        }
    }

    private var isConfirming: Binding<Bool> {
        Binding {
            model.confirming != nil
        } set: { isShown in
            if !isShown {
                model.declineUnprotected()
            }
        }
    }

    // the dialog's own button repeats the switch's words; it keeps the action it was shown for
    private var unprotectedAction: RowAction {
        let action = model.confirming
        return RowAction(String(localized: "Export without a passphrase")) {
            if let action {
                Task {
                    await model.confirmUnprotected(action)
                }
            }
        }
    }

    @ViewBuilder private var protection: some View {
        let problem = model.passphraseProblem
        if !model.draft.isUnprotected {
            VStack(alignment: .leading, spacing: Spacing.small) {
                FormHint(String(localized: "Passphrase"), .header)
                field(String(localized: "Passphrase"), text: $model.draft.passphrase, identifier: "export-passphrase") {
                    Button(isPassphraseShown ? String(localized: "Hide") : String(localized: "Show")) {
                        isPassphraseShown.toggle()
                    }
                    .buttonStyle(.borderless)
                    .frame(minWidth: Spacing.hitTarget, minHeight: Spacing.hitTarget)
                    .accessibilityLabel(
                        isPassphraseShown
                            ? String(localized: "Hide passphrases") : String(localized: "Show passphrases")
                    )
                }
                if case .short = problem, let problem {
                    InlineProblem(problem.message)
                } else {
                    FormHint(
                        String(
                            localized: """
                                At least \(model.passphraseMinimum) characters. It encrypts the exported key, and you \
                                type it again when you import the key.
                                """
                        ),
                        .note
                    )
                }
            }
            VStack(alignment: .leading, spacing: Spacing.small) {
                FormHint(String(localized: "Passphrase again"), .header)
                field(
                    String(localized: "Passphrase again"),
                    text: $model.draft.again,
                    identifier: "export-passphrase-again"
                ) {
                    EmptyView()
                }
                if problem == .differs, let problem {
                    InlineProblem(problem.message)
                }
            }
        }
        VStack(alignment: .leading, spacing: Spacing.small) {
            Toggle(isOn: $model.draft.isUnprotected) {
                VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                    Text("Export without a passphrase")
                    Text("Not recommended")
                        .font(Typography.note)
                        .foregroundStyle(Palette.secondaryText.color)
                }
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.small)
            .frame(minHeight: Spacing.hitTarget)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
            )
            .accessibilityIdentifier("export-unprotected")
            if model.draft.isUnprotected {
                Banner(
                    .failed,
                    message: String(localized: "The exported key won't be encrypted"),
                    note: String(localized: "Whoever reads it signs in to your machines.")
                )
            }
        }
    }

    private func actions(_ work: ExportWork) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            BusyButton(
                title: work.isBusy ? String(localized: "Exporting the key") : String(localized: "Save to a file"),
                isBusy: work.isBusy
            ) {
                tap(.save)
            }
            .accessibilityIdentifier("export-save")
            Button {
                tap(.copy)
            } label: {
                Label(String(localized: "Copy to the clipboard"), systemImage: "doc.on.doc")
                    .font(Typography.detail.weight(.semibold))
                    .frame(minHeight: Spacing.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("export-copy")
            FormHint(
                String(
                    localized: """
                        A file is safer: other apps can read the clipboard. ngterm clears the key from it when you \
                        close this screen, and it never leaves this device.
                        """
                ),
                .note
            )
        }
    }

    @ViewBuilder
    private func outcome(_ work: ExportWork) -> some View {
        if let done = work.done {
            Banner(.online, message: done.words.message, note: done.words.note)
                .accessibilityIdentifier("export-done")
        } else if let problem = work.problem {
            InlineProblem(problem.message)
                .accessibilityIdentifier("export-problem")
        }
    }

    // a passphrase's field on the raised ground, hidden unless Show was tapped, with `trailing` at its end
    private func field<Trailing: View>(
        _ title: String,
        text: Binding<String>,
        identifier: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            Group {
                if isPassphraseShown {
                    TextField(title, text: text)
                } else {
                    SecureField(title, text: text)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.password)
            .frame(minHeight: Spacing.hitTarget)
            .accessibilityIdentifier(identifier)
            trailing()
        }
        .padding(.horizontal, Spacing.medium)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
        )
    }

    private func tap(_ action: ExportAction) {
        Task {
            await model.tap(action)
        }
    }
}
