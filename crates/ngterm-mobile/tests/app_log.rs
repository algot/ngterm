//! The process's log ([`ngterm_mobile::app_log`]) as an app uses it: one log per process, which hears the core's own
//! lines from every thread and the app's, and survives being opened again.

use std::path::PathBuf;

use ngterm_mobile::applog::tag;
use ngterm_mobile::{AppLog, LogLevel, app_log, note};

#[test]
fn the_process_has_one_log_that_hears_the_core_on_every_thread() {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(format!("app-log-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let path = dir.to_string_lossy().into_owned();

    let log = app_log(path.clone());
    let again = app_log("/nowhere/else".to_owned());
    again.append(LogLevel::Info, "app".to_owned(), "started".to_owned());
    std::thread::spawn(|| note!(INFO, tag::LINK, "from another thread", machine = "m1"))
        .join()
        .unwrap();

    let text = log.text();
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 3, "{text}");
    assert!(
        lines[0].ends_with(&format!("I log: log opened core={}", env!("CARGO_PKG_VERSION"))),
        "{text}"
    );
    assert!(
        lines[1].ends_with("I app: started"),
        "the same log whatever the later directory: {text}"
    );
    assert!(lines[2].ends_with("I link: from another thread machine=m1"), "{text}");
    assert_eq!(AppLog::open(path).text(), text, "the files are the log");
    std::fs::remove_dir_all(&dir).unwrap();
}
