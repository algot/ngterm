//! Detach and reattach, a remote window's rows (`agtermctlKit/DetachCommands.swift`): `session detach|reattach`,
//! `workspace detach|reattach` and `window remote dismiss`. A detached row is hidden here and left running on its
//! server.

use ngterm_proto::command::{SessionCmd, WindowCmd, WorkspaceCmd};
use ngterm_proto::{Args, Command, Request};

use crate::session::session_request;
use crate::{BasicOptions, BatchTargetOptions, ClientOptions, RequestCommand, TargetOptions};

/// The `--target` of a reattach (upstream's `DetachedTargetOptions`): a hidden row has no `active`, so it is named by
/// a detached id or a unique prefix of one.
#[derive(Debug, clap::Args)]
struct DetachedTargetOptions {
    #[arg(
        long,
        help = "Detached id or unique prefix, as tree's remote.detachedSessions / detachedWorkspaces list it."
    )]
    target: String,
}

impl DetachedTargetOptions {
    fn validate(&self) -> Result<(), String> {
        if self.target.eq_ignore_ascii_case("active") {
            Err("a detached row is never 'active'; pass its id".to_owned())
        } else {
            Ok(())
        }
    }
}

/// `ngtermctl session detach`: one session, or a batch with a repeated `--target`.
#[derive(Debug, clap::Args)]
#[command(
    name = "detach",
    about = "Hide a remote window's sessions on this Mac and leave them running on the server.",
    long_about = "A parent takes its companions with it. Reattach brings a session back; session close ends it."
)]
pub struct SessionDetach {
    #[command(flatten)]
    target: BatchTargetOptions,

    #[command(flatten)]
    options: ClientOptions,
}

impl RequestCommand for SessionDetach {
    fn options(&self) -> &BasicOptions {
        &self.options.basic
    }

    fn make_request(&self) -> Request {
        let args = self.target.batch().map(|targets| Args {
            targets: Some(targets),
            ..Args::default()
        });
        session_request(SessionCmd::Detach, Some(self.target.first()), args, &self.options)
    }
}

/// `ngtermctl session reattach --target ID`.
#[derive(Debug, clap::Args)]
#[command(name = "reattach", about = "Show a detached session of a remote window again.")]
pub struct SessionReattach {
    #[command(flatten)]
    target: DetachedTargetOptions,

    #[command(flatten)]
    options: ClientOptions,
}

impl RequestCommand for SessionReattach {
    fn options(&self) -> &BasicOptions {
        &self.options.basic
    }

    fn validate(&self) -> Result<(), String> {
        self.target.validate()
    }

    fn make_request(&self) -> Request {
        session_request(
            SessionCmd::Reattach,
            Some(self.target.target.clone()),
            None,
            &self.options,
        )
    }
}

/// A request for a workspace `cmd` on `target` (`--window` folded in).
fn workspace_request(cmd: WorkspaceCmd, target: &str, options: &ClientOptions) -> Request {
    Request {
        cmd: Command::Workspace(cmd),
        target: Some(target.to_owned()),
        args: options.with_window(None),
    }
}

/// `ngtermctl workspace detach`.
#[derive(Debug, clap::Args)]
#[command(
    name = "detach",
    about = "Hide a remote window's workspace and its sessions on this Mac, leaving them running on the server."
)]
pub struct WorkspaceDetach {
    #[command(flatten)]
    target: TargetOptions,

    #[command(flatten)]
    options: ClientOptions,
}

impl RequestCommand for WorkspaceDetach {
    fn options(&self) -> &BasicOptions {
        &self.options.basic
    }

    fn make_request(&self) -> Request {
        workspace_request(WorkspaceCmd::Detach, &self.target.target, &self.options)
    }
}

/// `ngtermctl workspace reattach --target ID`.
#[derive(Debug, clap::Args)]
#[command(name = "reattach", about = "Show a detached workspace of a remote window again.")]
pub struct WorkspaceReattach {
    #[command(flatten)]
    target: DetachedTargetOptions,

    #[command(flatten)]
    options: ClientOptions,
}

impl RequestCommand for WorkspaceReattach {
    fn options(&self) -> &BasicOptions {
        &self.options.basic
    }

    fn validate(&self) -> Result<(), String> {
        self.target.validate()
    }

    fn make_request(&self) -> Request {
        workspace_request(WorkspaceCmd::Reattach, &self.target.target, &self.options)
    }
}

/// `ngtermctl window remote dismiss [<id>]`.
#[derive(Debug, clap::Args)]
#[command(
    name = "dismiss",
    about = "Drop a remote window's marks for actions whose outcome it could not learn."
)]
pub struct RemoteDismiss {
    #[arg(default_value = "active", help = "Window id, unique prefix, or 'active'.")]
    id: String,

    #[command(flatten)]
    options: BasicOptions,
}

impl RequestCommand for RemoteDismiss {
    fn options(&self) -> &BasicOptions {
        &self.options
    }

    fn make_request(&self) -> Request {
        Request {
            cmd: Command::Window(WindowCmd::RemoteDismiss),
            target: Some(self.id.clone()),
            args: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use clap::Parser;
    use serde_json::{Value, json};

    use crate::{Command as Cli, Ngtermctl};

    /// `ngtermctl <argv>` parsed and validated: the request it sends as JSON, or the validation refusal.
    fn outcome(argv: &[&str]) -> Result<Value, String> {
        let command_line = std::iter::once("ngtermctl").chain(argv.iter().copied());
        let parsed = Ngtermctl::try_parse_from(command_line).unwrap();
        let command = match &parsed.command {
            Cli::Session(group) => group.command(),
            Cli::Workspace(group) => group.command(),
            Cli::Window(group) => group.command(),
            other => panic!("not a detach command: {other:?}"),
        };
        command.validate()?;
        Ok(serde_json::to_value(command.make_request()).unwrap())
    }

    /// Upstream's `DetachCommandsTests`: one target is the request's own, a batch also rides in `targets`.
    #[test]
    fn session_detach_sends_one_target_or_a_batch() {
        assert_eq!(
            outcome(&["session", "detach"]),
            Ok(json!({"cmd": "session.detach", "target": "active"}))
        );
        assert_eq!(
            outcome(&["session", "detach", "--target", "a", "--window", "w"]),
            Ok(json!({"cmd": "session.detach", "target": "a", "args": {"window": "w"}}))
        );
        assert_eq!(
            outcome(&["session", "detach", "--target", "a", "--target", "b"]),
            Ok(json!({"cmd": "session.detach", "target": "a", "args": {"targets": ["a", "b"]}}))
        );
    }

    #[test]
    fn workspace_detach_sends_its_target() {
        assert_eq!(
            outcome(&["workspace", "detach"]),
            Ok(json!({"cmd": "workspace.detach", "target": "active"}))
        );
        assert_eq!(
            outcome(&["workspace", "detach", "--target", "w1", "--window", "w"]),
            Ok(json!({"cmd": "workspace.detach", "target": "w1", "args": {"window": "w"}}))
        );
    }

    #[test]
    fn a_reattach_names_a_detached_row_never_active() {
        for (group, cmd) in [("session", "session.reattach"), ("workspace", "workspace.reattach")] {
            assert_eq!(
                outcome(&[group, "reattach", "--target", "ab12"]),
                Ok(json!({"cmd": cmd, "target": "ab12"}))
            );
            assert_eq!(
                outcome(&[group, "reattach", "--target", "ab12", "--window", "w"]),
                Ok(json!({"cmd": cmd, "target": "ab12", "args": {"window": "w"}}))
            );
            for active in ["active", "ACTIVE"] {
                assert_eq!(
                    outcome(&[group, "reattach", "--target", active]),
                    Err("a detached row is never 'active'; pass its id".to_owned())
                );
            }
            // the target is required: a hidden row has no default
            let bare = ["ngtermctl", group, "reattach"];
            assert!(Ngtermctl::try_parse_from(bare).is_err(), "{group}");
        }
    }

    #[test]
    fn window_remote_dismiss_targets_a_window() {
        assert_eq!(
            outcome(&["window", "remote", "dismiss"]),
            Ok(json!({"cmd": "window.remote.dismiss", "target": "active"}))
        );
        assert_eq!(
            outcome(&["window", "remote", "dismiss", "ab12"]),
            Ok(json!({"cmd": "window.remote.dismiss", "target": "ab12"}))
        );
    }

    #[test]
    fn window_remote_open_sends_its_host_and_echoes_the_window() {
        assert_eq!(
            outcome(&["window", "remote", "open", "me@box"]),
            Ok(json!({"cmd": "window.remote.open", "args": {"host": "me@box"}}))
        );
        let parsed = Ngtermctl::try_parse_from(["ngtermctl", "window", "remote", "open", "box"]).unwrap();
        let Cli::Window(group) = &parsed.command else {
            panic!("not a window command")
        };
        assert!(group.command().echoes_result_id());
        assert!(Ngtermctl::try_parse_from(["ngtermctl", "window", "remote", "open"]).is_err());
    }
}
