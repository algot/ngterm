//! Reports the chat's Escape to the origin's pane-scoped status handler.

use std::path::PathBuf;
use std::process::ExitCode;

use ngterm_core::paths::Env;
use ngterm_proto::command::AgentCmd;
use ngterm_proto::{Args, Command, Request};

use crate::{Failure, TargetOptions, client, output, socket};

/// The chat sent Escape to this pane's running turn over its live attach.
#[derive(Debug, clap::Args)]
#[command(about = "Tell the instance chat Stop sent Escape to a running turn.")]
pub struct Interrupted {
    #[arg(long, help = "Which pane the agent runs in: left or right. Defaults to left.")]
    pane: Option<String>,

    #[command(flatten)]
    target: TargetOptions,

    #[arg(long, help = "Override the control socket path.")]
    socket: Option<PathBuf>,
}

impl Interrupted {
    pub(super) fn validate(&self) -> Result<(), String> {
        super::validate_pane_side(self.pane.as_deref())
    }

    pub(super) fn run(&self, env: &dyn Env) -> Result<(), Failure> {
        let request = Request {
            cmd: Command::Agent(AgentCmd::Interrupted),
            target: Some(self.target.target.clone()),
            args: Some(Args {
                pane: self.pane.clone(),
                ..Args::default()
            }),
        };
        let socket = socket::resolve(self.socket.as_deref(), env);
        let reply = client::send_within(&socket, &request, super::REPORT_DEADLINE)?;
        if reply.response.ok {
            return Ok(());
        }
        output::print_response(&reply, false, false);
        Err(Failure::Exit(ExitCode::FAILURE))
    }
}

#[cfg(test)]
mod tests {
    use clap::Parser as _;

    #[test]
    fn stop_accepts_only_a_session_pane() {
        for (flags, expected) in [
            (&[][..], Ok(())),
            (&["--pane", "right"][..], Ok(())),
            (
                &["--pane", "scratch"][..],
                Err("--pane must be left or right".to_owned()),
            ),
        ] {
            let argv = ["ngtermctl", "agent", "interrupted"].iter().chain(flags).copied();
            let parsed = crate::Ngtermctl::try_parse_from(argv).unwrap();
            let crate::Command::Agent(agent) = parsed.command else {
                panic!("not agent interrupted")
            };
            assert_eq!(agent.check(), expected);
        }
    }

    #[cfg(unix)]
    #[test]
    fn stop_names_its_pane_and_reports_a_refusal() {
        for (reply, result) in [
            (r#"{"ok":true,"result":{"id":"S"}}"#, "PROBE_RESULT:Ok(())"),
            (r#"{"ok":false,"error":"session missing"}"#, "PROBE_RESULT:Err(Exit("),
        ] {
            let (output, requests) = crate::messages::tests::run_command(
                &["agent", "interrupted", "--target", "S", "--pane", "right"],
                b"",
                &[],
                &[reply],
            );
            assert_eq!(
                requests,
                [serde_json::json!({"cmd": "agent.interrupted", "target": "S", "args": {"pane": "right"}})]
            );
            let printed = format!(
                "{}{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            assert!(printed.contains(result), "{printed}");
            if !reply.contains("true") {
                assert!(printed.contains("session missing"));
            }
        }
    }
}
