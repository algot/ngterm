//! `ngtermctl agent answered`: a viewer's word that it answered a pane's permission dialog itself, which the Android
//! app runs on the origin under its ssh once its approval card's key is seen to have closed the dialog. Claude Code
//! has no hook for an answered prompt, so without it the pane would stay `blocked` until the approved call ends. It
//! sends `agent.answered`; the origin changes nothing when the prompt is over already or is another one.

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use ngterm_core::paths::Env;
use ngterm_proto::command::AgentCmd;
use ngterm_proto::{Args, Command, Request};

use crate::{Failure, TargetOptions, client, output, socket};

/// The most the call waits, its reply included: the viewer's action waits on it.
const DEADLINE: Duration = Duration::from_secs(5);

/// `ngtermctl agent answered`: the pane's permission prompt was answered on its dialog.
#[derive(Debug, clap::Args)]
#[command(
    about = "Tell the instance a pane's permission prompt was answered on its dialog.",
    long_about = "Run by the Android app after its approval card answered the agent's dialog: while the prompt named \
                  is still the pane's live one, the pane's status leaves blocked for active (--working: the agent's \
                  turn runs on) or idle (its prompt is back), which ends the prompt in every chat. A prompt that is \
                  over, or another one, changes nothing. Prints nothing on success."
)]
pub struct Answered {
    #[arg(long, help = "The prompt's id, as its `approval` chat event carries it.")]
    approval: String,

    #[arg(long, help = "The agent's turn runs on: the status becomes active instead of idle.")]
    working: bool,

    #[arg(long, help = "Which pane the agent runs in: left or right. Defaults to left.")]
    pane: Option<String>,

    #[command(flatten)]
    target: TargetOptions,

    #[arg(long, help = "Override the control socket path.")]
    socket: Option<PathBuf>,
}

impl Answered {
    pub(super) fn validate(&self) -> Result<(), String> {
        super::validate_pane_side(self.pane.as_deref())
    }

    pub(super) fn run(&self, env: &dyn Env) -> Result<(), Failure> {
        let socket = socket::resolve(self.socket.as_deref(), env);
        let reply = client::send_within(&socket, &self.request(), DEADLINE)?;
        if reply.response.ok {
            return Ok(());
        }
        output::print_response(&reply, false, false);
        Err(Failure::Exit(ExitCode::FAILURE))
    }

    fn request(&self) -> Request {
        Request {
            cmd: Command::Agent(AgentCmd::Answered),
            target: Some(self.target.target.clone()),
            args: Some(Args {
                pane: self.pane.clone(),
                approval: Some(self.approval.clone()),
                status: Some(if self.working { "active" } else { "idle" }.to_owned()),
                ..Args::default()
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use clap::Parser as _;

    use super::*;
    use crate::agent::{Agent, AgentCommand};
    use crate::{Command as Cli, Ngtermctl};

    fn answered(argv: &[&str]) -> Answered {
        let argv = ["ngtermctl", "agent", "answered"].iter().chain(argv).copied();
        match Ngtermctl::try_parse_from(argv).expect("parses").command {
            Cli::Agent(Agent {
                command: AgentCommand::Answered(answered),
            }) => answered,
            _ => panic!("not agent answered"),
        }
    }

    #[test]
    fn only_the_left_or_the_right_pane_holds_a_prompt() {
        assert_eq!(
            answered(&["--approval", "a", "--pane", "scratch"]).validate(),
            Err("--pane must be left or right".to_owned())
        );
        assert_eq!(answered(&["--approval", "a", "--pane", "right"]).validate(), Ok(()));
        assert_eq!(answered(&["--approval", "a"]).validate(), Ok(()));
    }

    #[cfg(unix)]
    fn said(output: &std::process::Output) -> String {
        format!(
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )
    }

    #[cfg(unix)]
    #[test]
    fn it_sends_the_prompt_and_the_status_the_screen_showed() {
        for (flags, status) in [(&["--working"][..], "active"), (&[][..], "idle")] {
            let argv = [
                &[
                    "agent",
                    "answered",
                    "--target",
                    "S",
                    "--pane",
                    "right",
                    "--approval=approval-1.5",
                ],
                flags,
            ]
            .concat();
            let (output, requests) =
                crate::messages::tests::run_command(&argv, b"", &[], &[r#"{"ok":true,"result":{"id":"S"}}"#]);
            assert_eq!(
                requests,
                [serde_json::json!({
                    "cmd": "agent.answered",
                    "target": "S",
                    "args": {"pane": "right", "approval": "approval-1.5", "status": status},
                })]
            );
            assert!(said(&output).contains("PROBE_RESULT:Ok(())"), "{output:?}");
        }
    }

    #[cfg(unix)]
    #[test]
    fn a_refusal_is_printed_and_fails() {
        let (output, _) = crate::messages::tests::run_command(
            &["agent", "answered", "--target", "S", "--approval", "approval-1"],
            b"",
            &[],
            &[r#"{"ok":false,"error":"session not found: S"}"#],
        );
        let said = said(&output);
        assert!(said.contains("session not found: S"), "{said}");
        assert!(said.contains("PROBE_RESULT:Err(Exit("), "{said}");
    }
}
