"""Window commands sent before the compositor presents the preceding change."""

import time

import pytest
from agterm_conformance.match import assert_ok
from agterm_conformance.wait import wait_until


def _window(ctl):
    (window,) = assert_ok(ctl.request("window.list"))["windows"]
    return window


def _rested(ctl, zoomed):
    since = None

    def stable():
        nonlocal since
        window = _window(ctl)
        if window.get("zoomed") is not zoomed:
            since = None
            assert window.get("zoomed") is zoomed, window
        elif since is None:
            since = time.monotonic()
        return since is not None and time.monotonic() - since >= 1.0

    wait_until(stable, timeout=10)


@pytest.mark.covers("window.zoom", "field:window.zoomed")
@pytest.mark.parametrize("gap_ms", [0, 4, 8, 12])
def test_fast_window_zoom_pair_restores_the_window(launch, gap_ms):
    ctl = launch()
    _rested(ctl, False)
    for _ in range(3):
        assert_ok(ctl.request("window.zoom"))
        if gap_ms:
            time.sleep(gap_ms / 1000)
        assert_ok(ctl.request("window.zoom"))
        _rested(ctl, False)


@pytest.mark.covers("window.zoom", "field:window.zoomed")
def test_five_window_zoom_toggles_preserve_the_last_requested_state(launch):
    ctl = launch()
    _rested(ctl, False)
    for expected in (True, False):
        for _ in range(5):
            assert_ok(ctl.request("window.zoom"))
        _rested(ctl, expected)


@pytest.mark.covers("window.zoom", "window.resize", "field:window.zoomed", "field:window.geometry")
@pytest.mark.parametrize("wait_for_zoom", [False, True], ids=["pending-zoom", "presented-zoom"])
def test_window_resize_restores_a_zoomed_window(launch, adapter, wait_for_zoom):
    ctl = launch()
    _rested(ctl, False)
    assert_ok(ctl.request("window.zoom"))
    if wait_for_zoom:
        _rested(ctl, True)
    assert_ok(ctl.request("window.resize", width=900, height=600))
    _rested(ctl, False)
    if adapter.has("window-geometry"):
        geometry = _window(ctl)["geometry"]
        assert (geometry["width"], geometry["height"]) == (900, 600)
