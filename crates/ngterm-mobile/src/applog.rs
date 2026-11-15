//! The apps' diagnostic log ([`AppLog`]): a bounded, rotating text file the core and the apps both write, which the
//! apps show, copy and export so a problem on a phone can be read afterwards.
//!
//! **Storage.** One directory holds the current file ([`FILE_NAME`]) and the one before it ([`ROTATED_NAME`]). A line
//! that would take the current file past [`FILE_CAP`] rotates it first, so the log never holds more than twice the
//! cap. There is no copy in memory: every line is written to the file at once, so the log survives a restart and a
//! crash keeps the lines before it, and what the apps read is what is on disk. A log whose directory or file can't
//! be written drops its lines: logging never fails a caller.
//!
//! **Lines.** `2026-11-15T10:11:12.345Z I ssh: connected machine=…`: a UTC timestamp, the level's letter, a short
//! component tag ([`tag`]), the text, then `key=value` fields.
//!
//! **Who writes.** The core writes through `tracing`: [`note!`](crate::note) emits an event whose target is one of
//! [`tag`]'s, and the log's subscriber ([`AppLog::dispatch`]) takes the events of this crate's targets alone. The
//! app's process installs it for every thread ([`app_log`]); a test scopes it to its own thread, and the actor's
//! thread takes the dispatcher of the thread that started it. The apps append their own lines with [`AppLog::append`].
//!
//! **Privacy.** The log never holds typed text, terminal output, chat bodies, key material, passphrases or host key
//! fingerprints. The code keeps them out in four ways:
//! - [`note!`](crate::note) takes its text as a literal, so no line's text is built from data.
//! - The subscriber drops every value recorded through `Debug` or `Display`: only strings, integers and booleans
//!   are written.
//! - A string value is written as it is only in the fields that name what the user already sees of a machine
//!   ([`IDENTITY_FIELDS`]), cut at [`VALUE_CAP`]; in every other field it must read as a class or an id
//!   ([`is_class`]) or it is written as [`REDACTED`].
//! - Events of other crates (the terminal, russh) never reach the log.
//!
//! An app's own line ([`AppLog::append`]) is the app's to keep clean; the core makes it one line and cuts it at
//! [`MESSAGE_CAP`].

mod events;
#[cfg(test)]
pub(crate) mod tests;

use std::fmt::Write as _;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use tracing::field::{Field, Visit};
use tracing::span::{Attributes, Id, Record};
use tracing::{Dispatch, Event, Level, Metadata, Subscriber};

pub(crate) use self::events::LoggedSink;

/// The current log file's name in the log's directory.
pub const FILE_NAME: &str = "app.log";
/// The name of the file before the current one.
pub const ROTATED_NAME: &str = "app.log.1";
/// The size a log file is rotated at: the log holds at most twice this.
pub const FILE_CAP: u64 = 512 * 1024;
/// The most characters of an app's own line.
pub const MESSAGE_CAP: usize = 300;
/// The most characters of an app's component tag.
pub const TAG_CAP: usize = 16;
/// The most characters of a field's string value.
pub const VALUE_CAP: usize = 64;
/// What stands for a string value that is neither a class nor an id.
pub const REDACTED: &str = "<redacted>";
/// The fields whose string value is written as the user sees it in the app: a machine's label, host and user.
pub const IDENTITY_FIELDS: [&str; 3] = ["label", "host", "user"];

/// The core's component tags: the `tracing` target of each of its events, and, after [`tag::PREFIX`], the tag a line
/// shows.
pub mod tag {
    /// What every target of the core starts with: the subscriber takes these alone.
    pub const PREFIX: &str = "ngterm_mobile::";
    /// The log itself: opened, cleared.
    pub const LOG: &str = "ngterm_mobile::log";
    /// A machine's connection: connects, losses, retries, suspend and resume.
    pub const LINK: &str = "ngterm_mobile::link";
    /// ssh: the key's class, authentication, host keys, why a connect failed.
    pub const SSH: &str = "ngterm_mobile::ssh";
    /// A machine's sessions: listings (the CLI asked, what answered), creates and ends.
    pub const SESSIONS: &str = "ngterm_mobile::sessions";
    /// Attached sessions' presentation streams.
    pub const STREAM: &str = "ngterm_mobile::stream";
    /// Shown panes: attach, lead and role, ends.
    pub const PANE: &str = "ngterm_mobile::pane";
    /// The agent chat view: its state and why an action was held or refused.
    pub const CHAT: &str = "ngterm_mobile::chat";
    /// Input to a pane's terminal: sent or dropped, never what.
    pub const INPUT: &str = "ngterm_mobile::input";
}

/// Writes one line of the core's to the log: `note!(INFO, tag::SSH, "connected", machine = id)`. The text is a
/// literal; a field's value is a string, an integer or a boolean ([`crate::applog`] says what becomes of each).
#[macro_export]
macro_rules! note {
    ($level:ident, $tag:expr, $what:literal $(, $key:ident = $value:expr)* $(,)?) => {
        ::tracing::event!(target: $tag, ::tracing::Level::$level, what = $what $(, $key = $value)*)
    };
}

/// A line's level.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LogLevel {
    Info,
    Warn,
    Error,
}

impl LogLevel {
    fn letter(self) -> char {
        match self {
            Self::Info => 'I',
            Self::Warn => 'W',
            Self::Error => 'E',
        }
    }
}

/// Why the log could not be exported.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum LogError {
    /// The file could not be written.
    #[error("{reason}")]
    Io { reason: String },
}

/// The files of a log, with the current one open.
struct Store {
    dir: PathBuf,
    cap: u64,
    file: Option<File>,
    written: u64,
}

impl Store {
    fn current(&self) -> PathBuf {
        self.dir.join(FILE_NAME)
    }

    fn rotated(&self) -> PathBuf {
        self.dir.join(ROTATED_NAME)
    }

    fn open(&mut self) -> Option<&mut File> {
        if self.file.is_none() {
            fs::create_dir_all(&self.dir).ok()?;
            let file = OpenOptions::new().create(true).append(true).open(self.current()).ok()?;
            self.written = file.metadata().map_or(0, |metadata| metadata.len());
            self.file = Some(file);
        }
        self.file.as_mut()
    }

    fn rotate(&mut self) {
        self.file = None;
        // A rename that fails leaves the current file growing by one more line; the next line tries again.
        let _ = fs::rename(self.current(), self.rotated());
    }

    fn write(&mut self, line: &str) {
        let size = u64::try_from(line.len()).unwrap_or(u64::MAX);
        if self.open().is_none() {
            return;
        }
        if self.written > 0 && self.written.saturating_add(size) > self.cap {
            self.rotate();
        }
        let Some(file) = self.open() else { return };
        if file.write_all(line.as_bytes()).is_ok() {
            self.written = self.written.saturating_add(size);
        } else {
            // Reopened by the next line: the file may have gone with its directory.
            self.file = None;
        }
    }

    fn clear(&mut self) {
        self.file = None;
        let _ = fs::remove_file(self.rotated());
        let _ = fs::remove_file(self.current());
    }
}

/// The last `max` bytes of `path`, or all of it.
fn read_end(path: &Path, max: u64) -> Vec<u8> {
    let mut bytes = Vec::new();
    let Ok(mut file) = File::open(path) else {
        return bytes;
    };
    let length = file.metadata().map_or(0, |metadata| metadata.len());
    if length > max && file.seek(SeekFrom::Start(length - max)).is_err() {
        return bytes;
    }
    // What was read before a failure is still the file's.
    let _ = file.take(max).read_to_end(&mut bytes);
    bytes
}

/// The app's diagnostic log. One per process ([`app_log`]); every method is safe from any thread.
#[derive(uniffi::Object)]
pub struct AppLog {
    store: Mutex<Store>,
}

impl std::fmt::Debug for AppLog {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("AppLog").finish_non_exhaustive()
    }
}

impl AppLog {
    /// A log in `dir` whose files rotate at `cap` bytes, continuing the files already there.
    #[must_use]
    pub fn with_cap(dir: impl Into<PathBuf>, cap: u64) -> Arc<Self> {
        Arc::new(Self {
            store: Mutex::new(Store {
                dir: dir.into(),
                cap,
                file: None,
                written: 0,
            }),
        })
    }

    /// The `tracing` dispatcher that writes the core's events to this log: the events whose target is one of
    /// [`tag`]'s, at `INFO` and above, and nothing of any other crate.
    #[must_use]
    pub fn dispatch(self: &Arc<Self>) -> Dispatch {
        Dispatch::new(LogSubscriber { log: Arc::clone(self) })
    }

    fn store(&self) -> MutexGuard<'_, Store> {
        self.store.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn line(&self, level: LogLevel, tag: &str, text: &str) {
        let mut line = String::with_capacity(text.len() + 48);
        stamp(&mut line, SystemTime::now());
        let _ = writeln!(line, " {} {tag}: {text}", level.letter());
        self.store().write(&line);
    }

    /// Both files' ends, oldest first: at most `max` bytes, starting at a line's start.
    fn window(&self, max: u64) -> String {
        let store = self.store();
        let mut bytes = read_end(&store.current(), max);
        let left = max.saturating_sub(u64::try_from(bytes.len()).unwrap_or(u64::MAX));
        if left > 0 {
            let mut older = read_end(&store.rotated(), left);
            older.append(&mut bytes);
            bytes = older;
        }
        drop(store);
        let whole = u64::try_from(bytes.len()).unwrap_or(u64::MAX) < max;
        let text = String::from_utf8_lossy(&bytes);
        if whole {
            return text.into_owned();
        }
        // The window may open in the middle of a line (or of a character): it starts at the next line.
        text.split_once('\n')
            .map_or_else(String::new, |(_, rest)| rest.to_owned())
    }
}

#[uniffi::export]
impl AppLog {
    /// A log in the directory `dir` (made when missing), continuing the files already there. The app's process uses
    /// [`app_log`], which also sends the core's own lines to it.
    #[uniffi::constructor]
    #[must_use]
    pub fn open(dir: String) -> Arc<Self> {
        Self::with_cap(dir, FILE_CAP)
    }

    /// Appends the app's own line: `tag` names the component (1 to [`TAG_CAP`] ASCII letters, digits, `-` or `_`;
    /// anything else reads `app`), `message` is made one line and cut at [`MESSAGE_CAP`] characters. The app never
    /// passes typed text, a message body, a key or a passphrase.
    #[expect(
        clippy::needless_pass_by_value,
        reason = "UniFFI passes the foreign side's arguments owned"
    )]
    pub fn append(&self, level: LogLevel, tag: String, message: String) {
        let tag = if is_tag(&tag) { tag.as_str() } else { "app" };
        self.line(level, tag, &one_line(&message, MESSAGE_CAP));
    }

    /// The newest lines, oldest first: the end of the log, at most `max_bytes` of it, starting at a line's start.
    #[must_use]
    pub fn tail(&self, max_bytes: u32) -> String {
        self.window(u64::from(max_bytes))
    }

    /// The whole log, oldest line first.
    #[must_use]
    pub fn text(&self) -> String {
        self.window(u64::MAX)
    }

    /// Writes the whole log to the file `path` (replacing it), for the app to share; the bytes written.
    ///
    /// # Errors
    ///
    /// [`LogError::Io`] when the file can't be written.
    #[expect(
        clippy::needless_pass_by_value,
        reason = "UniFFI passes the foreign side's arguments owned"
    )]
    pub fn export(&self, path: String) -> Result<u64, LogError> {
        let text = self.text();
        fs::write(&path, &text).map_err(|error| LogError::Io {
            reason: error.to_string(),
        })?;
        Ok(u64::try_from(text.len()).unwrap_or(u64::MAX))
    }

    /// The bytes the log holds on disk.
    #[must_use]
    pub fn size(&self) -> u64 {
        let store = self.store();
        [store.current(), store.rotated()]
            .iter()
            .filter_map(|path| fs::metadata(path).ok())
            .map(|metadata| metadata.len())
            .sum()
    }

    /// Deletes every line; the log starts again with a line saying so.
    pub fn clear(&self) {
        self.store().clear();
        self.line(LogLevel::Info, short(tag::LOG), "log cleared");
    }
}

/// The process's log, opened in `dir` by the first call, which also sends the core's own lines to it from every
/// thread; later calls hand back the same log whatever their `dir`. The app calls it once at start, before it makes
/// its [`crate::MobileCore`].
#[uniffi::export]
#[must_use]
pub fn app_log(dir: String) -> Arc<AppLog> {
    static LOG: OnceLock<Arc<AppLog>> = OnceLock::new();
    Arc::clone(LOG.get_or_init(|| {
        let log = AppLog::open(dir);
        // A process that already has a subscriber (a test's) keeps it: the app's lines still reach the log.
        let _ = tracing::dispatcher::set_global_default(log.dispatch());
        note!(INFO, tag::LOG, "log opened", core = env!("CARGO_PKG_VERSION"));
        log
    }))
}

/// The dispatcher a thread the core starts takes from the thread starting it, so a log scoped to one thread (a
/// test's) hears the core's own threads too; `None` when that thread has none of its own, which leaves the new thread
/// on the process's.
pub(crate) fn inherited() -> Option<Dispatch> {
    tracing::dispatcher::get_default(|dispatch| dispatch.is::<LogSubscriber>().then(|| dispatch.clone()))
}

/// The name a value's `Debug` starts with (an enum's variant, an error's kind), for a field: its leading ASCII letters
/// and digits, at most [`VALUE_CAP`] of them, so nothing the value carries comes along.
pub(crate) fn variant(value: &dyn std::fmt::Debug) -> String {
    format!("{value:?}")
        .chars()
        .take_while(char::is_ascii_alphanumeric)
        .take(VALUE_CAP)
        .collect()
}

/// The tag a target shows: what follows [`tag::PREFIX`].
fn short(target: &str) -> &str {
    target.strip_prefix(tag::PREFIX).unwrap_or(target)
}

/// Whether `value` names an app's component: 1 to [`TAG_CAP`] ASCII letters, digits, `-` or `_`, so it never holds
/// the `:` that ends a line's tag.
fn is_tag(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= TAG_CAP
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

/// Whether `value` reads as a class or an id: 1 to [`VALUE_CAP`] ASCII letters, digits or `_ - . : + @ /`, so a
/// state's name, a count, a session's or a pane's id, never a sentence.
#[must_use]
pub fn is_class(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= VALUE_CAP
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"_-.:+@/".contains(&byte))
}

/// `text` as one line of at most `cap` characters: control characters and line breaks become spaces.
fn one_line(text: &str, cap: usize) -> String {
    text.chars()
        .take(cap)
        .map(|character| if character.is_control() { ' ' } else { character })
        .collect()
}

/// Appends `at` as `2026-11-15T10:11:12.345Z`.
fn stamp(line: &mut String, at: SystemTime) {
    let since = at.duration_since(UNIX_EPOCH).unwrap_or(Duration::ZERO);
    let seconds = since.as_secs();
    let (year, month, day) = civil(seconds / 86_400);
    let (hour, minute, second) = (seconds / 3600 % 24, seconds / 60 % 60, seconds % 60);
    let _ = write!(
        line,
        "{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{:03}Z",
        since.subsec_millis()
    );
}

/// The proleptic Gregorian date of the day `days` after 1970-01-01 (Howard Hinnant's `civil_from_days`).
fn civil(days: u64) -> (u64, u64, u64) {
    let shifted = days + 719_468;
    let era = shifted / 146_097;
    let day_of_era = shifted % 146_097;
    let year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    };
    let year = year_of_era + era * 400 + u64::from(month <= 2);
    (year, month, day)
}

/// The log as a `tracing` subscriber: events only, of the core's own targets.
struct LogSubscriber {
    log: Arc<AppLog>,
}

impl Subscriber for LogSubscriber {
    fn enabled(&self, metadata: &Metadata<'_>) -> bool {
        metadata.is_event() && *metadata.level() <= Level::INFO && metadata.target().starts_with(tag::PREFIX)
    }

    fn new_span(&self, _: &Attributes<'_>) -> Id {
        Id::from_u64(1)
    }

    fn record(&self, _: &Id, _: &Record<'_>) {}

    fn record_follows_from(&self, _: &Id, _: &Id) {}

    fn event(&self, event: &Event<'_>) {
        let metadata = event.metadata();
        let level = match *metadata.level() {
            Level::ERROR => LogLevel::Error,
            Level::WARN => LogLevel::Warn,
            _ => LogLevel::Info,
        };
        let mut fields = Fields::default();
        event.record(&mut fields);
        self.log.line(level, short(metadata.target()), &fields.text());
    }

    fn enter(&self, _: &Id) {}

    fn exit(&self, _: &Id) {}
}

/// An event's fields as a line's text: `what`, then each `key=value`.
#[derive(Default)]
struct Fields {
    what: String,
    rest: String,
}

impl Fields {
    fn text(self) -> String {
        format!("{}{}", self.what, self.rest)
    }

    fn pair(&mut self, field: &Field, value: impl std::fmt::Display) {
        let _ = write!(self.rest, " {}={value}", field.name());
    }
}

impl Visit for Fields {
    fn record_str(&mut self, field: &Field, value: &str) {
        let name = field.name();
        if name == "what" {
            self.what = one_line(value, MESSAGE_CAP);
        } else if IDENTITY_FIELDS.contains(&name) {
            self.pair(field, one_line(value, VALUE_CAP));
        } else if is_class(value) {
            self.pair(field, value);
        } else {
            self.pair(field, REDACTED);
        }
    }

    fn record_u64(&mut self, field: &Field, value: u64) {
        self.pair(field, value);
    }

    fn record_i64(&mut self, field: &Field, value: i64) {
        self.pair(field, value);
    }

    fn record_bool(&mut self, field: &Field, value: bool) {
        self.pair(field, value);
    }

    // A value formatted by its type could hold anything: it is not written.
    fn record_debug(&mut self, field: &Field, _: &dyn std::fmt::Debug) {
        self.pair(field, REDACTED);
    }
}
