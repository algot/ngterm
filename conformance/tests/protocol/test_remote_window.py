"""A remote window mirrors a headless server's catalog over ssh, which the suite's no-network constraints exclude. What
an app with windows answers without one is tested here: the catalog commands and an operation id are the server's
alone, `window.remote.open` checks its host before any ssh, and the detach commands act only on a remote window's
rows. The module shares one instance and changes nothing in it."""

import pytest
from agterm_conformance.match import assert_error, assert_ok, find_session, session_ids, window_ids

UNKNOWN = "zzzz"
# The Rust build names its own headless server; the reference adapter's vocabulary words it as upstream's.
SERVER_ONLY = "{command} is served only by ngterm-headless"
RECEIPTS = "operation receipts are served only by ngterm-headless"

pytestmark = pytest.mark.since("0.42.0")


def _new(ctl):
    sid = assert_ok(ctl.request("session.new"))["id"]
    ctl.wait_mounted(sid, "left")
    return sid


def _server_only(ctl, command):
    return ctl.vocabulary.text(SERVER_ONLY.format(command=command))


@pytest.mark.covers("catalog.subscribe")
def test_catalog_subscribe_is_the_servers_alone(ctl):
    assert_error(ctl.request("catalog.subscribe"), _server_only(ctl, "catalog.subscribe"))


@pytest.mark.covers("catalog.op")
@pytest.mark.parametrize(
    ("target", "args", "error"),
    [
        pytest.param(None, {}, "catalog.op requires an operation id", id="no-id"),
        pytest.param("  ", {}, "catalog.op requires an operation id", id="blank-id"),
        pytest.param("a b", {}, "catalog.op requires an operation id", id="spaced-id"),
        pytest.param("x" * 129, {}, "catalog.op requires an operation id", id="long-id"),
        pytest.param("op-1", {"epoch": "E"}, "catalog.op takes epoch and rev together", id="epoch-alone"),
        pytest.param("op-1", {"rev": 3}, "catalog.op takes epoch and rev together", id="rev-alone"),
    ],
)
def test_catalog_op_checks_its_arguments_first(ctl, target, args, error):
    assert_error(ctl.request("catalog.op", target, **args), error)


@pytest.mark.covers("catalog.op")
@pytest.mark.parametrize("args", [{}, {"epoch": "E", "rev": 3}], ids=["id-alone", "with-position"])
def test_catalog_op_is_the_servers_alone(ctl, args):
    assert_error(ctl.request("catalog.op", "op-1", **args), _server_only(ctl, "catalog.op"))


@pytest.mark.covers("field:result.receipt", "session.rename", "workspace.new", "tree")
def test_an_operation_id_is_refused_and_nothing_runs(ctl):
    """Only a headless server keeps receipts: an app with windows refuses the id before the command runs, on any
    command, so no answer reads as a durable one."""
    sid = _new(ctl)
    before = ctl.tree()
    name = find_session(before, sid)["name"]
    for cmd, target, args in [
        ("session.rename", sid, {"name": "renamed"}),
        ("workspace.new", None, {"name": "made"}),
        ("tree", None, {}),
    ]:
        response = ctl.request(cmd, target, opID="op-1", epoch="E", **args)
        assert_error(response, ctl.vocabulary.text(RECEIPTS))
        assert response.result is None, response.raw
    after = ctl.tree()
    assert find_session(after, sid)["name"] == name
    assert session_ids(after) == session_ids(before)
    assert len(after["tree"]["workspaces"]) == len(before["tree"]["workspaces"])
    assert_ok(ctl.request("session.close", sid))


@pytest.mark.covers("window.remote.open")
@pytest.mark.parametrize(
    ("args", "error"),
    [
        pytest.param({}, "window.remote.open requires a host", id="no-host"),
        pytest.param({"host": "   "}, "window.remote.open requires a host", id="blank-host"),
        pytest.param({"host": "-oProxyCommand=x"}, "window.remote.open: not a host ssh can be given", id="option"),
        pytest.param({"host": "a b"}, "window.remote.open: not a host ssh can be given", id="spaced"),
    ],
)
def test_remote_open_checks_its_host_before_any_ssh(ctl, args, error):
    """A successful open runs ssh to a headless server, which the suite's no-network constraints exclude."""
    before = window_ids(ctl.request("window.list"))
    assert_error(ctl.request("window.remote.open", **args), error)
    assert window_ids(ctl.request("window.list")) == before


@pytest.mark.covers("window.remote.dismiss", "session.detach", "workspace.detach")
@pytest.mark.parametrize("cmd", ["window.remote.dismiss", "session.detach", "workspace.detach"])
def test_a_local_windows_rows_are_not_detached(ctl, cmd):
    before = session_ids(ctl.tree())
    assert_error(ctl.request(cmd, "active"), f"{cmd} acts only on a remote window")
    assert session_ids(ctl.tree()) == before


@pytest.mark.covers("session.detach")
def test_session_detach_resolves_its_targets_first(ctl):
    assert_error(ctl.request("session.detach", UNKNOWN), f"no such session: {UNKNOWN}")
    assert_error(ctl.request("session.detach", targets=[]), "session.detach requires at least one --target")


@pytest.mark.covers("workspace.detach")
def test_workspace_detach_resolves_its_target_first(ctl):
    assert_error(ctl.request("workspace.detach", UNKNOWN), f"no such workspace: {UNKNOWN}")


@pytest.mark.covers("session.reattach", "workspace.reattach")
@pytest.mark.parametrize(
    ("cmd", "noun"), [("session.reattach", "detached session"), ("workspace.reattach", "detached workspace")]
)
def test_a_reattach_names_a_detached_row(ctl, cmd, noun):
    """A hidden row is never `active`, and a local window has detached none."""
    needs_id = f"{cmd} requires a {noun}'s id"
    for target in (None, "active", "ACTIVE", "  "):
        assert_error(ctl.request(cmd, target), needs_id)
    assert_error(ctl.request(cmd, UNKNOWN), f"no such {noun}: {UNKNOWN}")
    (sid, *_rest) = session_ids(ctl.tree())
    assert_error(ctl.request(cmd, sid), f"no such {noun}: {sid}")
