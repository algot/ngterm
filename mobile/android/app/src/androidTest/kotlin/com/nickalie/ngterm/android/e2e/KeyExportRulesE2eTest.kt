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
 * What stands between a person and the app's private key, end to end on the real mobile core, Keystore, system
 * prompt and clipboard: a device with no screen lock is told to set one; backing out of the system's prompt opens
 * no export; a passphrase under eight characters, or one whose repeat differs, exports nothing and says why; an
 * export without a passphrase needs its switch, shows its warning and asks once more, and only then is the key
 * copied unencrypted (it imports back with no passphrase, as the same key); closing the screen takes it off the
 * clipboard.
 */
@RunWith(AndroidJUnit4::class)
@SdkSuppress(minSdkVersion = Build.VERSION_CODES.R)
class KeyExportRulesE2eTest {
    private val driver = KeyExportDriver()

    @get:Rule
    val rules: RuleChain = driver.rules

    @Test
    fun aKeyLeavesOnlyPastTheScreenLockAndAPassphraseOrAnExplicitConfirmedChoice() {
        val made = driver.createKeyAndOpenSettings()

        driver.tap(EXPORT)
        driver.awaitText("Set a screen lock first")
        driver.tapInDialog("Cancel")
        assertNothingLeft("a device with no screen lock")

        driver.setScreenLock()
        driver.tap(EXPORT)
        driver.cancelLockPrompt()
        assertNothingLeft("backing out of the screen lock's prompt")

        driver.tap(EXPORT)
        driver.unlock()
        driver.awaitText(COPY)
        driver.field("Passphrase").performTextReplacement(SHORT)
        driver.field("Passphrase again").performTextReplacement(SHORT)
        driver.tap(COPY)
        driver.awaitText("Use at least 8 characters.")
        assertEquals("a passphrase of seven characters copied something", "", driver.clipboard())
        driver.field("Passphrase").performTextReplacement(PASSPHRASE)
        driver.tap(COPY)
        driver.awaitText("The two passphrases differ.")
        assertEquals("a passphrase whose repeat differs copied something", "", driver.clipboard())

        driver.tap(UNPROTECTED)
        driver.awaitText("Without a passphrase the exported key isn't encrypted", substring = true)
        driver.tap(COPY)
        driver.awaitText("Export without a passphrase?")
        driver.tapInDialog("Cancel")
        assertEquals("declining the unencrypted export copied something", "", driver.clipboard())
        driver.tap(COPY)
        driver.awaitText("Export without a passphrase?")
        driver.tapInDialog(UNPROTECTED)
        driver.awaitText("Copied. Paste it", substring = true)
        val exported = driver.clipboard()
        assertTrue("an OpenSSH private key was copied", exported.startsWith(KEY_START))
        driver.back()

        driver.awaitText("Import a key")
        assertEquals("the copied key left the clipboard with the export screen", "", driver.clipboard())
        driver.tap("Import a key")
        driver.field("Private key").performTextReplacement(exported)
        driver.tap("Import key")
        driver.awaitText("Add this key to your machines")
        assertEquals("the key exported without a passphrase is the app's key", made, driver.publicKeyLine())
    }

    private fun assertNothingLeft(after: String) {
        assertEquals("$after opened the export", 0, driver.shown(COPY))
        assertEquals("$after copied something", "", driver.clipboard())
    }

    private companion object {
        const val EXPORT = "Export private key"
        const val COPY = "Copy to the clipboard"
        const val UNPROTECTED = "Export without a passphrase"
        const val SHORT = "seven77"
    }
}
