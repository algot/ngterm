package com.nickalie.ngterm.android

import android.net.Uri
import com.nickalie.ngterm.android.platform.AuthResult
import com.nickalie.ngterm.android.platform.DeviceAuth
import com.nickalie.ngterm.android.platform.KeyExports
import java.io.IOException

/** A device whose owner answers the prompt with [answer] (none: the prompt stays up), lock screen [secured]. */
class FakeDeviceAuth(
    override var secured: Boolean = true,
    var answer: AuthResult? = AuthResult.Confirmed,
) : DeviceAuth {
    /** The prompts shown: their title and subtitle. */
    val prompts = mutableListOf<Pair<String, String>>()

    override fun confirm(
        title: String,
        subtitle: String,
        onResult: (AuthResult) -> Unit,
    ) {
        prompts += title to subtitle
        answer?.let(onResult)
    }
}

/** Where exports go in tests: what was saved and copied as text, and the bytes handed over, wiped by the app after. */
class FakeKeyExports : KeyExports {
    val saved = mutableMapOf<Uri, String>()
    val copied = mutableListOf<String>()
    val discarded = mutableListOf<Uri>()

    /** What is on the clipboard: the fake's own copy, or what a test puts there as another app would. */
    var clipboard: String? = null
    private var mine: String? = null
    val handed = mutableListOf<ByteArray>()

    /** When set, [save] fails with it. */
    var saveFailure: Exception? = null

    override fun save(
        target: Uri,
        key: ByteArray,
    ) {
        handed += key
        saveFailure?.let { throw it }
        saved[target] = String(key)
    }

    override fun copy(key: ByteArray) {
        handed += key
        copied += String(key)
        clipboard = copied.last()
        mine = clipboard
    }

    /** When set, [clearCopied] fails with it. */
    var clearFailure: RuntimeException? = null

    override fun clearCopied() {
        clearFailure?.let { throw it }
        if (mine != null && clipboard === mine) clipboard = null
        mine = null
    }

    override fun discard(target: Uri) {
        discarded += target
    }
}
