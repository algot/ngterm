//! `ngtermctl server install` (`agtermctlKit/ServerCommands.swift` `Server`): installs `ngterm-headless` on a Linux
//! host over ssh. Local-only, as `terminfo install`: it never opens the control socket, so it has no `--socket` or
//! `--json`. The installer itself is not in this build yet: the command parses, checks its destination and refuses.

use crate::Failure;
use crate::terminfo::{Connection, install_command};

/// The refusal of every run until the installer lands.
pub const NOT_SUPPORTED: &str = "server install is not supported by this build";

/// `ngtermctl server <subcommand>`.
#[derive(Debug, clap::Args)]
#[command(
    about = "ngterm-headless on Linux hosts.",
    subcommand_required = true,
    arg_required_else_help = true
)]
pub struct Server {
    #[command(subcommand)]
    command: ServerCommand,
}

/// The subcommands, in upstream's `Server.configuration.subcommands` order.
#[derive(Debug, clap::Subcommand)]
enum ServerCommand {
    Install(Install),
}

impl Server {
    /// Runs the command.
    pub fn execute(&self) -> Result<(), Failure> {
        match &self.command {
            ServerCommand::Install(command) => command.run().map_err(Failure::Local),
        }
    }
}

/// `ngtermctl server install [-p <port>] [-i <file> ...] [-J <host>] [-F <file>] [--from <file>] <destination>`.
#[derive(Debug, clap::Args)]
#[command(about = "Install or upgrade ngterm-headless on a Linux host over ssh.")]
pub struct Install {
    #[arg(help = "The host, as ssh would take it: host, user@host, or an alias from ~/.ssh/config.")]
    destination: String,

    #[arg(short = 'p', value_name = "port", help = "Port to connect to on the remote host.")]
    port: Option<i64>,

    #[arg(
        short = 'i',
        value_name = "file",
        action = clap::ArgAction::Append,
        help = "Identity file for public key authentication. Repeat to offer several."
    )]
    identity: Vec<String>,

    #[arg(short = 'J', value_name = "host", help = "Jump host, as ssh -J takes it.")]
    jump: Option<String>,

    #[arg(short = 'F', value_name = "file", help = "Per-user ssh configuration file.")]
    config: Option<String>,

    #[arg(
        long = "from",
        value_name = "file",
        help = "Use a tarball already on this Mac instead of downloading one; it must still match this app's sha256."
    )]
    source: Option<String>,
}

impl Install {
    fn connection(&self) -> Connection {
        Connection {
            destination: self.destination.clone(),
            port: self.port,
            identities: self.identity.clone(),
            jump: self.jump.clone(),
            config: self.config.clone(),
        }
    }

    /// A bad destination is a refusal with exit 1 like every other, so it is checked in the run, not as a usage error
    /// (upstream's `ServerInstaller.install`).
    fn run(&self) -> Result<(), String> {
        if install_command(&self.connection(), "ssh").is_err() {
            return Err(format!(
                "destination must be a host, user@host or an ssh alias, not '{}'",
                self.destination
            ));
        }
        Err(NOT_SUPPORTED.to_owned())
    }
}

#[cfg(test)]
mod tests {
    use clap::Parser;

    use crate::Ngtermctl;

    fn run(argv: &[&str]) -> Result<(), String> {
        let command_line = ["ngtermctl", "server", "install"].iter().chain(argv).copied();
        let parsed = Ngtermctl::try_parse_from(command_line).unwrap();
        assert_eq!(parsed.command.validate(), Ok(()));
        let crate::Command::Server(group) = parsed.command else {
            panic!("not a server command")
        };
        let super::ServerCommand::Install(install) = &group.command;
        install.run()
    }

    /// Upstream's `ServerCommandsTests`: a destination ssh would read as an option, or one with a space, is named.
    #[test]
    fn a_bad_destination_is_refused_by_name_before_anything_runs() {
        for bad in ["-oProxyCommand=x", "a b", ""] {
            assert_eq!(
                run(&["--", bad]),
                Err(format!(
                    "destination must be a host, user@host or an ssh alias, not '{bad}'"
                )),
                "{bad:?}"
            );
        }
    }

    #[test]
    fn a_good_destination_is_refused_until_the_installer_lands() {
        let options = [
            "-p", "2222", "-i", "a", "-i", "b", "-J", "jump", "-F", "cfg", "--from", "t.tgz",
        ];
        for argv in [&["buildbox"][..], &[&options[..], &["me@buildbox"]].concat()] {
            assert_eq!(
                run(argv),
                Err("server install is not supported by this build".to_owned()),
                "{argv:?}"
            );
        }
    }
}
