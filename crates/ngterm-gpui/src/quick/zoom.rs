//! The quick terminal's zoom on its window host: the request rule is every window's ([`crate::window_zoom`]).
//!
//! macOS has no maximize for the panel: `-[NSWindow zoom:]` does nothing on a window that is not resizable, as the
//! panel is. Its request there gives the panel its screen's visible frame, as upstream's panel takes it
//! (`QuickTerminalController.targetFrame`), and the unzoom gives back the frame it had ([`Restore`]). The kept frame
//! is the panel's maximize there, not the window's size against its screen, which stops matching once the screen's
//! visible frame changes under a zoomed panel; the request settles on it as the others do. A kept frame is in the
//! coordinates of the screen the zoom filled, so an unzoom on a changed or another screen brings it inside that one.

/// A window's frame in its platform's coordinates: x, y, width, height.
#[cfg(any(target_os = "macos", test))]
pub type Rect = [f64; 4];

/// The frame the macOS panel had before its zoom filled the screen, and that screen's visible frame.
#[cfg(any(target_os = "macos", test))]
#[derive(Debug, Default, Clone, Copy, PartialEq)]
pub struct Restore(Option<(Rect, Rect)>);

#[cfg(any(target_os = "macos", test))]
impl Restore {
    /// Whether a zoom of the panel's filled its screen and no unzoom gave the frame back since.
    #[must_use]
    pub fn filled(&self) -> bool {
        self.0.is_some()
    }

    /// The frame a request gives the window: the kept frame for the unzoom of a zoom that [`filled`](Self::filled)
    /// the screen, whatever size the window has by now, brought inside `visible` when that is no longer the frame
    /// the zoom filled (the screen changed, or the window is on another one); else the screen's `visible` frame,
    /// `current` kept.
    #[expect(
        clippy::float_cmp,
        reason = "a visible frame is compared as the screen reported it, never computed"
    )]
    pub fn target(&mut self, current: Rect, visible: Rect) -> Rect {
        match self.0.take() {
            Some((kept, filled)) if filled == visible => kept,
            Some((kept, _)) => fit(kept, visible),
            None => {
                self.0 = Some((current, visible));
                visible
            }
        }
    }
}

/// `frame` inside `visible`: no larger, moved in by the least that brings it inside, and centered when no part of
/// it was there.
#[cfg(any(target_os = "macos", test))]
fn fit(frame: Rect, visible: Rect) -> Rect {
    let apart = (0..2)
        .any(|axis| frame[axis] >= visible[axis] + visible[axis + 2] || frame[axis] + frame[axis + 2] <= visible[axis]);
    let mut fitted = frame;
    for axis in 0..2 {
        let (start, room) = (visible[axis], visible[axis + 2]);
        let extent = frame[axis + 2].min(room);
        fitted[axis + 2] = extent;
        fitted[axis] = if apart {
            start + (room - extent) / 2.
        } else {
            frame[axis].clamp(start, start + room - extent)
        };
    }
    fitted
}

#[cfg(test)]
#[path = "zoom_tests.rs"]
mod tests;
