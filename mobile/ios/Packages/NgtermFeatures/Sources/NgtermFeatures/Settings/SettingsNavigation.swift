import Observation

/// Settings' stack of pages, which tells the log each page it shows as it is set, before the page appears: a page
/// that reads the log (Logs) finds its own line there.
@preconcurrency
@MainActor
@Observable
internal final class SettingsNavigation {
    /// The pages pushed over Settings' form.
    internal var path: [SettingsPage] = [] {
        didSet {
            note()
        }
    }
    @ObservationIgnored private let diagnostics: Diagnostics
    // the page the log was last told
    @ObservationIgnored private var noted: String?

    /// A stack over the form, telling `diagnostics`.
    internal init(diagnostics: Diagnostics) {
        self.diagnostics = diagnostics
    }

    /// Settings came up on its form, or a page.
    internal func shown() {
        noted = nil
        note()
    }

    private func note() {
        let page = path.last?.logName ?? "home"
        guard page != noted else {
            return
        }
        noted = page
        diagnostics.info(.nav, "settings page=\(page)")
    }

    deinit {
        // nothing to release
    }
}
