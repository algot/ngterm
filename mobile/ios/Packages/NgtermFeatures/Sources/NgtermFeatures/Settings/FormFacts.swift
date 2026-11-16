import NgtermPlatform

/// What Settings' form shows that can change while a page covers it: the keys and the work on them, the machines
/// trusted with the clipboard, and whether the app may notify.
///
/// Settings keeps a copy of these while a pushed page takes its form out of the window, and lets go of it as the form
/// joins the window again (``WindowPresence``). A `Form` changed out of the window comes back with rows of a stale
/// height. On an iPad with a keyboard, UIKit's focus search after Back then measures those rows, lays the list out
/// again in the middle of the search and removes the focus guide that it reads: the app ends with
/// "parentEnvironment != nil". A form that changes only in a window keeps its rows' heights in step.
internal struct FormFacts {
    /// The app's keys, with the machines that use each.
    internal let keys: [KeyItem]
    /// Where making or bringing a key stands.
    internal let work: KeyWork
    /// The machines whose programs read the clipboard unasked.
    internal let trusted: [TrustedMachine]
    /// Whether the app may notify, as last read.
    internal let permission: NoticePermission?

    /// The facts as `model` has them now.
    @MainActor
    internal init(_ model: SettingsModel) {
        keys = model.keys
        work = model.work
        trusted = model.trusted
        permission = model.permission
    }
}
