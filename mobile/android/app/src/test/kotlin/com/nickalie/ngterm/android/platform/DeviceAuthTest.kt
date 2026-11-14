package com.nickalie.ngterm.android.platform

import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf

/** Whether the device can prove its owner, and how a prompt's end reads. */
@RunWith(AndroidJUnit4::class)
class DeviceAuthTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val keyguard = shadowOf(context.getSystemService(KeyguardManager::class.java))
    private val launched = mutableListOf<Intent>()
    private val results = mutableListOf<AuthResult>()

    private fun auth(sdk: Int) =
        SystemDeviceAuth(context, sdk) { intent, onResult ->
            launched += intent
            onResult(AuthResult.Confirmed)
        }

    @Test
    fun aDeviceIsSecuredOnlyWithAScreenLock() {
        val auth = auth(Build.VERSION.SDK_INT)

        keyguard.setIsDeviceSecure(false)
        assertFalse(auth.secured)
        keyguard.setIsDeviceSecure(true)
        assertTrue(auth.secured)
    }

    @Test
    fun beforeAndroid9TheKeyguardsCredentialScreenAsks() {
        keyguard.setIsDeviceSecure(true)

        auth(Build.VERSION_CODES.O).confirm("Export private key", "Confirm it's you") { results += it }

        assertEquals(1, launched.size)
        assertEquals(listOf<AuthResult>(AuthResult.Confirmed), results)
    }

    @Test
    fun beforeAndroid9ADeviceWithNoCredentialScreenFails() {
        keyguard.setIsDeviceSecure(false)

        auth(Build.VERSION_CODES.O).confirm("Export private key", "Confirm it's you") { results += it }

        assertTrue(launched.isEmpty())
        assertEquals(listOf<AuthResult>(AuthResult.Failed("")), results)
    }

    @Test
    fun aPromptsEndReadsAsConfirmedCancelledOrFailedWithTheDevicesWords() {
        val callback = PromptCallback { results += it }

        callback.onAuthenticationSucceeded(null)
        callback.onAuthenticationError(BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED, "Cancelled")
        callback.onAuthenticationError(BiometricPrompt.BIOMETRIC_ERROR_CANCELED, null)
        callback.onAuthenticationError(BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT, "Too many attempts")
        callback.onAuthenticationError(BiometricPrompt.BIOMETRIC_ERROR_HW_UNAVAILABLE, null)
        callback.onAuthenticationFailed()

        assertEquals(
            listOf(
                AuthResult.Confirmed,
                AuthResult.Cancelled,
                AuthResult.Cancelled,
                AuthResult.Failed("Too many attempts"),
                AuthResult.Failed(""),
            ),
            results,
        )
    }
}
