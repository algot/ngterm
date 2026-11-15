package com.nickalie.ngterm.android.ui.chat

import androidx.compose.runtime.saveable.SaverScope
import androidx.compose.ui.text.input.TextFieldValue
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.nickalie.ngterm.core.fake.FakeAction
import com.nickalie.ngterm.core.ffi.AgentInputOutcome
import com.nickalie.ngterm.core.ffi.ChatBody
import com.nickalie.ngterm.core.ffi.MobileEvent
import com.nickalie.ngterm.core.ffi.RemoteLayout
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

/** A kept draft against the conversation its chat's events name, and through the app's process being let go. */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(AndroidJUnit4::class)
class ChatDraftsTest {
    @get:Rule
    val dir = TemporaryFolder()

    private lateinit var bed: ChatBed

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        bed = ChatBed(dir.root)
    }

    @After
    fun tearDown() {
        bed.close()
        Dispatchers.resetMain()
    }

    private fun draft() =
        bed
            .chat("p1")!!
            .composer.draft.text

    @Test
    fun aMessagePutBackOnThePanesAnnouncementLeavesWhenTheChatsEventsNameAnotherConversation() {
        bed.attach("p1")
        bed.show("p1")
        bed.agent("p1", conversation = "c1")
        eventually { bed.chat("p1") != null }
        bed.chat("p1")!!.composer.edit(TextFieldValue("Fix the guide"))
        bed.test.chats.pick(bed.ref("p1"), PaneView.Terminal)
        eventually { bed.chat("p1") == null }
        // the pane moved on meanwhile, its announcement still on its way: the chat opens on the old one's word
        bed.test.chats.pick(bed.ref("p1"), PaneView.Chat)
        eventually { bed.chat("p1") != null }
        assertEquals("Fix the guide", draft())
        // its backlog names the conversation the pane is in now: the message was not written for it
        bed.emit("p1", event("conversation", ChatBody.Conversation("claude", "c2", null, null)), live)
        assertEquals("", draft())

        // one the events name as its own stays
        bed.agent("p1", conversation = "c2")
        bed.chat("p1")!!.composer.edit(TextFieldValue("For the second"))
        bed.test.chats.pick(bed.ref("p1"), PaneView.Terminal)
        eventually { bed.chat("p1") == null }
        bed.test.chats.pick(bed.ref("p1"), PaneView.Chat)
        eventually { bed.chat("p1") != null }
        bed.emit("p1", event("conversation", ChatBody.Conversation("claude", "c2", null, null)), live)
        assertEquals("For the second", draft())

        // and what was written over a message put back is the user's own, whatever the events name
        bed.test.chats.pick(bed.ref("p1"), PaneView.Terminal)
        eventually { bed.chat("p1") == null }
        bed.test.chats.pick(bed.ref("p1"), PaneView.Chat)
        eventually { bed.chat("p1") != null }
        bed.chat("p1")!!.composer.edit(TextFieldValue("For the second, and more"))
        bed.emit("p1", event("conversation", ChatBody.Conversation("claude", "c3", null, null)), live)
        assertEquals("For the second, and more", draft())
    }

    @Test
    fun aMessageKeptWhileThePaneShowsItsTerminalOutlivesTheAppsProcess() {
        val pane = bed.ref("p1")
        val saver = keptDraftsSaver(bed.test.chats.keptDrafts::saved)

        fun save() = with(saver) { SaverScope { true }.save(KeptDrafts(emptyList())) }
        bed.attach("p1")
        bed.show("p1")
        bed.agent("p1", conversation = "c1")
        eventually { bed.chat("p1") != null }
        // nothing kept, nothing saved; nor one too long for saved state
        assertNull(save())
        bed.chat("p1")!!.composer.edit(TextFieldValue("a".repeat(KEPT_DRAFT_MAX + 1)))
        bed.test.chats.pick(pane, PaneView.Terminal)
        eventually { bed.chat("p1") == null }
        assertNull(save())
        bed.test.chats.pick(pane, PaneView.Chat)
        eventually { bed.chat("p1") != null }

        // the message stays with its pane's terminal on screen, where no chat is there to save it
        bed.chat("p1")!!.composer.edit(TextFieldValue("Fix the guide"))
        bed.test.chats.pick(pane, PaneView.Terminal)
        eventually { bed.chat("p1") == null }
        val saved = save()!!
        assertEquals(listOf(PaneDraft(pane, "c1", "Fix the guide")), saver.restore(saved)!!.drafts)
        assertTrue(saver.restore(arrayListOf("m1", "s1"))!!.drafts.isEmpty())

        // the app's next process, its pane shown already: the chat open there takes the message
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        try {
            val next = chats(scope)
            eventually { next.chats.value[pane] != null }
            next.keptDrafts.take(saver.restore(saved)!!.drafts)
            assertEquals(
                "Fix the guide",
                next.chats.value[pane]!!
                    .composer.draft.text,
            )

            // its pane not on screen yet: the message waits for the pane's chat, and only the process's first
            // saved state is taken
            bed.test.core.emit(MobileEvent.SessionLayout("m1", "s1", RemoteLayout(emptyList(), "p1", "vertical", true)))
            eventually { next.chats.value[pane] == null }
            val later = chats(scope)
            later.keptDrafts.take(saver.restore(saved)!!.drafts)
            later.keptDrafts.take(listOf(PaneDraft(bed.ref("p2"), "c1", "an older copy")))
            assertEquals(listOf(PaneDraft(pane, "c1", "Fix the guide")), later.keptDrafts.saved())
            bed.test.core.emit(
                MobileEvent.SessionLayout("m1", "s1", RemoteLayout(listOf("p1"), "p1", "vertical", true)),
            )
            bed.show("p1")
            eventually { later.chats.value[pane] != null }
            assertEquals(
                "Fix the guide",
                later.chats.value[pane]!!
                    .composer.draft.text,
            )
            assertTrue(later.keptDrafts.saved().isEmpty())
        } finally {
            scope.cancel()
        }
    }

    @Test
    fun aMessageStillOnItsWayIsSavedOnlyOnceItDidNotGo() {
        val pane = bed.ref("p1")
        val prompts = bed.test.chats.keptDrafts
        bed.attach("p1")
        bed.show("p1")
        bed.agent("p1", conversation = "c1")
        eventually { bed.chat("p1") != null }
        // saved while on its way, it would come back in the app's next process though it went
        val gate = send("Fix the guide", sends = 1)
        bed.test.chats.pick(pane, PaneView.Terminal)
        eventually { bed.chat("p1") == null }
        assertTrue(prompts.saved().isEmpty())
        gate.complete(Unit)
        bed.test.chats.pick(pane, PaneView.Chat)
        eventually { bed.chat("p1") != null }
        assertEquals("", draft())
        assertTrue(prompts.saved().isEmpty())

        // one that did not go waits for the pane's next chat, in the next process too
        bed.panes.getValue("p1").outcome = AgentInputOutcome.NOT_ON_SCREEN
        val second = send("And the tests", sends = 2)
        bed.test.chats.pick(pane, PaneView.Terminal)
        eventually { bed.chat("p1") == null }
        assertTrue(prompts.saved().isEmpty())
        second.complete(Unit)
        eventually { prompts.saved() == listOf(PaneDraft(pane, "c1", "And the tests")) }
    }

    @Test
    fun savedStateHoldsOnlyWholeDraftsThatFitIt() {
        val long = "a".repeat(KEPT_DRAFT_MAX)
        val texts = listOf(long, long, long, "Fix the guide", long, long)
        val drafts = texts.mapIndexed { at, text -> PaneDraft(bed.ref("p$at"), "c1", text) }
        val saver = keptDraftsSaver { drafts }
        val saved = with(saver) { SaverScope { true }.save(KeptDrafts(emptyList())) }!!
        // a draft the rest has no room for is left out, a shorter one after it is not
        val back = saver.restore(saved)!!.drafts
        assertEquals(drafts.take(4).map { it.pane }, back.map { it.pane })
        assertEquals(texts.take(4).map { it.length }, back.map { it.text.length })

        // saved state that is not this saver's own brings nothing back
        assertTrue(saver.restore(arrayListOf("m1", "s1", 0, "p1", "c1", "text"))!!.drafts.isEmpty())
        assertTrue(saver.restore(arrayListOf("m1", "s1", "p1", "c1", long + "a"))!!.drafts.isEmpty())
        assertEquals(
            listOf(PaneDraft(bed.ref("p1"), "c1", "text")),
            saver.restore(arrayListOf("m1", "s1", "p1", "c1", "text"))!!.drafts,
        )
    }

    // [text] written in pane p1's chat and its send, the pane's [sends]th, on its way, held at the gate returned
    private fun send(
        text: String,
        sends: Int,
    ): CompletableDeferred<Unit> {
        val gate = CompletableDeferred<Unit>()
        bed.panes.getValue("p1").gate = gate
        bed.chat("p1")!!.composer.edit(TextFieldValue(text))
        bed.chat("p1")!!.send()
        eventually {
            val actions = bed.panes.getValue("p1").actions
            actions.size == sends && actions.last() == FakeAction.Prompt(text)
        }
        return gate
    }

    // the chats of a process of its own over the bed's machine
    private fun chats(scope: CoroutineScope) =
        PaneChats(scope, bed.test.connections, bed.test.live, bed.test.panes.shown, bed.test.sessionViews) { _, items ->
            items
        }
}
