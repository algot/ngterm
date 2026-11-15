package com.nickalie.ngterm.android.platform

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.hardware.biometrics.BiometricManager.Authenticators
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.ChecksSdkIntAtLeast
import androidx.annotation.RequiresApi
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext

/** How asking the device's owner to prove it is them ended. */
sealed interface AuthResult {
    /** They did: a biometric, or the screen lock's PIN, pattern or password. */
    data object Confirmed : AuthResult

    /** They backed out. */
    data object Cancelled : AuthResult

    /** The device couldn't ask or gave up (too many attempts), in its own words. */
    data class Failed(
        val reason: String,
    ) : AuthResult
}

/** Proof that whoever holds the device is its owner, before the app hands out what only they may have. */
interface DeviceAuth {
    /** Whether the device has a screen lock: without one there is nothing to prove with. */
    val secured: Boolean

    /** Asks, under [title] and [subtitle]; [onResult] hears how it ended, on the main thread. */
    fun confirm(
        title: String,
        subtitle: String,
        onResult: (AuthResult) -> Unit,
    )
}

/**
 * The system's own prompt: a strong biometric with the screen lock's credential as the other way in (Android 10 and
 * later), the keyguard's credential screen before that, where the prompt takes no credential.
 */
@Composable
fun rememberDeviceAuth(): DeviceAuth {
    val context = LocalContext.current
    var pending by remember { mutableStateOf<((AuthResult) -> Unit)?>(null) }
    val credential =
        rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            val heard = pending
            pending = null
            heard?.invoke(if (result.resultCode == Activity.RESULT_OK) AuthResult.Confirmed else AuthResult.Cancelled)
        }
    return remember(context, credential) {
        SystemDeviceAuth(context) { intent, onResult ->
            pending = onResult
            credential.launch(intent)
        }
    }
}

/**
 * [DeviceAuth] over the system: [launchCredential] starts the keyguard's credential screen where there is no prompt.
 */
class SystemDeviceAuth(
    private val context: Context,
    private val sdk: Int = Build.VERSION.SDK_INT,
    private val launchCredential: (Intent, (AuthResult) -> Unit) -> Unit,
) : DeviceAuth {
    private val keyguard get() = context.getSystemService(KeyguardManager::class.java)

    override val secured: Boolean get() = keyguard?.isDeviceSecure == true

    override fun confirm(
        title: String,
        subtitle: String,
        onResult: (AuthResult) -> Unit,
    ) {
        if (atLeast(Build.VERSION_CODES.Q)) {
            prompt(title, subtitle, onResult)
        } else {
            @Suppress("DEPRECATION") // the only credential screen before Android 10's prompt takes one
            val intent = keyguard?.createConfirmDeviceCredentialIntent(title, subtitle)
            if (intent == null) onResult(AuthResult.Failed("")) else launchCredential(intent, onResult)
        }
    }

    @ChecksSdkIntAtLeast(parameter = 0)
    private fun atLeast(api: Int) = sdk >= api

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun prompt(
        title: String,
        subtitle: String,
        onResult: (AuthResult) -> Unit,
    ) {
        build(title, subtitle).authenticate(CancellationSignal(), context.mainExecutor, PromptCallback(onResult))
    }

    // a class 3 biometric or the credential: a weak one (a 2D face unlock) is not proof enough to release a key
    @RequiresApi(Build.VERSION_CODES.Q)
    internal fun build(
        title: String,
        subtitle: String,
    ): BiometricPrompt {
        val builder = BiometricPrompt.Builder(context).setTitle(title).setSubtitle(subtitle)
        if (atLeast(Build.VERSION_CODES.R)) {
            builder.setAllowedAuthenticators(Authenticators.BIOMETRIC_STRONG or Authenticators.DEVICE_CREDENTIAL)
        } else {
            @Suppress("DEPRECATION") // Android 10 has no setAllowedAuthenticators
            builder.setDeviceCredentialAllowed(true)
        }
        return builder.build()
    }
}

/** A prompt's end as an [AuthResult]; a finger that didn't match is not an end, the prompt stays up. */
@RequiresApi(Build.VERSION_CODES.P)
internal class PromptCallback(
    private val onResult: (AuthResult) -> Unit,
) : BiometricPrompt.AuthenticationCallback() {
    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult?) =
        onResult(AuthResult.Confirmed)

    override fun onAuthenticationError(
        errorCode: Int,
        errString: CharSequence?,
    ) = onResult(
        when (errorCode) {
            BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED,
            BiometricPrompt.BIOMETRIC_ERROR_CANCELED,
            -> AuthResult.Cancelled

            else -> AuthResult.Failed(errString?.toString().orEmpty())
        },
    )
}
