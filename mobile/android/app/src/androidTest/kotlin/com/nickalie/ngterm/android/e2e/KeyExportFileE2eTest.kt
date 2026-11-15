package com.nickalie.ngterm.android.e2e

import android.os.Build
import androidx.compose.ui.test.performTextReplacement
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import com.nickalie.ngterm.android.e2e.KeyExportDriver.Companion.KEY_START
import com.nickalie.ngterm.android.e2e.KeyExportDriver.Companion.PASSPHRASE
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

/**
 * A key saved to a file and read back from it, end to end through the system's own file screen, as when a person
 * moves to another install of ngterm: Save to a file opens the system's screen for a new document; leaving that
 * screen writes nothing and says nothing was saved; saving writes an OpenSSH private key file under the passphrase;
 * Import a key's Choose file reads that file back, refuses a wrong passphrase and with the right one holds the same
 * public key.
 */
@RunWith(AndroidJUnit4::class)
@SdkSuppress(minSdkVersion = Build.VERSION_CODES.R)
class KeyExportFileE2eTest {
    private val driver = KeyExportDriver()

    @get:Rule
    val rules: RuleChain = driver.rules

    @Test
    fun aKeySavedThroughTheSystemsFileScreenImportsBackFromThatFile() {
        val made = driver.createKeyAndOpenSettings()
        driver.setScreenLock()
        driver.tap("Export private key")
        driver.unlock()
        driver.awaitText(SAVE)
        driver.field("Passphrase").performTextReplacement(PASSPHRASE)
        driver.field("Passphrase again").performTextReplacement(PASSPHRASE)

        driver.tap(SAVE)
        driver.leaveFileScreen()
        driver.awaitText(SAVE)
        assertEquals("leaving the file screen says the key was saved", 0, driver.shown(SAVED, substring = true))
        assertEquals("leaving the file screen wrote a file", "", driver.exportedFile())

        driver.tap(SAVE)
        driver.saveInFileScreen()
        driver.awaitText(SAVED, substring = true)
        assertTrue("an OpenSSH private key file was written", driver.exportedFile().startsWith(KEY_START))
        driver.back()

        driver.awaitText("Import a key")
        driver.tap("Import a key")
        driver.tap("Choose file")
        driver.pickExportedFile()
        driver.awaitText("The key from the chosen file is ready", substring = true)
        driver.field("Passphrase").performTextReplacement("not the passphrase")
        driver.tap("Import key")
        driver.awaitText("That passphrase doesn't open this key.")
        driver.field("Passphrase").performTextReplacement(PASSPHRASE)
        driver.tap("Import key")
        driver.awaitText("Add this key to your machines")
        assertEquals("the key imported from the file is the exported one", made, driver.publicKeyLine())
    }

    private companion object {
        const val SAVE = "Save to a file"
        const val SAVED = "Saved. Delete the file"
    }
}
