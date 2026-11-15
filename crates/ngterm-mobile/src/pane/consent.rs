//! Whether a program's clipboard read is answered without asking the user: the one rule both apps follow.
//!
//! A read that hands over no data never asks. A read that would hand over a clip its device marks sensitive (a
//! password manager's, an exported key) always asks, and that answer is for the one read: no standing permission
//! covers it and none comes of it. Any other read is answered unasked under a standing permission (the program's
//! grant in its terminal, the machine's "always allow") and asks without one.

/// What an app knows of a clipboard read when it decides how to answer it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "four independent facts of one read, named at every use"
)]
pub struct ClipboardReadFacts {
    /// The read hands over data: it asks for at least one type and is no listing of the types. Once the clipboard
    /// has been read for it: it holds at least one of them.
    pub discloses: bool,
    /// The program holds a grant in its terminal (the request's `granted`).
    pub granted: bool,
    /// The user lets the machine's programs read the clipboard unasked.
    pub trusted: bool,
    /// The device marks the clip sensitive. False until the clipboard has been read for this read.
    pub sensitive: bool,
}

/// How a clipboard read is answered.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ClipboardReadConsent {
    /// Answer it without asking.
    Unasked,
    /// Ask the user; the answer may become a standing permission.
    Ask,
    /// Ask the user for this one read: offer no standing permission and keep none.
    AskOnce,
}

/// How the read described by `facts` is answered.
#[uniffi::export]
#[must_use]
pub fn clipboard_read_consent(facts: ClipboardReadFacts) -> ClipboardReadConsent {
    if !facts.discloses {
        ClipboardReadConsent::Unasked
    } else if facts.sensitive {
        ClipboardReadConsent::AskOnce
    } else if facts.granted || facts.trusted {
        ClipboardReadConsent::Unasked
    } else {
        ClipboardReadConsent::Ask
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ORDINARY: ClipboardReadFacts = ClipboardReadFacts {
        discloses: true,
        granted: false,
        trusted: false,
        sensitive: false,
    };

    fn standing() -> [ClipboardReadFacts; 4] {
        [(false, false), (true, false), (false, true), (true, true)].map(|(granted, trusted)| ClipboardReadFacts {
            granted,
            trusted,
            ..ORDINARY
        })
    }

    #[test]
    fn a_read_with_no_standing_permission_asks() {
        assert_eq!(clipboard_read_consent(ORDINARY), ClipboardReadConsent::Ask);
    }

    #[test]
    fn a_standing_permission_answers_an_ordinary_clip_unasked() {
        for facts in &standing()[1..] {
            assert_eq!(
                clipboard_read_consent(*facts),
                ClipboardReadConsent::Unasked,
                "{facts:?}"
            );
        }
    }

    #[test]
    fn a_sensitive_clip_asks_for_the_one_read_whatever_the_standing_permission() {
        for facts in standing() {
            let facts = ClipboardReadFacts {
                sensitive: true,
                ..facts
            };
            assert_eq!(
                clipboard_read_consent(facts),
                ClipboardReadConsent::AskOnce,
                "{facts:?}"
            );
        }
    }

    #[test]
    fn a_read_that_hands_over_no_data_never_asks() {
        for facts in standing() {
            for sensitive in [false, true] {
                let facts = ClipboardReadFacts {
                    discloses: false,
                    sensitive,
                    ..facts
                };
                assert_eq!(
                    clipboard_read_consent(facts),
                    ClipboardReadConsent::Unasked,
                    "{facts:?}"
                );
            }
        }
    }
}
