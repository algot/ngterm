//! The e2e test's steps, in the order the test runs them.

use std::time::Duration;

use ngterm_mobile::{MachineState, PaneRole};

use crate::machine::World;
use crate::phone::{Client, GRID, MACHINE_ID, PRINTED, block_on, enter, nanos, poll};
use crate::sshd::Proxy;

/// The line typed into an agterm pane, and what it prints, which the line itself doesn't hold.
const AGTERM_TYPED: &str = "echo typed-$((6*7))-on-agterm";
const AGTERM_PRINTED: &str = "typed-42-on-agterm";

/// How long a client listens for events a step should not have caused.
const SETTLE: Duration = Duration::from_millis(500);

/// The marker session made through the private instance's own socket is the only one `live tree` lists over the
/// `sshd`: the ssh side reaches the private instance and nothing else. Answers the marker's name.
pub(crate) fn assert_isolated(world: &World, client: &Client) -> String {
    let marker = format!("e2e-marker-{}-{}", std::process::id(), nanos());
    let output = world
        .headless
        .ctl(&["session", "new", "--no-select", &format!("--name={marker}")])
        .expect("create the marker session");
    let marker_id = output.trim().to_owned();
    // the instance starts with a session of its own; only the marker may stay
    for (id, _) in world.headless.tree() {
        if !id.eq_ignore_ascii_case(&marker_id) {
            world
                .headless
                .ctl(&["session", "close", "--target", &id])
                .expect("close the instance's first session");
        }
    }
    let only_marker = |listed: &[(String, String)]| listed.len() == 1 && listed[0].1 == marker;
    poll("the private tree holding only the marker", || {
        only_marker(&world.headless.tree()).then_some(())
    });
    let listed = poll("the marker over ssh", || {
        let listed = client.list();
        (!listed.is_empty()).then_some(listed)
    });
    assert!(
        only_marker(&listed),
        "live tree over ssh lists {listed:?}, not just {marker}"
    );
    marker
}

/// Creates a session through the core, attaches it, shows its pane and runs a line in it. Answers the session's id.
pub(crate) fn create_and_read(client: &mut Client) -> String {
    let session = block_on(
        client
            .core
            .create_session(MACHINE_ID.to_owned(), Some("e2e-work".to_owned())),
    )
    .expect("create a session");
    assert_eq!(session.name, "e2e-work");
    block_on(client.core.attach_session(MACHINE_ID.to_owned(), session.id.clone())).expect("attach the session");
    let layout = client.wait_layout();
    let pane = block_on(
        client
            .core
            .show_pane(MACHINE_ID.to_owned(), session.id.clone(), layout.primary.clone(), GRID),
    )
    .expect("show the pane");
    client.pane = Some(layout.primary.clone());
    client.wait("the pane attached", |seen| seen.attached >= 1);
    client.wait("a role", |seen| seen.role.is_some());
    // the machine's own terminal of the pane attached first and leads; a follower's typing is dropped
    if client.seen.role != Some(PaneRole::Leader) {
        client.take_lead(&session.id, &layout.primary);
    }
    client.terminal = Some(pane);
    client.run_line();
    session.id
}

/// A second client of the same pane follows the one that leads; Take control turns the roles round.
pub(crate) fn leadership(first: &mut Client, second: &mut Client, session: &str, pane: &str) {
    first.wait("the first client leading", |seen| seen.role == Some(PaneRole::Leader));
    let roles = first.seen.roles.len();
    assert!(!second.list().is_empty());
    let shown = block_on(
        second
            .core
            .show_pane(MACHINE_ID.to_owned(), session.to_owned(), pane.to_owned(), GRID),
    )
    .expect("show the pane on the second client");
    second.terminal = Some(shown);
    second.wait("the second client following", |seen| {
        seen.role == Some(PaneRole::Follower)
    });
    second.wait_screen(PRINTED);
    // a lead the second attach took from the first would reach the first as its own event
    first.settle(SETTLE);
    assert!(
        first.seen.roles[roles..]
            .iter()
            .all(|role| *role == Some(PaneRole::Leader)),
        "the first client lost the lead to a follower's attach: {:?}",
        &first.seen.roles[roles..]
    );
    assert_eq!(first.seen.role, Some(PaneRole::Leader));

    first.drain();
    let roles = first.seen.roles.len();
    second.take_lead(session, pane);
    first.wait("the first client following", |seen| {
        seen.roles[roles..].contains(&Some(PaneRole::Follower))
    });
}

/// The client's link drops under it; it reconnects on its own and draws the same screen in a fresh terminal.
pub(crate) fn reconnect(client: &mut Client, proxy: &Proxy) {
    client.drain();
    let (lost, attached) = (client.seen.lost, client.seen.attached);
    client.seen.states.clear();
    proxy.sever();
    client.wait("the lost pane", |seen| seen.lost > lost);
    client.wait("a reconnect", |seen| {
        seen.states
            .iter()
            .any(|state| matches!(state, MachineState::Reconnecting { .. }))
    });
    client.wait("the machine connected again", |seen| {
        seen.states.last() == Some(&MachineState::Connected)
    });
    client.wait("the pane attached again", |seen| seen.attached > attached);
    client.wait_screen(PRINTED);
}

/// Attaches agterm's session `session`, whose pane agterm's own window leads: the pane follows and is covered, what is
/// typed while it follows never reaches the session, and Take control makes the typed line run.
pub(crate) fn type_into_agterm_after_taking_control(phone: &mut Client, session: &str) {
    block_on(phone.core.attach_session(MACHINE_ID.to_owned(), session.to_owned())).expect("attach the session");
    let pane = phone.wait_layout().primary;
    let shown = block_on(
        phone
            .core
            .show_pane(MACHINE_ID.to_owned(), session.to_owned(), pane.clone(), GRID),
    )
    .expect("show the pane");
    phone.terminal = Some(shown.clone());
    // agterm's own window leads: the pane must say so and be covered, where Take control is offered
    phone.wait("the pane following agterm's window", |seen| {
        seen.role == Some(PaneRole::Follower) && seen.covered
    });
    phone.wait_screen("agterm$");

    // zmx drops what a follower sends
    assert!(shown.type_text(AGTERM_TYPED.to_owned()).expect("type"));
    assert!(shown.key(enter()).expect("press enter"));
    let dropped = phone.screen_shows("typed", Duration::from_secs(2));
    assert!(dropped.is_err(), "a follower's typing reached the agterm session");

    phone.take_lead(session, &pane);
    assert!(!phone.seen.covered, "the pane is still covered after it took the lead");
    let leading = phone.terminal.clone().expect("the pane");
    phone.wait_screen("agterm$");
    assert!(leading.type_text(AGTERM_TYPED.to_owned()).expect("type"));
    assert!(leading.key(enter()).expect("press enter"));
    phone.wait_screen(AGTERM_PRINTED);
}
