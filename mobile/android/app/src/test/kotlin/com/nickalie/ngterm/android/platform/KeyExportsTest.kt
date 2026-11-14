package com.nickalie.ngterm.android.platform

import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
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
    fun theClipboardHoldsTheKeyMarkedSensitive() {
        exports.copy(key.toByteArray())

        val clip = context.getSystemService(ClipboardManager::class.java).primaryClip!!
        assertEquals(key, clip.getItemAt(0).text.toString())
        assertTrue(clip.description.extras.getBoolean("android.content.extra.IS_SENSITIVE"))
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
