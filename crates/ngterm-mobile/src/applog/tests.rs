//! The log's own tests: its files (the line format, rotation and its bound, a restart, the newest window, export and
//! clear, a directory that can't be written), what the subscriber writes of an event's fields, and what
//! [`LoggedSink`] keeps of each event. [`Captured`] is the log the other modules' tests drive their paths under.

use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, UNIX_EPOCH};

use tempfile::TempDir;
use tracing::Dispatch;
use tracing::subscriber::NoSubscriber;

use super::{
    AppLog, FILE_NAME, LogLevel, LoggedSink, MESSAGE_CAP, REDACTED, ROTATED_NAME, VALUE_CAP, is_class, stamp, tag,
    variant,
};
use crate::api::{EventSink, MachineState, MobileEvent};
use crate::chat::{ChatBody, ChatEvent, ChatState};
use crate::note;
use crate::pane::{ClipboardPart, PaneEnd, PaneRef, PaneRole};
use crate::presentation::{RemoteNotice, StreamState};
use crate::sessions::RemoteSession;

/// What a test puts wherever private text could be: typed text, output, a body, a key, a failure's wording. No line
/// of the log may hold it.
pub(crate) const MARKER: &str = "s3cret-MARKER";

/// A log in a scratch directory, for a test to run the core under.
pub(crate) struct Captured {
    dir: TempDir,
    pub(crate) log: Arc<AppLog>,
}

impl Captured {
    pub(crate) fn new() -> Self {
        // While `tracing` knows one dispatcher alone, it decides whether a call site is of interest by the thread
        // that reaches it first: another test's thread, with no log, would switch the site off for this test's. A
        // second dispatcher, kept for the whole run, makes it ask each thread's own every time.
        static SECOND: OnceLock<Dispatch> = OnceLock::new();
        SECOND.get_or_init(|| Dispatch::new(NoSubscriber::new()));
        let dir = TempDir::new().unwrap();
        let log = AppLog::open(dir.path().to_string_lossy().into_owned());
        Self { dir, log }
    }

    /// Runs `body` with the core's lines of this thread, and of the actors it starts, going to the log.
    pub(crate) fn run<R>(&self, body: impl FnOnce() -> R) -> R {
        tracing::dispatcher::with_default(&self.log.dispatch(), body)
    }

    pub(crate) fn text(&self) -> String {
        self.log.text()
    }

    /// The log's text, once it holds `wanted`: a line the actor writes after it answered a call.
    pub(crate) fn text_with(&self, wanted: &str) -> String {
        for _ in 0..500 {
            let text = self.text();
            if text.contains(wanted) {
                return text;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("the log never held {wanted:?}:\n{}", self.text());
    }

    /// Fails when the log holds [`MARKER`].
    pub(crate) fn assert_clean(&self) {
        let text = self.text();
        assert!(!text.contains(MARKER), "the log holds private text:\n{text}");
    }
}

fn lines(text: &str) -> Vec<&str> {
    text.lines().collect()
}

#[test]
fn a_line_carries_a_utc_timestamp_its_level_and_its_tag() {
    let captured = Captured::new();
    captured
        .log
        .append(LogLevel::Warn, "nav".to_owned(), "opened Settings".to_owned());

    let text = captured.text();
    let line = lines(&text)[0];
    let (time, rest) = line.split_once(' ').unwrap();
    assert_eq!(rest, "W nav: opened Settings");
    assert_eq!(time.len(), "2026-11-15T10:11:12.345Z".len(), "{time}");
    assert!(time.ends_with('Z') && time.as_bytes()[10] == b'T', "{time}");

    let mut leap_day = String::new();
    stamp(&mut leap_day, UNIX_EPOCH + Duration::from_millis(951_827_696_789));
    assert_eq!(leap_day, "2000-02-29T12:34:56.789Z");
    let mut epoch = String::new();
    stamp(&mut epoch, UNIX_EPOCH);
    assert_eq!(epoch, "1970-01-01T00:00:00.000Z");
    let mut today = String::new();
    stamp(&mut today, UNIX_EPOCH + Duration::from_hours(498_528));
    assert_eq!(today, "2026-11-15T00:00:00.000Z");
}

#[test]
fn the_log_rotates_at_its_cap_and_never_holds_more_than_twice_it() {
    let dir = TempDir::new().unwrap();
    let cap = 2000;
    let log = AppLog::with_cap(dir.path(), cap);
    for number in 0..500 {
        log.append(LogLevel::Info, "t".to_owned(), format!("line {number:04}"));
        assert!(log.size() <= cap * 2, "{} bytes after line {number}", log.size());
    }

    let current = std::fs::metadata(dir.path().join(FILE_NAME)).unwrap().len();
    let rotated = std::fs::metadata(dir.path().join(ROTATED_NAME)).unwrap().len();
    assert!(current <= cap && rotated <= cap, "{current} and {rotated}");
    let text = log.text();
    let kept = lines(&text);
    assert!(kept.last().unwrap().ends_with("line 0499"), "the newest line is kept");
    assert!(!text.contains("line 0000"), "the oldest lines are gone");
    let numbers: Vec<&str> = kept.iter().map(|line| &line[line.len() - 4..]).collect();
    assert!(
        numbers.windows(2).all(|pair| pair[0] < pair[1]),
        "oldest first, across the rotated file and the current one"
    );
}

#[test]
fn the_log_survives_a_restart_and_goes_on_in_the_same_files() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().to_string_lossy().into_owned();
    let before = AppLog::open(path.clone());
    before.append(LogLevel::Info, "app".to_owned(), "before the restart".to_owned());
    drop(before);

    let after = AppLog::open(path);
    assert!(after.text().ends_with("I app: before the restart\n"));
    after.append(LogLevel::Error, "app".to_owned(), "after the restart".to_owned());

    let text = after.text();
    let kept = lines(&text);
    assert_eq!(kept.len(), 2);
    assert!(kept[0].ends_with("before the restart") && kept[1].ends_with("E app: after the restart"));
}

#[test]
fn a_restart_keeps_counting_toward_the_cap() {
    let dir = TempDir::new().unwrap();
    let cap = 300;
    for number in 0..40 {
        // a fresh log each time, as every start of the app opens one
        let log = AppLog::with_cap(dir.path(), cap);
        log.append(LogLevel::Info, "t".to_owned(), format!("start {number:02}"));
        assert!(log.size() <= cap * 2);
    }
    assert!(
        dir.path().join(ROTATED_NAME).exists(),
        "the files rotated across the restarts"
    );
}

#[test]
fn the_tail_is_the_newest_window_and_starts_at_a_line() {
    let captured = Captured::new();
    for number in 0..50 {
        captured
            .log
            .append(LogLevel::Info, "t".to_owned(), format!("линия {number:02}"));
    }

    let tail = captured.log.tail(200);
    assert!(tail.len() <= 200 && !tail.is_empty());
    assert!(tail.ends_with("линия 49\n"));
    for line in tail.lines() {
        assert!(
            line.starts_with("20") && line.contains(" I t: линия "),
            "a whole line: {line:?}"
        );
    }
    assert_eq!(
        captured.log.tail(1_000_000),
        captured.text(),
        "a window past the log is all of it"
    );
    assert_eq!(captured.log.tail(0), "");
}

#[test]
fn the_tail_reaches_into_the_rotated_file() {
    let dir = TempDir::new().unwrap();
    let log = AppLog::with_cap(dir.path(), 400);
    for number in 0..12 {
        log.append(LogLevel::Info, "t".to_owned(), format!("line {number:02}"));
    }
    let current = std::fs::read_to_string(dir.path().join(FILE_NAME)).unwrap();
    let window = u32::try_from(current.len()).unwrap() + 100;

    let tail = log.tail(window);

    assert!(tail.ends_with(&current) && tail.len() > current.len(), "{tail:?}");
    assert!(tail.lines().all(|line| line.starts_with("20")));
}

#[test]
fn export_writes_the_whole_log_and_clear_empties_it() {
    let captured = Captured::new();
    captured.log.append(LogLevel::Info, "app".to_owned(), "one".to_owned());
    captured.log.append(LogLevel::Info, "app".to_owned(), "two".to_owned());
    let target = captured.dir.path().join("export").join("ngterm-log.txt");
    std::fs::create_dir_all(target.parent().unwrap()).unwrap();

    let written = captured.log.export(target.to_string_lossy().into_owned()).unwrap();

    let exported = std::fs::read_to_string(&target).unwrap();
    assert_eq!(exported, captured.text());
    assert_eq!(written, exported.len() as u64);
    assert!(
        captured
            .log
            .export(
                captured
                    .dir
                    .path()
                    .join("none/there.txt")
                    .to_string_lossy()
                    .into_owned()
            )
            .is_err(),
        "a file that can't be written is an error"
    );

    captured.log.clear();
    let text = captured.text();
    assert_eq!(lines(&text).len(), 1, "{text}");
    assert!(text.ends_with("I log: log cleared\n"));
}

#[test]
fn an_apps_line_is_one_line_cut_at_the_cap_under_a_plain_tag() {
    let captured = Captured::new();
    captured
        .log
        .append(LogLevel::Info, "bad tag!".to_owned(), "first\nsecond\tthird".to_owned());
    captured
        .log
        .append(LogLevel::Info, String::new(), "x".repeat(MESSAGE_CAP * 2));

    let text = captured.text();
    let kept = lines(&text);
    assert_eq!(kept.len(), 2);
    assert!(kept[0].ends_with("I app: first second third"), "{}", kept[0]);
    assert!(kept[1].ends_with(&format!("I app: {}", "x".repeat(MESSAGE_CAP))));
}

#[test]
fn a_log_that_cannot_be_written_drops_its_lines() {
    let dir = TempDir::new().unwrap();
    let file = dir.path().join("a-file");
    std::fs::write(&file, "x").unwrap();
    let log = AppLog::open(file.join("under-a-file").to_string_lossy().into_owned());

    log.append(LogLevel::Info, "app".to_owned(), "lost".to_owned());
    log.clear();

    assert_eq!(log.text(), "");
    assert_eq!(log.size(), 0);
}

#[test]
fn a_class_is_a_short_run_of_plain_characters() {
    for class in [
        "ok",
        "not-on-screen",
        "ssh-ed25519",
        "00000000-0000-0000-0000-0000000000A1",
        "a.b:c+d@e/f_g",
    ] {
        assert!(is_class(class), "{class}");
    }
    for other in ["", "two words", "naïve", "tab\there", &"x".repeat(VALUE_CAP + 1)] {
        assert!(!is_class(other), "{other}");
    }
    assert_eq!(variant(&std::io::ErrorKind::ConnectionRefused), "ConnectionRefused");
    assert_eq!(variant(&Some(MARKER)), "Some", "what a value carries is left out");
}

#[test]
fn the_subscriber_writes_classes_numbers_and_identity_and_redacts_the_rest() {
    let captured = Captured::new();
    let sentence = format!("typed {MARKER} text");
    let long_label = format!("My Box {}", "é".repeat(VALUE_CAP));
    captured.run(|| {
        note!(
            WARN,
            tag::SSH,
            "connect failed",
            machine = "m1",
            class = "refused",
            label = long_label.as_str(),
            host = "box.example",
            port = 22_u16,
            covered = true,
            code = Some(7_u64),
            signal = None::<&str>,
            why = sentence.as_str()
        );
        // values formatted by their type, and a line whose text is built from data, are never written
        tracing::warn!(target: tag::PANE, shown = %sentence, debugged = ?sentence, "typed {sentence}");
        // below the log's level, and other crates' events
        tracing::debug!(target: tag::PANE, what = "noise");
        tracing::error!(target: "russh::client", what = "theirs");
        tracing::error!(target: "ngterm_mobile_other", what = "not ours either");
    });

    let text = captured.text();
    let kept = lines(&text);
    assert_eq!(kept.len(), 2, "{text}");
    let expected = format!(
        "W ssh: connect failed machine=m1 class=refused label=My Box {} host=box.example port=22 covered=true \
         code=7 why={REDACTED}",
        "é".repeat(VALUE_CAP - "My Box ".len())
    );
    assert!(kept[0].ends_with(&expected), "{}", kept[0]);
    assert!(
        kept[1].ends_with(&format!(
            "W pane:  message={REDACTED} shown={REDACTED} debugged={REDACTED}"
        )),
        "{}",
        kept[1]
    );
    captured.assert_clean();
}

/// A sink that keeps what it was handed.
#[derive(Default)]
struct Kept(Mutex<Vec<MobileEvent>>);

impl EventSink for Kept {
    fn on_event(&self, event: MobileEvent) {
        self.0.lock().unwrap().push(event);
    }
}

fn pane() -> PaneRef {
    PaneRef {
        machine_id: "m1".to_owned(),
        session_id: "S1".to_owned(),
        pane_id: "P1".to_owned(),
    }
}

fn session(private: &str) -> RemoteSession {
    RemoteSession {
        id: "S1".to_owned(),
        name: private.to_owned(),
        window_name: private.to_owned(),
        workspace_name: private.to_owned(),
        context: Some(private.to_owned()),
        cwd: private.to_owned(),
        status: Some(private.to_owned()),
        status_color: None,
        status_shape: None,
        parent: None,
        pane_count: 1,
        split_axis: None,
        peer: None,
    }
}

fn private() -> String {
    format!("private {MARKER}")
}

fn machine_id() -> String {
    "m1".to_owned()
}

fn session_id() -> String {
    "S1".to_owned()
}

/// Events with [`MARKER`] in every payload the log must not keep.
fn private_events() -> Vec<MobileEvent> {
    let mut events = machine_events();
    events.extend(pane_events());
    events
}

fn machine_events() -> Vec<MobileEvent> {
    vec![
        MobileEvent::MachineState {
            machine_id: machine_id(),
            state: MachineState::Unreachable { reason: private() },
        },
        MobileEvent::HostKeyUnknown {
            machine_id: machine_id(),
            fingerprint: format!("SHA256:{MARKER}"),
        },
        MobileEvent::HostKeyChanged {
            machine_id: machine_id(),
            pinned: format!("SHA256:{MARKER}"),
            offered: format!("SHA256:{MARKER}"),
        },
        MobileEvent::SignInRequested {
            machine_id: machine_id(),
            message: private(),
            url: format!("https://example.com/{MARKER}"),
        },
        MobileEvent::Tree {
            machine_id: machine_id(),
            sessions: vec![session(&private())],
        },
        MobileEvent::SessionConnection {
            machine_id: machine_id(),
            session_id: session_id(),
            state: StreamState::Failed { reason: private() },
        },
        MobileEvent::SessionContext {
            machine_id: machine_id(),
            session_id: session_id(),
            context: Some(private()),
        },
        MobileEvent::SessionName {
            machine_id: machine_id(),
            session_id: session_id(),
            name: private(),
        },
        MobileEvent::Notify {
            machine_id: machine_id(),
            session_id: session_id(),
            notice: RemoteNotice {
                title: private(),
                body: private(),
                pane: None,
                source: private(),
            },
        },
    ]
}

fn pane_events() -> Vec<MobileEvent> {
    vec![
        MobileEvent::PaneTitle {
            pane: pane(),
            title: private(),
        },
        MobileEvent::PaneLead {
            pane: pane(),
            role: Some(PaneRole::Follower),
            covered: true,
        },
        MobileEvent::PaneEnded {
            pane: pane(),
            end: PaneEnd::Lost { reason: private() },
        },
        MobileEvent::PaneEnded {
            pane: pane(),
            end: PaneEnd::Exited {
                code: Some(3),
                signal: Some(private()),
            },
        },
        MobileEvent::ClipboardWrite {
            pane: pane(),
            write_id: 1,
            contents: vec![ClipboardPart {
                mime: "text/plain".to_owned(),
                data: MARKER.as_bytes().to_vec(),
            }],
        },
        MobileEvent::PaneAgent {
            machine_id: machine_id(),
            session_id: session_id(),
            pane_id: "P1".to_owned(),
            agent: Some(private()),
            conversation_id: Some(private()),
        },
        MobileEvent::Chat {
            pane: pane(),
            events: vec![
                ChatEvent {
                    id: private(),
                    cursor: 1,
                    parent: None,
                    body: ChatBody::User {
                        text: private(),
                        images: 0,
                    },
                },
                ChatEvent {
                    id: "e2".to_owned(),
                    cursor: 2,
                    parent: None,
                    body: ChatBody::Live,
                },
            ],
        },
        MobileEvent::ChatState {
            pane: pane(),
            state: ChatState::Ended,
        },
    ]
}

#[test]
fn every_event_reaches_the_app_and_the_log_keeps_its_kind_without_its_payload() {
    let captured = Captured::new();
    let kept = Arc::new(Kept::default());
    let sink = LoggedSink::wrap(Arc::clone(&kept) as Arc<dyn EventSink>);
    let events = private_events();

    captured.run(|| {
        for event in events.clone() {
            sink.on_event(event);
        }
    });

    assert_eq!(
        *kept.0.lock().unwrap(),
        events,
        "the app is handed every event as it was"
    );
    let text = captured.text();
    for wanted in [
        "W link: machine unreachable machine=m1",
        "I ssh: host key unknown: asking the user machine=m1",
        "W ssh: host key changed: connect stopped machine=m1",
        "I ssh: machine asks for a sign-in machine=m1",
        "I sessions: session list reported machine=m1 sessions=1",
        "I stream: stream state state=failed session=S1",
        "I stream: notification session=S1",
        "I pane: role role=follower covered=true session=S1 pane=P1",
        "W pane: ended end=lost session=S1 pane=P1",
        "W pane: ended end=exited code=3 session=S1 pane=P1",
        "I pane: clipboard write asked pane=P1",
        &format!("I chat: pane agent announced agent={REDACTED} conversation=true session=S1 pane=P1"),
        "I chat: chat events count=2 prompts=1 live=true reset=false session=S1 pane=P1",
        "I chat: chat state state=ended session=S1 pane=P1",
    ] {
        assert!(text.contains(wanted), "no line {wanted:?} in:\n{text}");
    }
    assert_eq!(
        lines(&text).len(),
        14,
        "a title, a name and a context write nothing:\n{text}"
    );
    captured.assert_clean();
}
