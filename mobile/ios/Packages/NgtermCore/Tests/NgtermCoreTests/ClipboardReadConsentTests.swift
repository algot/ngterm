import NgtermCore
import Testing

/// How a clipboard read is answered, as the linked core says (pane/consent.rs's `clipboard_read_consent`).
@Suite("the consent a clipboard read needs")
internal struct ClipboardReadConsentTests {
    private func consent(
        discloses: Bool = true,
        granted: Bool = false,
        trusted: Bool = false,
        sensitive: Bool = false
    ) -> ClipboardReadConsent {
        clipboardReadConsent(
            facts: ClipboardReadFacts(discloses: discloses, granted: granted, trusted: trusted, sensitive: sensitive)
        )
    }

    @Test("an ordinary clip asks, unless the program holds a grant or the machine is always allowed")
    internal func ordinary() {
        #expect(consent() == .ask)
        #expect(consent(granted: true) == .unasked)
        #expect(consent(trusted: true) == .unasked)
    }

    @Test("a sensitive clip asks for the one read, whatever was allowed before")
    internal func sensitive() {
        #expect(consent(sensitive: true) == .askOnce)
        #expect(consent(granted: true, sensitive: true) == .askOnce)
        #expect(consent(trusted: true, sensitive: true) == .askOnce)
    }

    @Test("a read that hands over no data never asks")
    internal func nothingDisclosed() {
        #expect(consent(discloses: false) == .unasked)
        #expect(consent(discloses: false, sensitive: true) == .unasked)
    }
}
