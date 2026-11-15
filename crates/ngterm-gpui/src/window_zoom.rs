//! A window's zoom (its maximize), followed until the window's maximize matches it.
//!
//! A maximize request reaches the window manager only at the right moment, and the window cannot see it go astray.
//! weston (libweston's xdg-shell) answers no configure to a maximize change that comes between the client's ack of a
//! configure and the commit that applies it: it compares the request with the committed state, which still holds the
//! old maximize, finds nothing to change, and never looks again. GPUI acks a configure as it arrives and commits it with
//! the next frame it draws, after that frame's callbacks ran. X11's request toggles, and so does Windows' (each picks
//! maximize or restore from the state it reads), so a request sent again before the first one's answer undoes it, and
//! a toggle read from a maximize whose answer is still out repeats the request instead of undoing it.
//!
//! So a window sends one request at a time ([`ZoomRequest`]), only when its maximize reads as the last drawn frame
//! committed it, and settles again once its state changes. A request that finds a configure acked and not committed
//! settles over two frames: the first commits every configure acked before it, and the second sends the request only
//! when the maximize still reads as that frame committed it; otherwise it waits for the next two.
//!
//! The quick terminal's window host settles every request over the two frames (`quick::view`). A main window
//! ([`WindowZoom`]) keeps the maximize its last frame committed, so a request with nothing in its way goes out at
//! once, as GPUI's own `zoom_window` does: a window no frame is drawn for (hidden, on another workspace) still takes
//! it. A window manager may never answer (X11 without one, a tiling compositor that refuses a maximize): a request
//! with no answer after [`UNANSWERED`] is forgotten at the next one, which then goes out as the first did.

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::{Duration, Instant};

use gpui_kit::{Pixels, Size, Window};

/// How long a request's answer is waited for before the next request counts it as never coming.
pub const UNANSWERED: Duration = Duration::from_secs(1);

/// What the window does next for a zoom.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Settle {
    /// The window's maximize is the zoom's: the request is done.
    Done,
    /// A request is in flight: its answer, a change of the window's state, settles again.
    Wait,
    /// A configure changed the maximize since the last frame and is not committed yet: settle after the next one.
    Again,
    /// Ask the window manager to maximize or restore the window.
    Request,
}

/// The zoom wanted of a window and the request in flight.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ZoomRequest {
    wanted: bool,
    /// The window's maximize when the last request went out, while it has not changed since.
    sent_from: Option<bool>,
}

impl ZoomRequest {
    #[must_use]
    pub fn new(wanted: bool) -> Self {
        Self {
            wanted,
            sent_from: None,
        }
    }

    /// The window is to be `wanted` now; a request in flight stays in flight.
    pub fn want(&mut self, wanted: bool) {
        self.wanted = wanted;
    }

    /// The step for the window's current maximize, `committed` the maximize as the last drawn frame committed it,
    /// recording a request the caller is to send.
    pub fn settle(&mut self, committed: bool, maximized: bool) -> Settle {
        if self.sent_from == Some(maximized) {
            return Settle::Wait;
        }
        if maximized == self.wanted {
            self.sent_from = None;
            return Settle::Done;
        }
        if committed != maximized {
            return Settle::Again;
        }
        self.sent_from = Some(maximized);
        Settle::Request
    }
}

/// A window's zoom requests: the one being settled and when it went out.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Pending {
    request: Option<ZoomRequest>,
    sent_at: Option<Instant>,
}

impl Pending {
    #[must_use]
    pub fn is_settled(&self) -> bool {
        self.request.is_none()
    }

    /// The opposite of what the window is to be: of the request being settled, else of its `maximized`.
    pub fn toggle(&mut self, maximized: bool, now: Instant) {
        self.forget_unanswered(now);
        let wanted = !self.request.map_or(maximized, |request| request.wanted);
        self.want(wanted, now);
    }

    /// The window is to be `wanted`.
    pub fn want(&mut self, wanted: bool, now: Instant) {
        self.forget_unanswered(now);
        match &mut self.request {
            Some(request) => request.want(wanted),
            None => self.request = Some(ZoomRequest::new(wanted)),
        }
    }

    /// [`ZoomRequest::settle`] for the request being settled, `None` with none; a request to send went out at `now`.
    pub fn settle(&mut self, committed: bool, maximized: bool, now: Instant) -> Option<Settle> {
        let step = self.request.as_mut()?.settle(committed, maximized);
        match step {
            Settle::Done => *self = Self::default(),
            Settle::Request => self.sent_at = Some(now),
            Settle::Wait | Settle::Again => {}
        }
        Some(step)
    }

    fn forget_unanswered(&mut self, now: Instant) {
        let unanswered = self
            .sent_at
            .is_some_and(|sent| now.saturating_duration_since(sent) >= UNANSWERED);
        if unanswered && self.request.is_some_and(|request| request.sent_from.is_some()) {
            *self = Self::default();
        }
    }
}

/// A main window's zoom: its requests, the maximize its last drawn frame committed, and the size it takes once
/// restored.
#[derive(Debug)]
pub struct WindowZoom {
    pending: RefCell<Pending>,
    committed: Cell<bool>,
    resize: Cell<Option<Size<Pixels>>>,
}

impl WindowZoom {
    #[must_use]
    pub fn new(window: &Window) -> Rc<Self> {
        Rc::new(Self {
            pending: RefCell::default(),
            committed: Cell::new(window.is_maximized()),
            resize: Cell::new(None),
        })
    }

    /// Whether no request is being settled.
    #[cfg(test)]
    pub fn is_settled(&self) -> bool {
        self.pending.borrow().is_settled()
    }

    /// Reads the last frame as one that committed the other maximize, so the next request waits for its frames: the
    /// test window panics when asked to maximize.
    #[cfg(test)]
    pub fn uncommit(&self) {
        self.committed.set(!self.committed.get());
    }

    /// Maximizes the window, or restores it: the opposite of what it is, or is on its way to.
    pub fn toggle(self: &Rc<Self>, window: &mut Window) {
        self.resize.set(None);
        self.pending.borrow_mut().toggle(window.is_maximized(), Instant::now());
        self.settle(self.committed.get(), window);
    }

    /// Restores a window that is maximized or on its way there, which takes `size` once it is restored: a size
    /// committed on a window still configured maximized is a protocol error on Wayland, which ends the connection.
    /// `false` for a window with nothing to restore, which the caller resizes itself.
    pub fn restore_to(self: &Rc<Self>, size: Size<Pixels>, window: &mut Window) -> bool {
        if self.pending.borrow().is_settled() && !window.is_maximized() {
            return false;
        }
        self.pending.borrow_mut().want(false, Instant::now());
        self.resize.set(Some(size));
        self.settle(self.committed.get(), window);
        true
    }

    /// The window's bounds changed, as a maximize changes them: settles once the frames committed it.
    pub fn bounds_changed(self: &Rc<Self>, window: &Window) {
        if self.pending.borrow().is_settled() && window.is_maximized() == self.committed.get() {
            return;
        }
        self.settle_after_a_frame(window);
    }

    /// Settles over two frames: the callbacks run as a frame starts, so the first one reads the maximize that frame
    /// commits, and the second one settles after it.
    fn settle_after_a_frame(self: &Rc<Self>, window: &Window) {
        let zoom = Rc::clone(self);
        window.on_next_frame(move |window, _| {
            let committed = zoom.frame_started(window);
            window.on_next_frame(move |window, _| zoom.settle(committed, window));
        });
    }

    /// A frame starts: the maximize it commits.
    fn frame_started(&self, window: &Window) -> bool {
        let committed = window.is_maximized();
        self.committed.set(committed);
        committed
    }

    fn settle(self: &Rc<Self>, committed: bool, window: &mut Window) {
        let maximized = window.is_maximized();
        let step = self.pending.borrow_mut().settle(committed, maximized, Instant::now());
        tracing::debug!(?step, committed, maximized, "window: zoom step");
        match step {
            None | Some(Settle::Wait) => {}
            Some(Settle::Done) => {
                tracing::info!(maximized, "window: zoom settled");
                if let Some(size) = self.resize.take() {
                    window.resize(size);
                }
            }
            Some(Settle::Again) => self.settle_after_a_frame(window),
            Some(Settle::Request) => {
                window.zoom_window();
                // macOS zooms within the call, and a zoom to the frame the window has changes no bounds
                if window.is_maximized() != maximized {
                    self.settle(committed, window);
                }
            }
        }
    }
}

#[cfg(test)]
#[path = "window_zoom/tests.rs"]
mod tests;
