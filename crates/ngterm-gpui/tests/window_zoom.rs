//! A main window's zoom on a real compositor, the sandbox's own headless weston (AGENTS.md > Never touch the user's
//! running ngterm): `window.zoom` and `window.resize` sent faster than weston answers them, read back from
//! `window.list`. A build that sends each request as it comes leaves the window maximized after a zoom and an unzoom
//! a few milliseconds apart: the unzoom is read from a maximize not answered yet, or reaches weston between the ack
//! of the zoom's configure and the commit that applies it, where weston drops it (`crate::window_zoom`). The test
//! does not tell the two apart.
//!
//! A test whose tool is missing prints `SKIPPED:` and passes, unless `NGTERM_REQUIRE_DISPLAY_TESTS` is set.
//!
//! Linux only: the window on a headless weston.

#![cfg(target_os = "linux")]

#[macro_use]
#[expect(dead_code, reason = "the sandbox serves the process tests too")]
mod support;

use std::io::{BufRead as _, BufReader, Write as _};
use std::time::Duration;

use serde_json::{Value, json};
use support::{DEADLINE, NO_SEATED_WESTON, Sandbox, TestResult, lavapipe_icd, seated_weston, wait_for};

/// One control request with `args` to the sandbox's socket; its result, or the error it answered.
fn request(sandbox: &Sandbox, cmd: &str, args: &Value) -> TestResult<Value> {
    let mut socket = std::os::unix::net::UnixStream::connect(sandbox.path("state/ngterm.sock"))?;
    socket.set_read_timeout(Some(DEADLINE))?;
    writeln!(socket, "{}", json!({ "cmd": cmd, "args": args }))?;
    let mut reply = String::new();
    BufReader::new(socket).read_line(&mut reply)?;
    let reply: Value = serde_json::from_str(&reply)?;
    if reply["ok"] == json!(true) {
        Ok(reply.get("result").cloned().unwrap_or(Value::Null))
    } else {
        Err(format!("{cmd} {args}: {reply}").into())
    }
}

fn toggle_zoom(sandbox: &Sandbox) -> TestResult {
    request(sandbox, "window.zoom", &json!({}))?;
    Ok(())
}

/// Whether `window.list` reads the one window zoomed; `None` before its first frame reported a state.
fn zoomed(sandbox: &Sandbox) -> TestResult<Option<bool>> {
    let list = request(sandbox, "window.list", &json!({}))?;
    Ok(list["windows"][0]["zoomed"].as_bool())
}

/// How long `window.list` must keep reading a zoom for the window to count as at rest in it: a window on its way
/// through a maximize reads restored first.
const REST: Duration = Duration::from_secs(1);

/// Waits until `window.list` reads the window `maximized` and keeps reading it for [`REST`].
fn wait_rested(sandbox: &Sandbox, maximized: bool, after: &str) -> TestResult {
    let started = std::time::Instant::now();
    let mut since = None;
    loop {
        let now = zoomed(sandbox)?;
        if now != Some(maximized) {
            since = None;
        } else if since.get_or_insert_with(std::time::Instant::now).elapsed() >= REST {
            return Ok(());
        }
        if started.elapsed() > DEADLINE {
            return Err(format!(
                "after {after}: the window never rested at zoomed={maximized}; window.list reads zoomed={now:?}:\n{}",
                sandbox.log("primary.log")
            )
            .into());
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn a_main_window_follows_back_to_back_zooms_on_weston() -> TestResult {
    if seated_weston().is_none() {
        skip!("{NO_SEATED_WESTON}");
    }
    let Some(lavapipe) = lavapipe_icd() else {
        skip!("no lavapipe ICD (scripts/fetch-lavapipe.sh)");
    };
    let mut sandbox = Sandbox::new()?;
    sandbox.start_weston()?;
    sandbox.use_software_rendering(&lavapipe);
    let primary = sandbox.start_gpui_primary("primary.log")?;
    wait_for(|| (zoomed(&sandbox).ok()? == Some(false)).then_some(()))
        .map_err(|_| format!("the window never reported its state:\n{}", sandbox.log("primary.log")))?;

    // an unzoom right behind the zoom, from no distance to a few frames behind it: the window ends restored
    for gap in (0..=32).step_by(4).map(Duration::from_millis) {
        toggle_zoom(&sandbox)?;
        std::thread::sleep(gap);
        toggle_zoom(&sandbox)?;
        wait_rested(&sandbox, false, &format!("an unzoom {gap:?} behind its zoom"))?;
    }

    // an odd number of toggles leaves the window zoomed, an even number restored
    for (toggles, maximized) in [(3, true), (5, false), (2, false), (1, true), (4, true), (1, false)] {
        for _ in 0..toggles {
            toggle_zoom(&sandbox)?;
        }
        wait_rested(&sandbox, maximized, &format!("{toggles} toggles"))?;
    }

    // a resize right behind a zoom takes the window out of it; sized while still maximized, weston would end the
    // connection
    toggle_zoom(&sandbox)?;
    request(&sandbox, "window.resize", &json!({ "width": 900, "height": 600 }))?;
    wait_rested(&sandbox, false, "a resize behind a zoom")?;

    sandbox.terminate(primary)?;
    assert_eq!(sandbox.wait_exit(primary, Duration::from_secs(10))?.0.code(), Some(0));
    Ok(())
}
