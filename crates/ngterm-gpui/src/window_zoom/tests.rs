use super::*;

#[test]
fn a_zoom_requests_once_and_is_done_when_the_window_maximizes() {
    let mut zoom = ZoomRequest::new(true);
    assert_eq!(zoom.settle(false, false), Settle::Request);
    assert_eq!(
        zoom.settle(false, false),
        Settle::Wait,
        "no second request before the first one's answer"
    );
    assert_eq!(zoom.settle(true, true), Settle::Done);
}

#[test]
fn a_window_already_as_wanted_needs_no_request() {
    assert_eq!(ZoomRequest::new(false).settle(false, false), Settle::Done);
    assert_eq!(ZoomRequest::new(true).settle(true, true), Settle::Done);
}

#[test]
fn an_unzoom_during_the_zooms_request_restores_the_window_once_it_maximized() {
    let mut zoom = ZoomRequest::new(true);
    assert_eq!(zoom.settle(false, false), Settle::Request);
    zoom.want(false);
    // the window still reads unmaximized, as wanted now, but the maximize is on its way
    assert_eq!(zoom.settle(false, false), Settle::Wait);
    assert_eq!(
        zoom.settle(true, true),
        Settle::Request,
        "the window maximized: restore it"
    );
    assert_eq!(zoom.settle(true, true), Settle::Wait);
    assert_eq!(zoom.settle(false, false), Settle::Done);
}

#[test]
fn an_unzoom_waits_for_the_frame_that_commits_the_maximize() {
    let mut zoom = ZoomRequest::new(true);
    assert_eq!(zoom.settle(false, false), Settle::Request);
    zoom.want(false);
    // the maximize's configure was acked after the last frame: a restore now would come before its commit
    assert_eq!(zoom.settle(false, true), Settle::Again);
    assert_eq!(zoom.settle(true, true), Settle::Request, "the next frame committed it");
}

#[test]
fn a_maximize_not_committed_yet_needs_nothing_when_it_is_wanted() {
    let mut zoom = ZoomRequest::new(false);
    zoom.want(true);
    assert_eq!(zoom.settle(false, true), Settle::Done);
}

#[test]
fn a_rezoom_before_the_unzoom_is_sent_needs_nothing() {
    let mut zoom = ZoomRequest::new(false);
    zoom.want(true);
    assert_eq!(zoom.settle(true, true), Settle::Done);
}

fn at(start: Instant, millis: u64) -> Instant {
    start + Duration::from_millis(millis)
}

#[test]
fn a_toggle_right_behind_a_toggle_undoes_it_once_the_window_answered() {
    let start = Instant::now();
    let mut pending = Pending::default();
    pending.toggle(false, start);
    assert_eq!(pending.settle(false, false, start), Some(Settle::Request));
    // the window still reads restored: the second toggle is of the maximize on its way, not of what it reads
    pending.toggle(false, at(start, 5));
    assert_eq!(pending.settle(false, false, at(start, 5)), Some(Settle::Wait));
    assert_eq!(
        pending.settle(false, true, at(start, 20)),
        Some(Settle::Again),
        "acked, not committed"
    );
    assert_eq!(pending.settle(true, true, at(start, 40)), Some(Settle::Request));
    assert_eq!(pending.settle(false, false, at(start, 60)), Some(Settle::Done));
    assert!(pending.is_settled());
    assert_eq!(pending.settle(false, false, at(start, 80)), None);
}

#[test]
fn three_toggles_before_any_answer_leave_one_maximize() {
    let start = Instant::now();
    let mut pending = Pending::default();
    pending.toggle(false, start);
    assert_eq!(pending.settle(false, false, start), Some(Settle::Request));
    pending.toggle(false, start);
    pending.toggle(false, start);
    assert_eq!(pending.settle(false, false, start), Some(Settle::Wait));
    assert_eq!(pending.settle(true, true, at(start, 30)), Some(Settle::Done));
}

#[test]
fn a_request_never_answered_is_forgotten_at_the_next_one() {
    let start = Instant::now();
    let mut pending = Pending::default();
    pending.toggle(false, start);
    assert_eq!(pending.settle(false, false, start), Some(Settle::Request));
    // within the wait the request still counts: the toggle undoes it, and nothing more goes out
    pending.toggle(false, at(start, 999));
    assert_eq!(pending.settle(false, false, at(start, 999)), Some(Settle::Wait));
    // past it no answer is coming: the toggle is of the window as it reads, and goes out as the first did
    pending.toggle(false, at(start, 1000));
    assert_eq!(pending.settle(false, false, at(start, 1000)), Some(Settle::Request));
}

#[test]
fn a_request_not_sent_yet_is_kept_however_long_its_frames_take() {
    let start = Instant::now();
    let mut pending = Pending::default();
    pending.want(false, start);
    assert_eq!(pending.settle(false, true, start), Some(Settle::Again));
    pending.toggle(true, at(start, 5000));
    assert_eq!(
        pending.settle(true, true, at(start, 5000)),
        Some(Settle::Done),
        "the toggle is of the restore that waited, not of the window"
    );
}

// The test window never maximizes, runs no frame callbacks, and panics when asked to maximize: a request here would
// panic, and the frames and the requests themselves are the weston process test's (`tests/window_zoom.rs`).

#[gpui_kit::test]
fn a_toggle_over_a_maximize_not_committed_yet_waits_for_its_frames(cx: &mut gpui_kit::TestAppContext) {
    let cx = cx.add_empty_window();
    cx.update(|window, _| {
        let zoom = WindowZoom::new(window);
        // a maximize the last frame committed and a restore acked since: the toggle maximizes, after the frames
        zoom.committed.set(true);
        zoom.toggle(window);
        assert!(!zoom.pending.borrow().is_settled(), "nothing went out, nothing settled");
        // toggled back before the frames: the window is as wanted, with no request
        zoom.toggle(window);
        assert!(!zoom.frame_started(window));
        zoom.settle(false, window);
        assert!(zoom.pending.borrow().is_settled());
    });
}

#[gpui_kit::test]
fn a_restore_over_a_maximize_not_sent_yet_gives_the_window_its_size(cx: &mut gpui_kit::TestAppContext) {
    let cx = cx.add_empty_window();
    cx.update(|window, _| {
        let zoom = WindowZoom::new(window);
        let size = gpui_kit::size(gpui_kit::px(640.), gpui_kit::px(400.));
        assert!(
            !zoom.restore_to(size, window),
            "a window not maximized has nothing to restore"
        );
        assert_eq!(zoom.resize.get(), None);
        // a maximize waiting for its frames: the restore takes its place, and the window, as wanted, takes the size
        zoom.committed.set(true);
        zoom.toggle(window);
        assert!(zoom.restore_to(size, window));
        assert_eq!(zoom.resize.get(), None);
        assert_eq!(window.bounds().size, size);
        assert!(zoom.pending.borrow().is_settled());
    });
}

#[gpui_kit::test]
fn a_bounds_change_with_nothing_to_settle_asks_for_no_frame(cx: &mut gpui_kit::TestAppContext) {
    let cx = cx.add_empty_window();
    cx.update(|window, _| {
        let zoom = WindowZoom::new(window);
        zoom.bounds_changed(window);
        assert_eq!(Rc::strong_count(&zoom), 1, "no frame callback holds the zoom");
        zoom.committed.set(true);
        zoom.bounds_changed(window);
        assert_eq!(Rc::strong_count(&zoom), 2, "a maximize change settles after its frames");
    });
}
