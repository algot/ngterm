import SwiftUI

/// Why Export private key didn't open the export, as the system's alert: a device with no passcode is told to set
/// one; one that couldn't confirm its owner says why and offers Try again, calling `onUnlocked` once it has.
internal struct ExportNotices: ViewModifier {
    internal let model: ExportKeyModel
    internal let onUnlocked: @MainActor () -> Void

    private var isShown: Binding<Bool> {
        Binding {
            model.notice != nil
        } set: { isShown in
            if !isShown {
                model.dismissNotice()
            }
        }
    }

    internal func body(content: Content) -> some View {
        content.alert(model.notice?.title ?? "", isPresented: isShown, presenting: model.notice) { notice in
            switch notice {
            case .noPasscode:
                Button(String(localized: "OK"), role: .cancel) {
                    model.dismissNotice()
                }

            case .authFailed:
                Button(String(localized: "Try again")) {
                    Task {
                        await model.retry()
                        onUnlocked()
                    }
                }
                Button(String(localized: "Cancel"), role: .cancel) {
                    model.dismissNotice()
                }
            }
        } message: { notice in
            Text(notice.message)
        }
    }
}
