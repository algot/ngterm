import NgtermCoreBindings

/// How the clipboard read described by `facts` is answered (crates/ngterm-mobile, pane/consent.rs's
/// `clipboard_read_consent`): a read that hands over no data never asks, one that would hand over a clip marked
/// sensitive asks for that one read whatever was allowed before, and any other asks unless its program holds a grant
/// or its machine is always allowed.
public func clipboardReadConsent(facts: ClipboardReadFacts) -> ClipboardReadConsent {
    NgtermCoreBindings.clipboardReadConsent(facts: facts)
}
