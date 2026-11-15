package com.nickalie.ngterm.android.e2e

import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Base64
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextReplacement
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import com.nickalie.ngterm.android.MainActivity
import com.nickalie.ngterm.android.R
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.ExternalResource
import org.junit.rules.RuleChain
import org.junit.rules.TestWatcher
import org.junit.runner.Description
import org.junit.runner.RunWith
import java.io.File

/**
 * A Mac whose agterm is not in Live sessions mode, end to end: the app signs in to it over ssh as to any machine, its
 * listing is empty, and its sessions screen says why in the core's words, over the empty state: agterm lists only the
 * sessions started in that mode. Nothing on the machine is changed.
 *
 * The machine is the conformance suite's stand-in agterm (`conformance/agterm_conformance/fake_agterm.py`) in restore
 * mode `none` with no session, behind the private `sshd` that `scripts/test-android-e2e.sh` starts, on a port of its
 * own ([OFF_PORT]). Without the script's arguments the test is skipped. No live agterm.
 */
@RunWith(AndroidJUnit4::class)
@SdkSuppress(minSdkVersion = Build.VERSION_CODES.P)
class AgtermNotLiveE2eTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val arguments = InstrumentationRegistry.getArguments()
    private val compose = createAndroidComposeRule<MainActivity>()

    private val stack =
        object : ExternalResource() {
            override fun before() {
                assumeTrue(
                    "no agterm machine: run it through scripts/test-android-e2e.sh",
                    listOf(HOST, OFF_PORT, USER, KEY).all { !arguments.getString(it).isNullOrBlank() },
                )
            }
        }

    /** A fresh install (no key, no machine, no pin), cleared before the activity starts. */
    private val freshInstall =
        object : ExternalResource() {
            override fun before() {
                val context = instrumentation.targetContext
                File(context.filesDir, "datastore").deleteRecursively()
                File(context.noBackupFilesDir, "keys").deleteRecursively()
            }
        }

    private val evidence =
        object : TestWatcher() {
            override fun failed(
                e: Throwable?,
                description: Description,
            ) = screenshot("failed")
        }

    @get:Rule
    val rules: RuleChain =
        RuleChain
            .outerRule(stack)
            .around(freshInstall)
            .around(compose)
            .around(evidence)

    @Test
    fun anAgtermOutsideLiveSessionsModeSaysWhyItListsNothing() {
        signIn()
        addMachine(MACHINE, arguments.getString(OFF_PORT).orEmpty())
        compose.onNodeWithText(MACHINE).performClick()

        awaitText(text(R.string.machine_sessions_empty_title, MACHINE))
        awaitText(HINT)
        assertEquals("the hint shows once", 1, nodes(hasText(HINT)))
        screenshot("not-live")
    }

    private fun signIn() {
        val key = String(Base64.decode(arguments.getString(KEY), Base64.DEFAULT))
        awaitText(text(R.string.welcome_import))
        compose.onNodeWithText(text(R.string.welcome_import)).performClick()
        compose.onNodeWithText(text(R.string.import_key_label)).performTextInput(key)
        compose.onNodeWithText(text(R.string.import_action)).performScrollTo().performClick()
        awaitText(text(R.string.key_done))
        compose.onNodeWithText(text(R.string.key_done)).performScrollTo().performClick()
        awaitText(text(R.string.machines_add))
    }

    private fun addMachine(
        label: String,
        port: String,
    ) {
        compose.onAllNodesWithText(text(R.string.machines_add))[0].performClick()
        compose.onNodeWithText(text(R.string.form_label)).performTextInput(label)
        compose.onNodeWithText(text(R.string.form_host)).performTextInput(arguments.getString(HOST).orEmpty())
        compose.onNodeWithText(text(R.string.form_port)).performTextReplacement(port)
        compose.onNodeWithText(text(R.string.form_user)).performTextInput(arguments.getString(USER).orEmpty())
        compose.onNodeWithText(text(R.string.form_save)).performClick()
        awaitText(text(R.string.hostkey_trust))
        compose.onNodeWithText(text(R.string.hostkey_trust)).performClick()
        awaitText(label)
    }

    private fun nodes(matcher: SemanticsMatcher): Int = compose.onAllNodes(matcher).fetchSemanticsNodes().size

    private fun awaitText(text: String) = compose.waitUntil(CONNECT_WAIT_MS) { nodes(hasText(text)) > 0 }

    private fun text(
        id: Int,
        vararg args: Any,
    ): String = instrumentation.targetContext.getString(id, *args)

    private fun screenshot(name: String) {
        ParcelFileDescriptor
            .AutoCloseInputStream(
                instrumentation.uiAutomation.executeShellCommand("screencap -p $EVIDENCE_DIR/agterm-off-$name.png"),
            ).use { it.readBytes() }
    }

    private companion object {
        /** The instrumentation arguments the script passes: the host, the machine's port, the user and key. */
        const val HOST = "e2eHost"
        const val OFF_PORT = "e2eAgtermOffPort"
        const val USER = "e2eUser"
        const val KEY = "e2eKey"

        const val MACHINE = "qa-agterm-off"

        /** The core's words for an agterm in restore mode none, naming the machine by its label. */
        const val HINT =
            "agterm on $MACHINE is not in Live sessions mode: set Settings > General > Restore sessions to Live " +
                "sessions and restart agterm; only sessions started after that can be attached"

        const val EVIDENCE_DIR = "/data/local/tmp/ngterm-e2e"
        const val CONNECT_WAIT_MS = 60_000L
    }
}
