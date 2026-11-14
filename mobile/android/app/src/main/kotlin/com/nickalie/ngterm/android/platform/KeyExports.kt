package com.nickalie.ngterm.android.platform

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.PersistableBundle
import android.provider.DocumentsContract
import java.io.FileNotFoundException
import java.io.IOException

/** Where an exported private key goes; what it is handed is the caller's to wipe. */
interface KeyExports {
    /**
     * Writes [key] as the whole of the document [target] the user made; a document left partly written is removed.
     * Whatever the document's provider refuses with is an [IOException].
     */
    @Throws(IOException::class)
    fun save(
        target: Uri,
        key: ByteArray,
    )

    /** Puts [key] on the clipboard, marked sensitive so the system's preview and other devices don't show it. */
    fun copy(key: ByteArray)

    /** Removes the document [target] nothing was written to. */
    fun discard(target: Uri)
}

/** [KeyExports] over the system's documents and clipboard. Nothing is written anywhere else. */
class AndroidKeyExports(
    private val context: Context,
) : KeyExports {
    override fun save(
        target: Uri,
        key: ByteArray,
    ) {
        try {
            val stream = context.contentResolver.openOutputStream(target, "wt") ?: throw FileNotFoundException()
            stream.use { it.write(key) }
        } catch (error: IOException) {
            discard(target)
            throw error
        } catch (expected: RuntimeException) {
            // a provider's own refusal crosses the binder as it was thrown: no access, an unknown mode or URI
            discard(target)
            throw IOException(expected.message, expected)
        }
    }

    override fun copy(key: ByteArray) {
        val clip = ClipData.newPlainText(LABEL, String(key, Charsets.US_ASCII))
        clip.description.extras = PersistableBundle().apply { putBoolean(IS_SENSITIVE, true) }
        context.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(clip)
    }

    override fun discard(target: Uri) {
        try {
            DocumentsContract.deleteDocument(context.contentResolver, target)
        } catch (_: FileNotFoundException) {
            // already gone
        } catch (_: RuntimeException) {
            // not a document URI, or the provider keeps it: the user sees an empty file and can remove it
        }
    }

    private companion object {
        const val LABEL = "ngterm private key"

        // ClipDescription.EXTRA_IS_SENSITIVE, named only since Android 13; older versions ignore it
        const val IS_SENSITIVE = "android.content.extra.IS_SENSITIVE"
    }
}
