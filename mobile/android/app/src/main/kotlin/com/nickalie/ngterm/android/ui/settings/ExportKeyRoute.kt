package com.nickalie.ngterm.android.ui.settings

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.nickalie.ngterm.android.R
import com.nickalie.ngterm.android.data.AppKey
import com.nickalie.ngterm.android.data.PassphraseRule
import com.nickalie.ngterm.android.platform.AuthResult
import com.nickalie.ngterm.android.platform.DeviceAuth
import com.nickalie.ngterm.android.ui.components.ConfirmDialog
import com.nickalie.ngterm.core.ffi.ExportProtection

// a private key file has no type of its own; this one keeps the system from adding an extension
private const val KEY_FILE_TYPE = "application/octet-stream"

/** Why Export private key didn't open the export. */
private sealed interface ExportNotice {
    /** The device has no screen lock, so its owner can't prove it is them. */
    data object NoLock : ExportNotice

    /** The device couldn't confirm the owner of [keyId]'s export, for [reason]. */
    data class AuthFailed(
        val keyId: String,
        val reason: String,
    ) : ExportNotice
}

/**
 * What Export private key does for a key's id: [auth] asks the device's owner to prove it is them, and only then
 * [onUnlock] hears the id. A device with no screen lock is told to set one, with the system's security settings
 * one tap away; a device that couldn't ask says why, with Try again. Backing out of the prompt does nothing.
 */
@Composable
internal fun rememberExportStart(
    auth: DeviceAuth,
    onUnlock: (String) -> Unit,
): (String) -> Unit {
    val context = LocalContext.current
    val unlocked by rememberUpdatedState(onUnlock)
    val title = stringResource(R.string.export_auth_title)
    val subtitle = stringResource(R.string.export_auth_subtitle)
    var notice by remember { mutableStateOf<ExportNotice?>(null) }
    val start =
        remember(auth, title, subtitle) {
            { keyId: String ->
                if (auth.secured) {
                    auth.confirm(title, subtitle) { result ->
                        when (result) {
                            AuthResult.Confirmed -> unlocked(keyId)
                            AuthResult.Cancelled -> Unit
                            is AuthResult.Failed -> notice = ExportNotice.AuthFailed(keyId, result.reason)
                        }
                    }
                } else {
                    notice = ExportNotice.NoLock
                }
            }
        }
    when (val shown = notice) {
        null -> {}

        ExportNotice.NoLock -> {
            ConfirmDialog(
                title = stringResource(R.string.export_no_lock_title),
                body = stringResource(R.string.export_no_lock_body),
                confirmLabel = stringResource(R.string.export_no_lock_action),
                onConfirm = {
                    notice = null
                    context.openSecuritySettings()
                },
                onDismiss = { notice = null },
                destructive = false,
            )
        }

        is ExportNotice.AuthFailed -> {
            ConfirmDialog(
                title = stringResource(R.string.export_auth_failed_title),
                body =
                    if (shown.reason.isBlank()) {
                        stringResource(R.string.export_auth_failed_body)
                    } else {
                        stringResource(R.string.export_auth_failed_reason, shown.reason)
                    },
                confirmLabel = stringResource(R.string.export_auth_retry),
                onConfirm = {
                    notice = null
                    start(shown.keyId)
                },
                onDismiss = { notice = null },
                destructive = false,
            )
        }
    }
    return start
}

/** What the export screen asks of its view model: [start] hears each tap on Save or Copy, before anything else. */
internal class ExportHandlers(
    val start: () -> Unit,
    val save: (Uri, ExportProtection?) -> Unit,
    val copy: (ExportProtection) -> Unit,
    val back: () -> Unit,
)

internal fun ExportKeyViewModel.handlers() = ExportHandlers(::begin, ::save, ::copy, ::close)

/**
 * The export screen of [key], its passphrase held to [rule]: Save to a file opens the system's screen for making a
 * document and hands [ExportHandlers.save] the one the user makes, with the protection chosen (none when it was lost:
 * it waits here, in memory only, while the system's screen is up); Copy hands [ExportHandlers.copy] the protection.
 */
@Composable
internal fun ExportKeyPage(
    key: AppKey,
    work: ExportWork,
    rule: PassphraseRule,
    on: ExportHandlers,
    modifier: Modifier = Modifier,
) {
    var chosen by remember { mutableStateOf<ExportProtection?>(null) }
    val create =
        rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(KEY_FILE_TYPE)) { target ->
            val protection = chosen
            chosen = null
            if (target != null) on.save(target, protection)
        }
    val name = stringResource(R.string.export_file_name)
    ExportKeyScreen(
        fingerprint = key.fingerprint,
        work = work,
        rule = rule,
        onSave = {
            chosen = it
            create.launch(name)
        },
        onCopy = on.copy,
        onBack = on.back,
        modifier = modifier,
        onStart = on.start,
    )
}

private fun Context.openSecuritySettings() {
    try {
        startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    } catch (_: ActivityNotFoundException) {
        startActivity(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
