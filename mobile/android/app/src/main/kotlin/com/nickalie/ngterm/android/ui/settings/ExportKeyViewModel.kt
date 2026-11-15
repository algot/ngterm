package com.nickalie.ngterm.android.ui.settings

import android.net.Uri
import android.os.SystemClock
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nickalie.ngterm.android.data.AppKeys
import com.nickalie.ngterm.android.data.PassphraseRule
import com.nickalie.ngterm.android.platform.KeyExports
import com.nickalie.ngterm.android.ui.onboarding.describe
import com.nickalie.ngterm.core.ffi.ExportProtection
import com.nickalie.ngterm.core.ffi.KeyException
import com.nickalie.ngterm.core.ffi.VaultException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.IOException

/** What the export screen starts with: its tests fill it, the app starts empty. */
data class ExportDraft(
    val passphrase: String = "",
    val again: String = "",
    val unprotected: Boolean = false,
)

/** Where an export went. */
enum class ExportDone { Saved, Copied }

/** Why an export didn't happen. */
sealed interface ExportProblem {
    /** The proof that it is the owner is too old: they confirm again. */
    data object Expired : ExportProblem

    /** The passphrase was lost while the system's file screen was up (the app was restarted under it). */
    data object Interrupted : ExportProblem

    /** The passphrase has fewer than [minimum] characters. */
    data class ShortPassphrase(
        val minimum: Int,
    ) : ExportProblem

    /** The key is no longer on this device. */
    data object Gone : ExportProblem

    /** The key couldn't be read or written out, for [reason]. */
    data class Failed(
        val reason: String,
    ) : ExportProblem
}

/** Where exporting a key stands. */
data class ExportWork(
    /** The key being exported, once its owner has confirmed it is them; none otherwise. */
    val keyId: String? = null,
    val busy: Boolean = false,
    val done: ExportDone? = null,
    val problem: ExportProblem? = null,
)

/**
 * Exporting one of [keys]' private keys through [exports]. Nothing leaves before [unlock], which the route calls
 * only once the device's owner has confirmed it is them, and which lasts [UNLOCKED_FOR_MS] by [now] or until
 * [close], which also takes a copied key back off the clipboard. The exported bytes are wiped once handed over; the
 * unsealed key never reaches this class.
 */
class ExportKeyViewModel(
    private val keys: AppKeys,
    private val exports: KeyExports,
    private val now: () -> Long = SystemClock::elapsedRealtime,
) : ViewModel() {
    private val state = MutableStateFlow(ExportWork())
    private var unlockedAt = 0L

    // which showing of the screen this is: an export begun under an earlier one delivers and says nothing
    private var showing = 0

    /** Where the export stands. */
    val work: StateFlow<ExportWork> = state.asStateFlow()

    /** What an export's passphrase must meet, as the exporter counts it. */
    val rule: PassphraseRule get() = keys.exportRule

    /** The owner confirmed it is them: [keyId] can be exported. */
    fun unlock(keyId: String) {
        showing++
        unlockedAt = now()
        state.value = ExportWork(keyId = keyId)
    }

    /**
     * The export screen is left: nothing can be exported until the owner confirms again, and a key copied from it
     * leaves the clipboard.
     */
    fun close() {
        showing++
        state.value = ExportWork()
        try {
            exports.clearCopied()
        } catch (_: RuntimeException) {
            // a clipboard that refuses keeps what it has; leaving the screen never crashes on it
        }
    }

    /** An export is asked for: what the last one said no longer stands, whether or not this one gets to write. */
    fun begin() {
        state.value = state.value.copy(done = null, problem = null)
    }

    /** Saves the key under [protection] into the document [target] the user made. */
    fun save(
        target: Uri,
        protection: ExportProtection?,
    ) {
        if (protection == null || !ready()) {
            exports.discard(target)
            if (protection == null && state.value.keyId != null) {
                state.value = state.value.copy(done = null, problem = ExportProblem.Interrupted)
            }
            return
        }
        export(protection, ExportDone.Saved, unmade = { exports.discard(target) }) {
            withContext(Dispatchers.IO) { exports.save(target, it) }
        }
    }

    /** Copies the key under [protection] to the clipboard. */
    fun copy(protection: ExportProtection) {
        val begun = showing
        // a copy that is ready only after the screen was left would stay on the clipboard: it isn't made
        if (ready()) export(protection, ExportDone.Copied) { if (showing == begun) exports.copy(it) }
    }

    // whether an export may start: a key is unlocked, recently enough, and none is under way
    private fun ready(): Boolean {
        val current = state.value
        val idle = current.keyId != null && !current.busy
        val fresh = now() - unlockedAt <= UNLOCKED_FOR_MS
        if (idle && !fresh) state.value = current.copy(done = null, problem = ExportProblem.Expired)
        return idle && fresh
    }

    // [unmade] runs when there was no export to [deliver]: what was made ready for it is taken back
    private fun export(
        protection: ExportProtection,
        done: ExportDone,
        unmade: () -> Unit = {},
        deliver: suspend (ByteArray) -> Unit,
    ) {
        val keyId = state.value.keyId ?: return
        val begun = showing
        state.value = state.value.copy(busy = true, done = null, problem = null)
        viewModelScope.launch {
            var exported: ByteArray? = null
            val problem =
                try {
                    exported = keys.export(keyId, protection)
                    deliver(exported)
                    null
                } catch (error: KeyException.PassphraseTooShort) {
                    ExportProblem.ShortPassphrase(error.minimum.toInt())
                } catch (error: KeyException) {
                    ExportProblem.Failed(error.describe())
                } catch (_: VaultException.Missing) {
                    ExportProblem.Gone
                } catch (error: VaultException.Unavailable) {
                    ExportProblem.Failed(error.reason)
                } catch (error: IOException) {
                    ExportProblem.Failed(error.describe())
                } catch (error: CancellationException) {
                    throw error
                } catch (expected: RuntimeException) {
                    // what the Keystore or the clipboard throws unchecked: said in words, never a crash
                    ExportProblem.Failed(expected.describe())
                } finally {
                    if (exported != null) exported.fill(0) else unmade()
                }
            // an export that ends after the screen was left says nothing, to that screen or to one opened since
            if (showing == begun) {
                state.value = state.value.copy(busy = false, done = done.takeIf { problem == null }, problem = problem)
            }
        }
    }

    private companion object {
        const val UNLOCKED_FOR_MS = 5 * 60 * 1000L
    }
}
