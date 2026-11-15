//! One machine that runs both apps, and a server that views it. [`BothHost`] is a private `ngterm-headless` with the
//! stand-in agterm ([`StandIn`]) beside it, behind one `sshd`: a login there finds `ngtermctl` and `agtermctl`, so a
//! listing asks both. [`Viewer`] is a second private `ngterm-headless`, another server of the user's, whose `ssh`
//! knows the machine by a name ([`HOST`]): `ngtermctl live tree` and `live attach` on it reach the machine as they do
//! from any ngterm.
//!
//! Each instance has its own directory under the run's scratch directory (`b`, `v`), which the script's exit trap
//! reaps like the first test's.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use ngterm_mobile::KeyPair;
use ngterm_mobile::api::generate_key;

use crate::agterm::{StandIn, executable};
use crate::machine::{Headless, STAGE_VARIABLE, WORK_VARIABLE, account, quoted, text};
use crate::phone::{Listed, PRINTED, poll};
use crate::sshd::{Sshd, SshdSetup};

/// The name the viewer's `ssh` knows the machine by.
pub(crate) const HOST: &str = "e2e-both";
/// The session the machine's agterm is seeded with.
pub(crate) const AGTERM_SESSION: &str = "e2e-both-agterm";

/// The machine that runs both apps; torn down in reverse on drop.
pub(crate) struct BothHost {
    pub(crate) sshd: Sshd,
    pub(crate) headless: Headless,
    pub(crate) agterm: StandIn,
    pub(crate) key: KeyPair,
    /// Its host key: the public line and the fingerprint.
    pub(crate) host_key: KeyPair,
}

impl BothHost {
    pub(crate) fn start(binary: &Path) -> Self {
        let (stage, directory) = (stage(), work().join("b"));
        let user = account();
        let agterm = StandIn::lay_out(&directory.join("agterm"), AGTERM_SESSION);
        let headless = Headless::start(&stage, &directory, &user, Some(&agterm.bin()));
        let key = generate_key("ngterm-mobile e2e both".to_owned()).expect("a client key");
        let host_key = generate_key("ngterm-mobile e2e both host".to_owned()).expect("a host key");
        let force_command = headless.write_force_command(&directory);
        let sshd_directory = directory.join("sshd");
        fs::create_dir_all(&sshd_directory).expect("create the sshd directory");
        let sshd = Sshd::start(&SshdSetup {
            binary,
            directory: &sshd_directory,
            user: &user,
            host_key: &host_key.private_key,
            authorized_key: &key.authorized_key,
            force_command: &force_command,
        })
        .unwrap_or_else(|error| panic!("start the sshd of the machine that runs both: {error}"));
        Self {
            sshd,
            headless,
            agterm,
            key,
            host_key,
        }
    }
}

/// Another server of the user's, which reaches the machine over its own `ssh`.
pub(crate) struct Viewer {
    pub(crate) headless: Headless,
}

impl Viewer {
    /// Starts the server with an `ssh` that reads only the test's own config, where [`HOST`] is `host`.
    pub(crate) fn start(host: &BothHost) -> Self {
        let directory = work().join("v");
        let client = directory.join("ssh");
        let tools = client.join("bin");
        fs::create_dir_all(&tools).expect("create the viewer's ssh directory");
        let identity = client.join("id_ed25519");
        fs::write(&identity, &host.key.private_key).expect("write the viewer's key");
        fs::set_permissions(&identity, fs::Permissions::from_mode(0o600)).expect("keep the key private");
        let port = host.sshd.port();
        // the host key's `authorized_keys` line is `TYPE KEY COMMENT`; a `known_hosts` line takes the first two
        let public: Vec<&str> = host.host_key.authorized_key.split_whitespace().take(2).collect();
        let known_hosts = client.join("known_hosts");
        fs::write(&known_hosts, format!("[127.0.0.1]:{port} {}\n", public.join(" "))).expect("write known_hosts");
        let config = client.join("config");
        let settings = format!(
            "Host {HOST}\n  HostName 127.0.0.1\n  Port {port}\n  User {user}\n  IdentityFile \"{identity}\"\n  \
             IdentitiesOnly yes\n  UserKnownHostsFile \"{known_hosts}\"\n  GlobalKnownHostsFile /dev/null\n  \
             StrictHostKeyChecking yes\n",
            user = account(),
            identity = identity.display(),
            known_hosts = known_hosts.display(),
        );
        fs::write(&config, settings).expect("write the viewer's ssh config");
        // nothing of the account's `~/.ssh` or the system's ssh_config is read: `-F` names the only config
        let wrapper = format!(
            "#!/bin/sh\nexec {} -F {} \"$@\"\n",
            quoted(&ssh().display().to_string()),
            quoted(&config.display().to_string()),
        );
        executable(&tools.join("ssh"), &wrapper);
        let headless = Headless::start(&stage(), &directory, &account(), Some(&tools));
        Self { headless }
    }
}

fn stage() -> PathBuf {
    PathBuf::from(std::env::var_os(STAGE_VARIABLE).expect("MOBILE_E2E_STAGE: run the script"))
}

fn work() -> PathBuf {
    PathBuf::from(std::env::var_os(WORK_VARIABLE).expect("MOBILE_E2E_WORK: run the script"))
}

/// The system's `ssh`, which the viewer's instance runs.
fn ssh() -> PathBuf {
    ["/usr/bin/ssh", "/bin/ssh"]
        .iter()
        .map(PathBuf::from)
        .find(|path| path.exists())
        .expect("the viewer reaches the machine with ssh, in /usr/bin or /bin")
}

/// The session of `listed` named `name`.
pub(crate) fn named<'a>(listed: &'a [Listed], name: &str) -> &'a Listed {
    listed
        .iter()
        .find(|session| session.name == name)
        .unwrap_or_else(|| panic!("no session {name} in {listed:?}"))
}

/// The viewer's `ngtermctl live tree HOST`, in text and in JSON: ngterm's sessions, then agterm's under its header,
/// each app's with the endpoint its sessions attach through.
pub(crate) fn the_viewer_lists_both_apps(viewer: &Viewer, ngterm: &Listed, agterm: &Listed) {
    let printed = poll("the viewer's listing of both apps", || {
        viewer.headless.ctl(&["live", "tree", HOST]).ok()
    });
    let own = printed.find(&format!("[{}]", ngterm.id));
    let header = printed.find(&format!("agterm on {HOST}:"));
    let theirs = printed.find(&format!("[{}]", agterm.id));
    assert!(
        own.is_some() && own < header && header < theirs,
        "ngterm's sessions, agterm's header, then agterm's sessions:\n{printed}"
    );

    let json = viewer
        .headless
        .ctl(&["live", "tree", HOST, "--json"])
        .expect("the listing as JSON");
    let reply: serde_json::Value = serde_json::from_str(&json).expect("live tree's json");
    let remote = &reply["result"]["remote"];
    let names = |tree: &serde_json::Value| -> Vec<String> {
        let sessions = tree["sessions"].as_array().cloned().unwrap_or_default();
        sessions.iter().map(|session| text(&session["name"])).collect()
    };
    assert!(names(remote).contains(&ngterm.name), "{json}");
    assert!(!names(remote).contains(&agterm.name), "{json}");
    assert_eq!(names(&remote["beside"]), std::slice::from_ref(&agterm.name), "{json}");
    assert_eq!(remote["beside"]["endpoint"]["peer"], "agterm", "{json}");
    assert_eq!(remote["host"], HOST, "{json}");
    assert_eq!(remote["beside"]["host"], HOST, "{json}");
}

/// The viewer's `ngtermctl live attach HOST ID` of a session of each app: each becomes a session there, attached
/// through the app that listed it, and shows what its far side shows.
pub(crate) fn the_viewer_attaches_a_session_of_each_app(
    viewer: &Viewer,
    host: &BothHost,
    ngterm: &Listed,
    agterm: &Listed,
) {
    let attach = |session: &Listed| {
        let local = viewer
            .headless
            .ctl(&["live", "attach", HOST, &session.id])
            .unwrap_or_else(|error| panic!("attach {}: {error}", session.name));
        local.trim().to_owned()
    };
    let shows = |local: &str, needle: &str| {
        poll(&format!("{needle:?} in the viewer's session {local}"), || {
            let screen = viewer.headless.ctl(&["session", "text", "--target", local]).ok()?;
            screen.contains(needle).then_some(())
        });
    };
    let calls = host.agterm.zmx_calls().len();
    let local = attach(agterm);
    // agterm's own zmx attached it: nothing of ngterm's holds an agterm session
    poll("the attach through agterm's zmx", || {
        (host.agterm.zmx_calls().len() > calls).then_some(())
    });
    shows(&local, "agterm$");
    // what the phone ran in ngterm's session
    shows(&attach(ngterm), PRINTED);
}
