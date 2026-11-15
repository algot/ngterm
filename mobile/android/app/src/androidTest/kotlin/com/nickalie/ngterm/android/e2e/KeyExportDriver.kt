package com.nickalie.ngterm.android.e2e

import android.app.KeyguardManager
import android.content.ClipboardManager
import android.os.ParcelFileDescriptor
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import com.nickalie.ngterm.android.MainActivity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeFalse
import org.junit.Assume.assumeTrue
import org.junit.rules.ExternalResource
import org.junit.rules.RuleChain
import java.io.File
import java.util.regex.Pattern

/**
 * What the key export's end-to-end tests do as a person would: the app's own screens through Compose, the system's
 * screen-lock prompt and file screen through UiAutomator. A test starts at the first run on a device with no screen
 * lock (one that has its own is skipped, since the test can't unlock it) and leaves it with none, an empty clipboard
 * and no exported file. Each test needs an app process of its own, as `KeyExportImportE2eTest` says: without
 * `scripts/test-android-e2e.sh`'s arguments it is skipped.
 */
internal class KeyExportDriver {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    val device: UiDevice = UiDevice.getInstance(instrumentation)
    val compose = createAndroidComposeRule<MainActivity>()

    private val ownRun =
        object : ExternalResource() {
            override fun before() {
                assumeTrue(
                    "no run of its own: run it through scripts/test-android-e2e.sh",
                    !InstrumentationRegistry.getArguments().getString(OWN_RUN).isNullOrBlank(),
                )
            }
        }

    private val freshInstall =
        object : ExternalResource() {
            override fun before() {
                val context = instrumentation.targetContext
                File(context.filesDir, "datastore").deleteRecursively()
                File(context.noBackupFilesDir, "keys").deleteRecursively()
            }
        }

    private val cleanDevice =
        object : ExternalResource() {
            override fun before() {
                val keyguard = instrumentation.targetContext.getSystemService(KeyguardManager::class.java)
                assumeFalse("the device has a screen lock of its own", keyguard.isDeviceSecure)
                clean()
            }

            override fun after() {
                shell("locksettings clear --old $PIN")
                clean()
            }

            private fun clean() {
                instrumentation.targetContext.getSystemService(ClipboardManager::class.java).clearPrimaryClip()
                shell("rm -f $EXPORTED_FILE")
            }
        }

    val rules: RuleChain =
        RuleChain
            .outerRule(ownRun)
            .around(freshInstall)
            .around(cleanDevice)
            .around(compose)

    /** The first run's Create a key, then Settings; the new key's `authorized_keys` line. */
    fun createKeyAndOpenSettings(): String {
        awaitText("Create a key")
        tap("Create a key")
        awaitText("Add this key to your machines")
        val made = publicKeyLine()
        tap("Done")
        awaitText("Settings")
        compose.onNodeWithText("Settings").performClick()
        return made
    }

    fun setScreenLock() {
        shell("locksettings set-pin $PIN")
        val keyguard = instrumentation.targetContext.getSystemService(KeyguardManager::class.java)
        assertTrue("the test's screen lock is set", keyguard.isDeviceSecure)
    }

    /** The system's prompt for the screen lock, up. */
    fun awaitLockPrompt() {
        val prompt = device.wait(Until.findObject(By.text("Export private key").pkg(SYSTEM_UI)), WAIT_MS)
        assertNotNull("the system asks for the screen lock before the export opens", prompt)
        val entry = device.wait(Until.findObject(By.clazz("android.widget.EditText").pkg(SYSTEM_UI)), WAIT_MS)
        assertNotNull("the prompt takes the PIN", entry)
    }

    /** Backs out of the system's prompt, as a person who changed their mind. */
    fun cancelLockPrompt() {
        awaitLockPrompt()
        device.pressBack()
        assertTrue(
            "the prompt closes on Back",
            device.wait(Until.gone(By.text("Export private key").pkg(SYSTEM_UI)), WAIT_MS),
        )
    }

    /** Answers the system's prompt with the test's PIN. */
    fun unlock() {
        awaitLockPrompt()
        shell("input text $PIN")
        shell("input keyevent KEYCODE_ENTER")
    }

    /** The system's file screen for a new document, up. */
    fun awaitFileScreen() {
        assertNotNull("the system's file screen opens", device.wait(Until.findObject(saveButton()), WAIT_MS))
    }

    /** Leaves the system's file screen without making a document (a first Back may only put its keyboard away). */
    fun leaveFileScreen() {
        awaitFileScreen()
        repeat(BACKS) {
            if (device.hasObject(By.pkg(FILES))) {
                device.pressBack()
                device.wait(Until.gone(By.pkg(FILES)), GONE_MS)
            }
        }
        assertEquals("the file screen is left", false, device.hasObject(By.pkg(FILES)))
    }

    /** Saves the document the system's file screen offers, under the name and in the place it proposes. */
    fun saveInFileScreen() {
        awaitFileScreen()
        device.findObject(saveButton()).click()
    }

    /** Picks the exported file in the system's file screen. */
    fun pickExportedFile() {
        val file = device.wait(Until.findObject(By.pkg(FILES).text(EXPORTED_NAME)), WAIT_MS)
        assertNotNull("the system's file screen lists the exported file", file)
        file.click()
    }

    /** What the exported file holds; nothing when there is none. */
    fun exportedFile(): String = shell("cat $EXPORTED_FILE")

    fun publicKeyLine(): String =
        compose
            .onAllNodesWithText("ssh-ed25519 ", substring = true)
            .fetchSemanticsNodes()
            .mapNotNull { node ->
                node.config
                    .getOrNull(SemanticsProperties.Text)
                    ?.firstOrNull()
                    ?.text
            }.first { it.startsWith("ssh-ed25519 ") }

    fun clipboard(): String {
        var text = ""
        compose.runOnUiThread {
            val manager = compose.activity.getSystemService(ClipboardManager::class.java)
            text =
                manager.primaryClip
                    ?.getItemAt(0)
                    ?.text
                    ?.toString()
                    .orEmpty()
        }
        return text
    }

    fun back() = compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }

    fun awaitText(
        text: String,
        substring: Boolean = false,
    ) = compose.waitUntil(WAIT_MS) { shown(text, substring) > 0 }

    fun shown(
        text: String,
        substring: Boolean = false,
    ): Int = compose.onAllNodesWithText(text, substring = substring).fetchSemanticsNodes().size

    fun tap(text: String) = compose.onNodeWithText(text).performScrollTo().performClick()

    fun tapInDialog(text: String) = compose.onNode(hasText(text) and hasAnyAncestor(isDialog())).performClick()

    fun field(label: String) = compose.onNode(hasText(label) and hasSetTextAction())

    private fun saveButton() = By.pkg(FILES).clazz("android.widget.Button").text(Pattern.compile("(?i)save"))

    private fun shell(command: String): String =
        ParcelFileDescriptor
            .AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command))
            .bufferedReader()
            .use { it.readText() }

    companion object {
        const val PASSPHRASE = "correct horse battery"
        const val KEY_START = "-----BEGIN OPENSSH PRIVATE KEY-----\n"

        private const val WAIT_MS = 20_000L
        private const val GONE_MS = 3_000L
        private const val BACKS = 3
        private const val PIN = "1379"
        private const val SYSTEM_UI = "com.android.systemui"
        private const val EXPORTED_NAME = "ngterm-private-key"
        private const val EXPORTED_FILE = "/sdcard/Download/$EXPORTED_NAME"

        // the system's file screen: com.android.documentsui, or Google's build of it
        private val FILES: Pattern = Pattern.compile(".*\\.documentsui")

        // an argument only scripts/test-android-e2e.sh passes, with each class's own run
        private const val OWN_RUN = "e2eHost"
    }
}
