package com.nickalie.ngterm.android.platform

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.PersistableBundle
import android.provider.DocumentsContract
import androidx.annotation.ChecksSdkIntAtLeast
import java.io.FileNotFoundException
import java.io.IOException
import java.util.UUID

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

    /** Empties the clipboard if what [copy] last put there is still on it; anything else on it stays. */
    fun clearCopied()

    /** Removes the document [target] nothing was written to. */
    fun discard(target: Uri)
}

/** [KeyExports] over the system's documents and clipboard. Nothing is written anywhere else. */
class AndroidKeyExports(
    private val context: Context,
    private val sdk: Int = Build.VERSION.SDK_INT,
) : KeyExports {
    private var copied: String? = null

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
        val mark = UUID.randomUUID().toString()
        val clip = ClipData.newPlainText(LABEL, String(key, Charsets.US_ASCII))
        clip.description.extras =
            PersistableBundle().apply {
                putBoolean(IS_SENSITIVE, true)
                putString(MARK, mark)
            }
        context.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(clip)
        copied = mark
    }

    override fun clearCopied() {
        val mark = copied ?: return
        copied = null
        val clipboard = context.getSystemService(ClipboardManager::class.java)
        // an app without the focus is shown no clip: nothing to check, so nothing is cleared
        if (clipboard?.primaryClipDescription?.extras?.getString(MARK) != mark) return
        if (atLeast(Build.VERSION_CODES.P)) {
            clipboard.clearPrimaryClip()
        } else {
            // no way to empty the clipboard before Android 9: an empty clip takes the key's place
            clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
        }
    }

    @ChecksSdkIntAtLeast(parameter = 0)
    private fun atLeast(api: Int) = sdk >= api

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

        // names this app's own clip, so only that one is ever cleared
        const val MARK = "com.nickalie.ngterm.android.EXPORTED_KEY"

        // ClipDescription.EXTRA_IS_SENSITIVE, named only since Android 13; older versions ignore it
        const val IS_SENSITIVE = "android.content.extra.IS_SENSITIVE"
    }
}
