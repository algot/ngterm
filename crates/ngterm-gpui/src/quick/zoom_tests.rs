use super::*;
use crate::window_zoom::{Settle, ZoomRequest};

const PANEL: Rect = [410., 190., 1100., 700.];
const VISIBLE: Rect = [0., 0., 1920., 1055.];

#[test]
#[expect(clippy::float_cmp, reason = "a frame is handed back as it was kept, never computed")]
fn a_zoom_fills_the_visible_frame_and_its_unzoom_gives_the_panels_frame_back() {
    let mut restore = Restore::default();
    assert!(!restore.filled());
    assert_eq!(restore.target(PANEL, VISIBLE), VISIBLE);
    assert!(restore.filled());
    assert_eq!(restore.target(VISIBLE, VISIBLE), PANEL);
    assert_eq!(restore, Restore::default(), "the frame is given back once");
}

#[test]
#[expect(clippy::float_cmp, reason = "a frame is handed back as it was kept, never computed")]
fn an_unzoom_gives_the_panels_frame_back_after_the_screens_visible_frame_changed() {
    let without_dock: Rect = [0., 0., 1920., 1175.];
    let mut restore = Restore::default();
    assert_eq!(restore.target(PANEL, VISIBLE), VISIBLE);
    // the window no longer has its screen's visible size, and the kept frame still reads as the zoom
    assert_eq!(
        ZoomRequest::new(false).settle(restore.filled(), restore.filled()),
        Settle::Request
    );
    assert_eq!(restore.target(VISIBLE, without_dock), PANEL);
    assert_eq!(
        ZoomRequest::new(false).settle(restore.filled(), restore.filled()),
        Settle::Done
    );
    assert_eq!(
        restore.target(PANEL, without_dock),
        without_dock,
        "the next zoom keeps the panel's own frame"
    );
    assert_eq!(restore.target(without_dock, without_dock), PANEL);
}

#[test]
#[expect(clippy::float_cmp, reason = "a frame is handed back as it was kept, never computed")]
fn a_zoom_after_an_unzoom_keeps_the_frame_the_window_has_then() {
    let moved: Rect = [100., 80., 900., 600.];
    let mut restore = Restore::default();
    assert_eq!(restore.target(PANEL, VISIBLE), VISIBLE);
    assert_eq!(restore.target(VISIBLE, VISIBLE), PANEL);
    assert_eq!(restore.target(moved, VISIBLE), VISIBLE);
    assert_eq!(restore.target(VISIBLE, VISIBLE), moved);
}

#[test]
#[expect(
    clippy::float_cmp,
    reason = "whole coordinates, exact in the arithmetic that fits them"
)]
fn an_unzoom_on_another_screen_centers_the_panels_frame_there() {
    let other: Rect = [-1440., 155., 1440., 875.];
    let mut restore = Restore::default();
    assert_eq!(restore.target(PANEL, VISIBLE), VISIBLE);
    // the zoom's display was unplugged: the kept frame lies on no screen that is left
    assert_eq!(restore.target(other, other), [-1270., 242.5, 1100., 700.]);
    assert!(!restore.filled());
}

#[test]
#[expect(
    clippy::float_cmp,
    reason = "whole coordinates, exact in the arithmetic that fits them"
)]
fn an_unzoom_on_a_shrunk_screen_moves_the_panels_frame_inside_it() {
    let shrunk: Rect = [0., 25., 1280., 695.];
    let mut restore = Restore::default();
    assert_eq!(restore.target(PANEL, VISIBLE), VISIBLE);
    assert_eq!(
        restore.target(VISIBLE, shrunk),
        [180., 25., 1100., 695.],
        "no larger than the screen, and moved by the least that brings it inside"
    );
}

#[test]
#[expect(clippy::float_cmp, reason = "a frame is handed back as it was kept, never computed")]
fn an_unzoom_on_the_unchanged_screen_gives_back_a_frame_that_reaches_past_it() {
    let dragged: Rect = [1500., -300., 1100., 700.];
    let mut restore = Restore::default();
    assert_eq!(restore.target(dragged, VISIBLE), VISIBLE);
    assert_eq!(restore.target(VISIBLE, VISIBLE), dragged);
}
