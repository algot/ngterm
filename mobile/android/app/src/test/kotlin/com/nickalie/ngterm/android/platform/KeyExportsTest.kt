package com.nickalie.ngterm.android.platform

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.Build
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream

/** An exported key reaches the document the user made, whole, or the clipboard marked sensitive. */
@RunWith(AndroidJUnit4::class)
class KeyExportsTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val exports = AndroidKeyExports(context)
    private val target = Uri.parse("content://documents/ngterm-private-key")
    private val key = "-----BEGIN OPENSSH PRIVATE KEY-----\nmade up\n-----END OPENSSH PRIVATE KEY-----\n"

    @Test
    fun theKeyIsWrittenAsTheWholeDocumentAndTheDocumentClosed() {
        val written = Tracked()
        shadowOf(context.contentResolver).registerOutputStream(target, written)

        exports.save(target, key.toByteArray())

        assertEquals(key, written.toString())
        assertTrue(written.closed)
    }

    @Test
    fun aDocumentThatCannotBeWrittenIsAnIoFailure() {
        val failing =
            object : OutputStream() {
                override fun write(byte: Int) = throw IOException("no space left")
            }
        shadowOf(context.contentResolver).registerOutputStream(target, failing)

        val error = assertThrows(IOException::class.java) { exports.save(target, key.toByteArray()) }

        assertEquals("no space left", error.message)
    }

    @Test
    fun aDocumentTheProviderRefusesIsAnIoFailure() {
        val refusing =
            object : OutputStream() {
                override fun write(byte: Int) = throw SecurityException("permission revoked")
            }
        shadowOf(context.contentResolver).registerOutputStream(target, refusing)

        val error = assertThrows(IOException::class.java) { exports.save(target, key.toByteArray()) }

        assertEquals("permission revoked", error.message)
    }

    @Test
    fun whatAProviderThrowsOfItsOwnIsAnIoFailureToo() {
        val unsupported =
            object : OutputStream() {
                override fun write(byte: Int) = throw UnsupportedOperationException("mode wt is not supported")
            }
        shadowOf(context.contentResolver).registerOutputStream(target, unsupported)

        val error = assertThrows(IOException::class.java) { exports.save(target, key.toByteArray()) }

        assertEquals("mode wt is not supported", error.message)
        assertTrue(error.cause is UnsupportedOperationException)
    }

    @Test
    fun theClipboardHoldsTheKeyMarkedSensitive() {
        exports.copy(key.toByteArray())

        val clip = context.getSystemService(ClipboardManager::class.java).primaryClip!!
        assertEquals(key, clip.getItemAt(0).text.toString())
        assertTrue(clip.description.extras.getBoolean("android.content.extra.IS_SENSITIVE"))
    }

    private val clipboard get() = context.getSystemService(ClipboardManager::class.java)

    private fun onClipboard(): String? =
        clipboard.primaryClip
            ?.takeIf { it.itemCount > 0 }
            ?.getItemAt(0)
            ?.text
            ?.toString()

    @Test
    fun theCopiedKeyIsClearedFromTheClipboardWhileItIsStillThere() {
        exports.copy(key.toByteArray())

        exports.clearCopied()

        assertFalse(clipboard.hasPrimaryClip())
    }

    @Test
    fun beforeAndroid9AnEmptyClipTakesTheCopiedKeysPlace() {
        val old = AndroidKeyExports(context, Build.VERSION_CODES.O)
        old.copy(key.toByteArray())

        old.clearCopied()

        assertEquals("", onClipboard())
    }

    @Test
    fun whatAnotherAppCopiedSinceIsNeverCleared() {
        exports.copy(key.toByteArray())
        clipboard.setPrimaryClip(ClipData.newPlainText("ngterm private key", "another app's text"))

        exports.clearCopied()

        assertEquals("another app's text", onClipboard())
    }

    @Test
    fun aClipboardThisExportCopiedNothingToIsLeftAlone() {
        clipboard.setPrimaryClip(ClipData.newPlainText("note", "the user's own text"))
        exports.clearCopied()
        assertEquals("the user's own text", onClipboard())

        AndroidKeyExports(context).copy(key.toByteArray())
        exports.clearCopied()
        assertEquals("another export's copy is not this one's to clear", key, onClipboard())
    }

    @Test
    fun aKeyIsClearedOnceThenTheClipboardIsTheUsersAgain() {
        exports.copy(key.toByteArray())
        exports.clearCopied()
        clipboard.setPrimaryClip(ClipData.newPlainText("note", "the user's own text"))

        exports.clearCopied()

        assertEquals("the user's own text", onClipboard())
    }

    @Test
    fun discardingWhatIsNotADocumentDoesNothing() {
        exports.discard(target)
        exports.discard(Uri.parse("file:///nowhere"))
    }

    private class Tracked : ByteArrayOutputStream() {
        var closed = false

        override fun close() {
            closed = true
            super.close()
        }
    }
}
