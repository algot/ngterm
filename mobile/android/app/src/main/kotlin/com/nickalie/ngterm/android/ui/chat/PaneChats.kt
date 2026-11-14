package com.nickalie.ngterm.android.ui.chat

import com.nickalie.ngterm.android.data.ChatViews
import com.nickalie.ngterm.android.data.Connections
import com.nickalie.ngterm.android.data.LiveSession
import com.nickalie.ngterm.android.data.LiveSessions
import com.nickalie.ngterm.android.data.MachinePeer
import com.nickalie.ngterm.android.data.PaneAgent
import com.nickalie.ngterm.android.data.SessionChatViews
import com.nickalie.ngterm.android.data.SessionKey
import com.nickalie.ngterm.android.data.offersChat
import com.nickalie.ngterm.android.data.session
import com.nickalie.ngterm.android.ui.terminal.TerminalState
import com.nickalie.ngterm.android.ui.theme.AgentState
import com.nickalie.ngterm.core.ffi.AgentCommand
import com.nickalie.ngterm.core.ffi.AgentInputOutcome
import com.nickalie.ngterm.core.ffi.MachineState
import com.nickalie.ngterm.core.ffi.MobileEvent
import com.nickalie.ngterm.core.ffi.PaneRef
import com.nickalie.ngterm.core.ffi.filterCommands
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import java.io.IOException

/** How a pane running an agent shows: its chat, or its terminal. */
enum class PaneView { Terminal, Chat }

/**
 * Which panes show as a chat, and their chats. A pane whose origin announces an agent (`LiveSession.agents`) shows as
 * a chat while its session's chat view is on ([chatViews]: Settings' Agent chat view, unless the session's More menu
 * set its own through [setChatView], kept in [sessionViews]), unless its terminal was picked: by hand ([pick]), or
 * because its chat ended or the origin couldn't open it (a link that is down only defers the open until it is back).
 * A terminal so picked holds until the pane's next conversation (or the agent leaves); picking the chat again lifts
 * it, and so does turning its session's chat view on. With its session's chat view off every pane shows its
 * terminal, as on a machine whose app has no chat view (agterm: [Connections.sessionPeers]).
 *
 * [views] has every pane with an agent whose session's chat view is on. A pane in chat view that is shown ([shown])
 * has its chat open in [chats], one [ChatViewModel] each, so the core's chat channels stay as few as the panes on
 * screen; a pane leaving chat view (or the screen) closes its chat, and the pane's own attach stays open behind it all
 * along. A prompt being written in a chat that closes comes back to the pane's next chat of the same conversation,
 * unless it was on its way to the agent and went. A session's Chat view item reads [chatViewItems], whichever menu
 * shows it.
 * Events arrive on the core's thread; the flows take them from any. Used on the main thread. A chat's `/` menu ranks
 * the agent's commands with [filter] (the core's `filter_commands`; the app's tests, which run without the native
 * library, give their own).
 */
class PaneChats(
    private val scope: CoroutineScope,
    private val connections: Connections,
    live: LiveSessions,
    private val shown: StateFlow<Map<PaneRef, TerminalState>>,
    private val sessionViews: SessionChatViews,
    private val filter: (String, List<AgentCommand>) -> List<AgentCommand> = ::filterCommands,
) {
    // the panes whose terminal was picked, with the conversation it holds for (`null`: the one still to be named)
    private val holds = MutableStateFlow<Map<PaneRef, Hold>>(emptyMap())
    private val chatViewState = MutableStateFlow(ChatViews())

    private val itemState = MutableStateFlow(ChatViews())

    // the sessions' choices laid over what the store reads until it reads them too, so an earlier write landing after
    // a later tap never shows through; one the store could not keep holds until the process ends or a later choice
    private val choices = MutableStateFlow<Map<SessionKey, Choice>>(emptyMap())
    private var lastChoice = 0L
    private val viewState = MutableStateFlow<Map<PaneRef, PaneView>>(emptyMap())
    private val chatState = MutableStateFlow<Map<PaneRef, ChatViewModel>>(emptyMap())
    private val sessions = live.sessions
    private val drafts = Drafts(scope) { chatState.value[it] }

    // how many times each machine's link has come up, by id: a chat asked for while it was down opens on the next
    private val connects = MutableStateFlow<Map<String, Long>>(emptyMap())

    /** How each pane with an agent shows, by pane; a pane not here shows its terminal, with no switch. */
    val views: StateFlow<Map<PaneRef, PaneView>> = viewState.asStateFlow()

    /** Whether each session's panes running an agent show as a chat: the default, and the sessions' own choices. */
    val chatViews: StateFlow<ChatViews> = chatViewState.asStateFlow()

    /**
     * What each session's Chat view item reads: [chatViews], with a session one of whose panes shows the terminal
     * picked for it as off, so the item says what the pane shows and its tap ([setChatView], on) brings the chat back.
     */
    val chatViewItems: StateFlow<ChatViews> = itemState.asStateFlow()

    /** The open chats, by pane. */
    val chats: StateFlow<Map<PaneRef, ChatViewModel>> = chatState.asStateFlow()

    init {
        connections.listen(::onEvent)
        scope.launch {
            combine(
                sessionViews.views.catch { /* each source stands in for itself (SessionChatViews): none comes */ },
                choices,
                ::Pair,
            ).collect { (views, laid) -> chatViewState.value = withChoices(views, settle(views, laid)) }
        }
        scope.launch {
            sessions.collect {
                keepHolds(it)
                drafts.follow(it)
            }
        }
        scope.launch {
            combine(sessions, holds, chatViewState, connections.sessionPeers, ::views).collect { viewState.value = it }
        }
        scope.launch { combine(viewState, chatViewState, ::items).collect { itemState.value = it } }
        scope.launch {
            combine(viewState, shown) { views, shown -> views to shown.keys }
                .collect { (views, shown) -> sync(views, shown) }
        }
    }

    /** Shows [pane] as [view]: its terminal held until its next conversation, or its chat again. */
    fun pick(
        pane: PaneRef,
        view: PaneView,
    ) {
        when (view) {
            PaneView.Terminal -> hold(pane)
            PaneView.Chat -> holds.update { it - pane }
        }
    }

    /**
     * Shows [key]'s panes running an agent as a chat ([on]) or as their terminal, whatever Settings' default; a choice
     * equal to the default follows it from then on. Turning it on brings back the chat of each pane whose terminal was
     * picked.
     */
    fun setChatView(
        key: SessionKey,
        on: Boolean,
    ) {
        val default = chatViewState.value.default
        if (on) holds.update { held -> held.filterKeys { it.session != key } }
        val choice = Choice(on.takeIf { on != default }, ++lastChoice)
        choices.update { it + (key to choice) }
        // at once, so the views follow the tap rather than the store's write
        chatViewState.update { withChoices(it, mapOf(key to choice)) }
        scope.launch {
            try {
                sessionViews.set(key, on, default)
                choices.update { now -> if (now[key] == choice) now + (key to choice.copy(landed = true)) else now }
            } catch (_: IOException) {
                // the store can't be written: the choice holds over what it reads until the app's process ends
            }
        }
    }

    /**
     * Brings [pane]'s open chat to its newest row, the card it waits on pinned under it (a notification's tap opened
     * the pane). A pane with no chat open has nothing to move: it shows its terminal, or its chat opens at its end.
     */
    fun reveal(pane: PaneRef) {
        chatState.value[pane]?.showEnd()
    }

    // the choices still laid over [views]: a landed one goes once the store reads it too
    private fun settle(
        views: ChatViews,
        laid: Map<SessionKey, Choice>,
    ): Map<SessionKey, Choice> {
        val read = laid.filter { (key, choice) -> choice.landed && views.sessions[key] == choice.on }
        if (read.isEmpty()) return laid
        choices.update { now -> now.filter { (key, choice) -> read[key] != choice } }
        return laid - read.keys
    }

    // a pane whose agent left holds nothing: its next agent starts in chat view
    private fun hold(pane: PaneRef) {
        val agent = sessions.value[pane.session]?.agents?.get(pane.paneId) ?: return
        holds.update { it + (pane to Hold(agent.conversation)) }
    }

    private fun onEvent(event: MobileEvent) {
        when (event) {
            is MobileEvent.Chat -> {
                chatState.value[event.pane]?.take(event.events)
            }

            is MobileEvent.ChatState -> {
                chatState.value[event.pane]?.take(event.state)
            }

            is MobileEvent.MachineState -> {
                if (event.state == MachineState.Connected) {
                    connects.update { it + (event.machineId to (it[event.machineId] ?: 0L) + 1) }
                }
            }

            else -> {}
        }
    }

    // a hold lasts while the pane's agent stays in the conversation it was made in; one made before the conversation
    // was named takes the first name it gets
    private fun keepHolds(sessions: Map<SessionKey, LiveSession>) {
        holds.update { held ->
            held
                .mapNotNull { (pane, hold) ->
                    val agent = sessions[pane.session]?.agents?.get(pane.paneId) ?: return@mapNotNull null
                    when (hold.conversation) {
                        null -> pane to Hold(agent.conversation)
                        agent.conversation -> pane to hold
                        else -> null
                    }
                }.toMap()
        }
    }

    // the chats open for exactly the panes on screen in chat view
    private fun sync(
        views: Map<PaneRef, PaneView>,
        shown: Set<PaneRef>,
    ) {
        val wanted = views.filter { (pane, view) -> view == PaneView.Chat && pane in shown }.keys
        val open = chatState.value
        drafts.follow(sessions.value)
        for ((pane, chat) in open) if (pane !in wanted) drafts.close(chat, sessions.value.agent(pane))
        val made = (wanted - open.keys).associateWith(::chat)
        chatState.value = open.filterKeys { it in wanted } + made
        for (chat in made.values) {
            chat.open()
            drafts.restore(chat)
        }
    }

    private fun chat(pane: PaneRef): ChatViewModel {
        // the conversation the pane announced as its chat opened
        val opened = sessions.value.agent(pane)?.conversation
        lateinit var chat: ChatViewModel
        chat =
            ChatViewModel(
                pane = pane,
                opened = opened,
                announced = { sessions.value.agent(pane)?.conversation },
                core = connections.core,
                handle = { shown.value[pane]?.pane },
                connects = connects,
                working = sessions.map { it[pane.session].works(pane.paneId) }.distinctUntilChanged(),
                filter = filter,
                sends = scope,
                scope = CoroutineScope(scope.coroutineContext + SupervisorJob(scope.coroutineContext.job)),
                // ends on the core's thread, or the chat's own: the views are the main thread's
                onEnded = { scope.launch { ended(chat, opened) } },
            )
        return chat
    }

    // a chat that ended, or never opened, leaves its terminal on screen until the next conversation: the one it
    // followed (its events named, or the pane announced as it opened). The pane may have moved on meanwhile (/clear
    // ends the old conversation's chat in the moment its record is cleared, and the next is announced right after):
    // then the chat goes and, the pane still in chat view, opens again for the conversation announced now
    private fun ended(
        chat: ChatViewModel,
        opened: String?,
    ) {
        val pane = chat.pane
        // an agent that left holds nothing: the pane leaves chat view, and its next agent starts in it
        val agent = sessions.value[pane.session]?.agents?.get(pane.paneId)
        if (chatState.value[pane] !== chat || agent == null) return
        val followed =
            chat.state.value.conversation
                ?.conversationId ?: opened
        if (followed == null || agent.conversation == followed) {
            holds.update { it + (pane to Hold(agent.conversation)) }
        } else {
            drafts.close(chat, agent)
            chatState.value -= pane
            sync(viewState.value, shown.value.keys)
        }
    }
}

// whether the session's agent status says the agent in pane [paneId] works on a turn: the status is the session's,
// naming the pane it came from (none: an origin that doesn't say, taken as the pane's)
private fun LiveSession?.works(paneId: String): Boolean {
    val status = this?.status ?: return false
    return AgentState.fromWire(status.status) == AgentState.Active && (status.pane == null || status.pane == paneId)
}

// a pane's terminal, picked for [conversation]
private data class Hold(
    val conversation: String?,
)

// what the origin announced of [pane]'s agent, or `null` when it runs none
private fun Map<SessionKey, LiveSession>.agent(pane: PaneRef): PaneAgent? = this[pane.session]?.agents?.get(pane.paneId)

// a prompt kept from a chat that closed: its [text], the [conversation] it was written in (`null`: the one its
// pane's agent has still to name), and its send still on its way as the chat closed ([sending])
private class Kept(
    var conversation: String?,
    val text: String,
    val sending: Deferred<Result<AgentInputOutcome>>?,
)

/**
 * The prompts being written in the chats that closed, each kept for its pane's next chat of the same conversation.
 * One written before the conversation had a name follows its pane's agent as a picked terminal does ([follow]): it
 * takes the first name the agent gets, and goes with the agent. One on its way to the agent as its chat closed waits
 * for the send to end, which the core carries through whoever waits for it: sent, it is let go, so it is never sent
 * twice; else it goes to the pane's chat [open] then, or its next. Main thread only, its waits in [scope].
 */
private class Drafts(
    private val scope: CoroutineScope,
    private val open: (PaneRef) -> ChatViewModel?,
) {
    private val kept = mutableMapOf<PaneRef, Kept>()

    // closes [chat], keeping what its field holds for the conversation it follows, else the one its pane's [agent]
    // announced, else the one that agent names next; with no agent left there is no conversation to keep it for
    fun close(
        chat: ChatViewModel,
        agent: PaneAgent?,
    ) {
        val text = chat.composer.draft.text
        val conversation = chat.conversation ?: agent?.conversation
        if (text.isNotBlank() && (conversation != null || agent != null)) {
            val draft = Kept(conversation, text, chat.sending)
            kept[chat.pane] = draft
            draft.sending?.let { sending -> scope.launch { settle(chat.pane, draft, sending) } }
        }
        chat.close()
    }

    // a draft whose conversation had no name takes the first one its pane's agent gets; its agent gone, it goes too
    fun follow(sessions: Map<SessionKey, LiveSession>) {
        val unnamed = kept.filterValues { it.conversation == null }
        for ((pane, draft) in unnamed) {
            val agent = sessions.agent(pane)
            if (agent == null) kept.remove(pane) else draft.conversation = agent.conversation
        }
    }

    // hands [chat], just opened, the prompt kept for its pane, unless its send is still on its way
    fun restore(chat: ChatViewModel) {
        val draft = kept[chat.pane]?.takeUnless { it.sending?.isActive == true } ?: return
        kept.remove(chat.pane)
        hand(chat, draft)
    }

    // a draft's send ended after its chat closed: sent, the draft goes; else the pane's open chat takes it
    private suspend fun settle(
        pane: PaneRef,
        draft: Kept,
        sending: Deferred<Result<AgentInputOutcome>>,
    ) {
        val sent = sending.await().getOrNull() == AgentInputOutcome.SENT
        if (kept[pane] !== draft) return
        val chat = open(pane)
        if (sent || chat != null) kept.remove(pane)
        if (!sent && chat != null) hand(chat, draft)
    }

    // a draft still unnamed is its pane's agent's own (it would have gone with the agent): [chat] is that one's
    private fun hand(
        chat: ChatViewModel,
        draft: Kept,
    ) {
        val conversation = draft.conversation
        if (conversation == null) chat.composer.restore(draft.text) else chat.restoreDraft(conversation, draft.text)
    }
}

// [chatViews] as the sessions' Chat view items read it: off for a session with a pane in [views] showing the
// terminal picked for it
private fun items(
    views: Map<PaneRef, PaneView>,
    chatViews: ChatViews,
): ChatViews {
    val picked = views.filterValues { it == PaneView.Terminal }.keys.associate { it.session to false }
    return if (picked.isEmpty()) chatViews else chatViews.copy(sessions = chatViews.sessions + picked)
}

// every pane with an agent, in its view, while its session's chat view is on and its session's app has one
private fun views(
    sessions: Map<SessionKey, LiveSession>,
    holds: Map<PaneRef, Hold>,
    chatViews: ChatViews,
    peers: Map<SessionKey, MachinePeer>,
): Map<PaneRef, PaneView> =
    sessions
        .filterKeys { key -> chatViews.on(key) && peers[key].offersChat }
        .flatMap { (key, session) ->
            session.agents.map { (paneId, agent) ->
                val pane = PaneRef(key.machineId, key.sessionId, paneId)
                val hold = holds[pane]
                val held = hold != null && (hold.conversation == null || hold.conversation == agent.conversation)
                pane to if (held) PaneView.Terminal else PaneView.Chat
            }
        }.toMap()

// a session's choice of tap [seq]: [on], or `null` for the default again; [landed] once the store took it
private data class Choice(
    val on: Boolean?,
    val seq: Long,
    val landed: Boolean = false,
)

// [views] with [choices] laid over its own
private fun withChoices(
    views: ChatViews,
    choices: Map<SessionKey, Choice>,
): ChatViews {
    if (choices.isEmpty()) return views
    val sessions = views.sessions.toMutableMap()
    for ((key, choice) in choices) if (choice.on == null) sessions.remove(key) else sessions[key] = choice.on
    return views.copy(sessions = sessions)
}
