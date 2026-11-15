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
//! it.
//!
//! No platform answers within the call, and an answer need not change the window's bounds (a window already the
//! size of its maximize), so a request sent is looked at ([`watch`]) every [`LOOK`]: an answer settles again. A
//! window manager may never answer (X11 without one, a tiling compositor that refuses a maximize): a request the
//! window's maximize still reads unchanged for after [`UNANSWERED`] is forgotten, and the next one goes out as the
//! first did. A request answered whose frames are still to come is kept, however long they take.

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Duration;

use gpui_kit::{App, Pixels, Size, Window};

/// How long a request's answer is waited for before it counts as never coming.
pub const UNANSWERED: Duration = Duration::from_secs(1);

/// How often a request sent is looked at for its answer.
const LOOK: Duration = Duration::from_millis(50);

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

/// What a look at a request sent finds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Watch {
    /// The request is settled or another one went out since: nothing left to look at.
    Over,
    /// No answer yet.
    Wait,
    /// The window's maximize changed, seen for the first time: settle again.
    Answered,
    /// No answer came in time: the request is forgotten.
    Unanswered,
}

/// A window's zoom requests: the one being settled and how many went out.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Pending {
    request: Option<ZoomRequest>,
    sends: u64,
    /// The send whose answer a look reported.
    answered: u64,
}

impl Pending {
    #[must_use]
    pub fn is_settled(&self) -> bool {
        self.request.is_none()
    }

    /// How many requests went out: the last one's name for [`watch`](Self::watch).
    #[must_use]
    pub fn sends(&self) -> u64 {
        self.sends
    }

    /// The opposite of what the window is to be: of the request being settled, else of its `maximized`.
    pub fn toggle(&mut self, maximized: bool) {
        let wanted = !self.request.map_or(maximized, |request| request.wanted);
        self.want(wanted);
    }

    /// The window is to be `wanted`.
    pub fn want(&mut self, wanted: bool) {
        match &mut self.request {
            Some(request) => request.want(wanted),
            None => self.request = Some(ZoomRequest::new(wanted)),
        }
    }

    /// [`ZoomRequest::settle`] for the request being settled, `None` with none.
    pub fn settle(&mut self, committed: bool, maximized: bool) -> Option<Settle> {
        let step = self.request.as_mut()?.settle(committed, maximized);
        match step {
            Settle::Done => self.request = None,
            Settle::Request => self.sends += 1,
            Settle::Wait | Settle::Again => {}
        }
        Some(step)
    }

    /// A look at the request that went out as `send`, the window reading `maximized`; the `last` look forgets a
    /// request with no answer.
    pub fn watch(&mut self, send: u64, maximized: bool, last: bool) -> Watch {
        let in_flight = self.request.and_then(|request| request.sent_from);
        match in_flight {
            Some(from) if send == self.sends => {
                if from != maximized {
                    if std::mem::replace(&mut self.answered, send) == send {
                        Watch::Wait
                    } else {
                        Watch::Answered
                    }
                } else if last {
                    self.request = None;
                    Watch::Unanswered
                } else {
                    Watch::Wait
                }
            }
            _ => Watch::Over,
        }
    }
}

/// Looks at a request just sent every [`LOOK`] while `look` asks for more; it is told which look is the last,
/// [`UNANSWERED`] after the request.
pub(crate) fn watch(window: &Window, cx: &App, mut look: impl FnMut(bool, &mut Window, &mut App) -> bool + 'static) {
    window
        .spawn(cx, async move |cx| {
            let looks = UNANSWERED.as_millis() / LOOK.as_millis();
            for nth in 1..=looks {
                cx.background_executor().timer(LOOK).await;
                if !cx.update(|window, cx| look(nth == looks, window, cx)).unwrap_or(false) {
                    return;
                }
            }
        })
        .detach();
}

/// A main window's zoom: its requests, the maximize its last drawn frame committed, and the size it takes once it
/// rests restored.
#[derive(Debug)]
pub struct WindowZoom {
    pending: RefCell<Pending>,
    committed: Cell<bool>,
    resize: Cell<Option<Size<Pixels>>>,
    request: fn(&mut Window),
}

impl WindowZoom {
    #[must_use]
    pub fn new(window: &Window) -> Rc<Self> {
        Self::requesting(window, |window| window.zoom_window())
    }

    /// A zoom that asks the window manager through `request`: the test window panics when asked to maximize.
    fn requesting(window: &Window, request: fn(&mut Window)) -> Rc<Self> {
        Rc::new(Self {
            pending: RefCell::default(),
            committed: Cell::new(window.is_maximized()),
            resize: Cell::new(None),
            request,
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

    /// Maximizes the window, or restores it: the opposite of what it is, or is on its way to. A size that waits for
    /// the window's restore keeps waiting for it.
    pub fn toggle(self: &Rc<Self>, window: &mut Window, cx: &mut App) {
        self.pending.borrow_mut().toggle(window.is_maximized());
        self.settle(self.committed.get(), window, cx);
    }

    /// Restores a window that is maximized or on its way there, which takes `size` once it rests restored: a size
    /// committed on a window still configured maximized is a protocol error on Wayland, which ends the connection,
    /// and a size given on the way to another maximize is not the one GPUI's Wayland window restores to. `false` for
    /// a window with nothing to restore, which the caller resizes itself.
    pub fn restore_to(self: &Rc<Self>, size: Size<Pixels>, window: &mut Window, cx: &mut App) -> bool {
        if self.pending.borrow().is_settled() && !window.is_maximized() {
            self.resize.set(None);
            return false;
        }
        self.pending.borrow_mut().want(false);
        self.resize.set(Some(size));
        self.settle(self.committed.get(), window, cx);
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
            window.on_next_frame(move |window, cx| zoom.settle(committed, window, cx));
        });
    }

    /// A frame starts: the maximize it commits.
    fn frame_started(&self, window: &Window) -> bool {
        let committed = window.is_maximized();
        self.committed.set(committed);
        committed
    }

    fn settle(self: &Rc<Self>, committed: bool, window: &mut Window, cx: &mut App) {
        let maximized = window.is_maximized();
        let step = self.pending.borrow_mut().settle(committed, maximized);
        tracing::debug!(?step, committed, maximized, "window: zoom step");
        match step {
            Some(Settle::Wait) => {}
            None => self.rest(window),
            Some(Settle::Done) => {
                tracing::info!(maximized, "window: zoom settled");
                self.rest(window);
            }
            Some(Settle::Again) => self.settle_after_a_frame(window),
            Some(Settle::Request) => {
                (self.request)(window);
                let (zoom, send) = (Rc::clone(self), self.pending.borrow().sends());
                watch(window, cx, move |last, window, _| zoom.look(send, last, window));
            }
        }
    }

    /// A look at the request sent as `send`; whether it is to be looked at again.
    fn look(self: &Rc<Self>, send: u64, last: bool, window: &mut Window) -> bool {
        let maximized = window.is_maximized();
        let watch = self.pending.borrow_mut().watch(send, maximized, last);
        match watch {
            Watch::Over => false,
            Watch::Wait => true,
            Watch::Answered => {
                self.settle_after_a_frame(window);
                true
            }
            Watch::Unanswered => {
                tracing::info!(maximized, "window: zoom request unanswered");
                self.rest(window);
                false
            }
        }
    }

    /// No request is left: a window restored takes the size that waited for it. A window maximized keeps it for
    /// its next restore, the window manager's own included.
    fn rest(&self, window: &mut Window) {
        if !window.is_maximized()
            && let Some(size) = self.resize.take()
        {
            window.resize(size);
        }
    }
}

#[cfg(test)]
#[path = "window_zoom/tests.rs"]
mod tests;
