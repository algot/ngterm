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

#[test]
fn a_toggle_right_behind_a_toggle_undoes_it_once_the_window_answered() {
    let mut pending = Pending::default();
    pending.toggle(false);
    assert_eq!(pending.settle(false, false), Some(Settle::Request));
    // the window still reads restored: the second toggle is of the maximize on its way, not of what it reads
    pending.toggle(false);
    assert_eq!(pending.settle(false, false), Some(Settle::Wait));
    assert_eq!(pending.settle(false, true), Some(Settle::Again), "acked, not committed");
    assert_eq!(pending.settle(true, true), Some(Settle::Request));
    assert_eq!(pending.sends(), 2);
    assert_eq!(pending.settle(false, false), Some(Settle::Done));
    assert!(pending.is_settled());
    assert_eq!(pending.settle(false, false), None);
}

#[test]
fn three_toggles_before_any_answer_leave_one_maximize() {
    let mut pending = Pending::default();
    pending.toggle(false);
    assert_eq!(pending.settle(false, false), Some(Settle::Request));
    pending.toggle(false);
    pending.toggle(false);
    assert_eq!(pending.settle(false, false), Some(Settle::Wait));
    assert_eq!(pending.settle(true, true), Some(Settle::Done));
}

#[test]
fn a_request_never_answered_is_forgotten_at_the_last_look() {
    let mut pending = Pending::default();
    pending.toggle(false);
    assert_eq!(pending.settle(false, false), Some(Settle::Request));
    // before the last look the request still counts: the toggle undoes it, and nothing more goes out
    assert_eq!(pending.watch(1, false, false), Watch::Wait);
    pending.toggle(false);
    assert_eq!(pending.settle(false, false), Some(Settle::Wait));
    // at the last one no answer is coming: the next toggle is of the window as it reads, and goes out as the first
    assert_eq!(pending.watch(1, false, true), Watch::Unanswered);
    assert!(pending.is_settled());
    assert_eq!(pending.watch(1, false, true), Watch::Over);
    pending.toggle(false);
    assert_eq!(pending.settle(false, false), Some(Settle::Request));
}

#[test]
fn a_request_answered_is_kept_however_long_its_frames_take() {
    let mut pending = Pending::default();
    pending.toggle(false);
    assert_eq!(pending.settle(false, false), Some(Settle::Request));
    pending.toggle(false);
    // the window maximized, and no frame is drawn for it (hidden, on another workspace): nothing settles
    assert_eq!(pending.watch(1, true, false), Watch::Answered);
    assert_eq!(pending.watch(1, true, false), Watch::Wait, "an answer is reported once");
    assert_eq!(pending.watch(1, true, true), Watch::Wait, "answered: not forgotten");
    // a third toggle long after is of the restore still to send, so the three end maximized
    pending.toggle(true);
    assert_eq!(pending.settle(false, true), Some(Settle::Done));
}

#[test]
fn an_answer_undone_before_its_frames_counts_as_none() {
    let mut pending = Pending::default();
    pending.toggle(false);
    assert_eq!(pending.settle(false, false), Some(Settle::Request));
    assert_eq!(pending.watch(1, true, false), Watch::Answered);
    assert_eq!(pending.watch(1, false, true), Watch::Unanswered);
}

#[test]
fn a_look_at_an_earlier_request_ends_once_another_went_out() {
    let mut pending = Pending::default();
    pending.toggle(false);
    assert_eq!(pending.settle(false, false), Some(Settle::Request));
    assert_eq!(pending.settle(true, true), Some(Settle::Done));
    assert_eq!(pending.watch(1, true, false), Watch::Over, "settled");
    pending.toggle(true);
    assert_eq!(pending.settle(true, true), Some(Settle::Request));
    assert_eq!(
        pending.watch(1, true, true),
        Watch::Over,
        "the second request has its own looks"
    );
    assert_eq!(pending.watch(2, true, false), Watch::Wait);
}

#[test]
fn a_request_not_sent_yet_is_kept_however_long_its_frames_take() {
    let mut pending = Pending::default();
    pending.want(false);
    assert_eq!(pending.settle(false, true), Some(Settle::Again));
    assert_eq!(pending.watch(0, true, true), Watch::Over);
    pending.toggle(true);
    assert_eq!(
        pending.settle(true, true),
        Some(Settle::Done),
        "the toggle is of the restore that waited, not of the window"
    );
}

// The test window never maximizes, runs no frame callbacks, and panics when asked to maximize: a request here would
// panic, and the frames and the requests themselves are the weston process test's (`tests/window_zoom.rs`).

#[gpui_kit::test]
fn a_toggle_over_a_maximize_not_committed_yet_waits_for_its_frames(cx: &mut gpui_kit::TestAppContext) {
    let cx = cx.add_empty_window();
    cx.update(|window, cx| {
        let zoom = WindowZoom::new(window);
        // a maximize the last frame committed and a restore acked since: the toggle maximizes, after the frames
        zoom.committed.set(true);
        zoom.toggle(window, cx);
        assert!(!zoom.pending.borrow().is_settled(), "nothing went out, nothing settled");
        // toggled back before the frames: the window is as wanted, with no request
        zoom.toggle(window, cx);
        assert!(!zoom.frame_started(window));
        zoom.settle(false, window, cx);
        assert!(zoom.pending.borrow().is_settled());
    });
}

#[gpui_kit::test]
fn a_restore_over_a_maximize_not_sent_yet_gives_the_window_its_size(cx: &mut gpui_kit::TestAppContext) {
    let cx = cx.add_empty_window();
    cx.update(|window, cx| {
        let zoom = WindowZoom::new(window);
        let size = gpui_kit::size(gpui_kit::px(640.), gpui_kit::px(400.));
        assert!(
            !zoom.restore_to(size, window, cx),
            "a window not maximized has nothing to restore"
        );
        assert_eq!(zoom.resize.get(), None);
        // a maximize waiting for its frames: the restore takes its place, and the window, as wanted, takes the size
        zoom.committed.set(true);
        zoom.toggle(window, cx);
        assert!(zoom.restore_to(size, window, cx));
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

// With a request that does nothing in place of the window's own, the test window is one whose window manager never
// answers: the looks run on the test clock.

fn unanswered(window: &Window) -> Rc<WindowZoom> {
    WindowZoom::requesting(window, |_| {})
}

#[gpui_kit::test]
fn a_request_never_answered_lets_the_next_toggle_out(cx: &mut gpui_kit::TestAppContext) {
    let cx = cx.add_empty_window();
    let zoom = cx.update(|window, cx| {
        let zoom = unanswered(window);
        zoom.toggle(window, cx);
        zoom.toggle(window, cx);
        assert_eq!(zoom.pending.borrow().sends(), 1, "one request at a time");
        zoom
    });
    cx.executor().advance_clock(UNANSWERED.saturating_sub(LOOK));
    assert!(!zoom.is_settled(), "still waited for");
    cx.executor().advance_clock(LOOK);
    assert!(zoom.is_settled());
    cx.update(|window, cx| zoom.toggle(window, cx));
    assert_eq!(zoom.pending.borrow().sends(), 2);
}

#[gpui_kit::test]
fn a_size_behind_a_maximize_never_answered_is_the_windows_once_the_wait_is_over(cx: &mut gpui_kit::TestAppContext) {
    let cx = cx.add_empty_window();
    let size = gpui_kit::size(gpui_kit::px(640.), gpui_kit::px(400.));
    let zoom = cx.update(|window, cx| {
        let zoom = unanswered(window);
        zoom.toggle(window, cx);
        assert!(zoom.restore_to(size, window, cx), "the maximize may still come");
        assert_ne!(window.bounds().size, size);
        zoom
    });
    cx.executor().advance_clock(UNANSWERED);
    assert!(zoom.is_settled());
    assert_eq!(cx.update(|window, _| window.bounds().size), size);
    assert_eq!(zoom.pending.borrow().sends(), 1);
}

#[gpui_kit::test]
fn a_toggle_behind_a_size_still_waiting_keeps_the_size(cx: &mut gpui_kit::TestAppContext) {
    let cx = cx.add_empty_window();
    let size = gpui_kit::size(gpui_kit::px(640.), gpui_kit::px(400.));
    let zoom = cx.update(|window, cx| {
        let zoom = unanswered(window);
        zoom.toggle(window, cx);
        assert!(zoom.restore_to(size, window, cx));
        zoom.toggle(window, cx);
        assert_eq!(
            zoom.resize.get(),
            Some(size),
            "the size waits for the window's next restore"
        );
        zoom
    });
    cx.executor().advance_clock(UNANSWERED);
    assert_eq!(
        cx.update(|window, _| window.bounds().size),
        size,
        "restored, it takes the size"
    );
    assert_eq!(zoom.resize.get(), None);
}

#[gpui_kit::test]
fn a_size_still_waiting_is_the_windows_once_it_reads_restored_with_no_request(cx: &mut gpui_kit::TestAppContext) {
    let cx = cx.add_empty_window();
    let size = gpui_kit::size(gpui_kit::px(640.), gpui_kit::px(400.));
    cx.update(|window, cx| {
        let zoom = WindowZoom::new(window);
        // kept through a maximize, which the window manager then undid itself
        zoom.resize.set(Some(size));
        zoom.settle(false, window, cx);
        assert_eq!(window.bounds().size, size);
        assert_eq!(zoom.resize.get(), None);
    });
}

#[gpui_kit::test]
fn a_size_given_to_a_window_at_rest_drops_one_still_waiting(cx: &mut gpui_kit::TestAppContext) {
    let cx = cx.add_empty_window();
    cx.update(|window, cx| {
        let zoom = WindowZoom::new(window);
        zoom.resize
            .set(Some(gpui_kit::size(gpui_kit::px(300.), gpui_kit::px(200.))));
        assert!(!zoom.restore_to(gpui_kit::size(gpui_kit::px(640.), gpui_kit::px(400.)), window, cx));
        assert_eq!(zoom.resize.get(), None, "the caller's own size is the last one");
    });
}

#[gpui_kit::test]
fn an_answer_seen_by_a_look_settles_after_its_frames(cx: &mut gpui_kit::TestAppContext) {
    let cx = cx.add_empty_window();
    cx.update(|window, _| {
        let zoom = unanswered(window);
        // a restore sent from a maximized window, which reads restored at the look
        zoom.pending.borrow_mut().want(false);
        assert_eq!(zoom.pending.borrow_mut().settle(true, true), Some(Settle::Request));
        assert!(zoom.look(1, false, window));
        assert_eq!(Rc::strong_count(&zoom), 2, "a frame callback holds the zoom");
        assert!(zoom.look(1, true, window), "answered: kept for its frames");
        assert!(!zoom.look(0, true, window), "another request's look is over");
    });
}
