package com.nickalie.ngterm.android.ui.logs

import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onLast
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.nickalie.ngterm.android.TestGraph
import com.nickalie.ngterm.android.awaitStore
import com.nickalie.ngterm.android.awaitText
import com.nickalie.ngterm.android.ui.settings.SettingsRoute
import com.nickalie.ngterm.android.ui.theme.NgtermTheme
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** Settings > Logs through the real route and model: reading, Copy, Share through the share sheet, and Clear. */
@RunWith(AndroidJUnit4::class)
@Config(qualifiers = "w700dp-h1000dp-mdpi")
class LogsScreenTest {
    @get:Rule val dir = TemporaryFolder()

    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private lateinit var test: TestGraph

    @Before fun setUp() {
        test = TestGraph(dir.root)
        test.logs.core('I', "link", "connect asked machine=m1 label=build-01")
        test.logs.core('W', "ssh", "connect failed machine=m1 class=refused")
    }

    @After fun tearDown() = test.close()

    private fun open() {
        compose.setContent { NgtermTheme { SettingsRoute(test.graph, "settings-test") } }
        compose.awaitText("core settings-test")
        compose.onNodeWithText("Logs").performScrollTo().performClick()
        compose.awaitText("connect failed machine=m1 class=refused", substring = true)
    }

    @Test
    fun settingsOpensTheLogWhichSaysWhatItHoldsAndBackReturns() {
        open()
        compose.onNodeWithText("It never holds what you type", substring = true).assertExists()
        compose.onNodeWithText("warning connect failed", substring = true).assertExists()
        assertTrue("I nav: settings page=logs" in test.logs.lines)
        compose.onNodeWithContentDescription("Back").performClick()
        compose.awaitText("core settings-test")
        compose.onNodeWithText("Logs").performScrollTo().performClick()
        compose.awaitText("Clear logs")
        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.awaitText("core settings-test")
    }

    @Test
    fun copyPutsTheShownLinesOnTheClipboard() {
        open()
        compose.onNodeWithText("Copy").performClick()
        compose.awaitText("Copied")
        val clipboard = compose.activity.getSystemService(ClipboardManager::class.java)
        compose.awaitStore { clipboard.primaryClip != null }
        val copied =
            clipboard.primaryClip
                ?.getItemAt(0)
                ?.text
                .toString()
        // the lines as the log wrote them, whole, up to the ones shown when Copy was tapped
        assertTrue(copied, test.logs.text().startsWith(copied))
        assertTrue(
            copied,
            copied.trimEnd().lines().size >= 2 && "W ssh: connect failed machine=m1 class=refused" in copied,
        )
        compose.awaitText("copied the shown lines", substring = true)
    }

    @Test
    fun shareHandsTheWholeLogToTheShareSheetAsAFileOnlyItsReaderMayOpen() {
        open()
        val whole = test.logs.text()
        compose.onNodeWithText("Share").performClick()
        compose.awaitStore { shadowOf(compose.activity.application).peekNextStartedActivity() != null }
        val chooser = shadowOf(compose.activity.application).nextStartedActivity
        assertEquals(Intent.ACTION_CHOOSER, chooser.action)
        val send = requireNotNull(chooser.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java))
        assertEquals(Intent.ACTION_SEND, send.action)
        assertEquals("text/plain", send.type)
        assertTrue(send.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
        val uri = requireNotNull(send.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java))
        assertEquals("content://${compose.activity.packageName}.logs/logs/ngterm-log.txt", uri.toString())
        val sent =
            compose.activity.contentResolver
                .openInputStream(uri)
                .use { requireNotNull(it).readBytes().decodeToString() }
        assertEquals(whole, sent)
    }

    @Test
    fun aShareThatFailsSaysWhatToDo() {
        test.logs.failExport = true
        open()
        compose.onNodeWithText("Share").performClick()
        compose.awaitText("The log could not be written to a file to share", substring = true)
    }

    @Test
    fun clearAsksFirstAndCancelKeepsTheLines() {
        open()
        compose.onNodeWithText("Clear logs").performClick()
        compose.awaitText("Clear logs?")
        compose.onNodeWithText("Cancel").performClick()
        compose.onNodeWithText("connect failed machine=m1 class=refused", substring = true).assertExists()
        compose.onNodeWithText("Clear logs").performClick()
        compose.awaitText("Clear logs?")
        compose.onAllNodesWithText("Clear logs").onLast().performClick()
        compose.awaitText("log cleared", substring = true)
        compose.onNodeWithText("connect failed machine=m1 class=refused", substring = true).assertDoesNotExist()
    }
}
