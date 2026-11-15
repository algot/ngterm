package com.nickalie.ngterm.android.data

import com.nickalie.ngterm.core.ffi.ClipboardPart
import com.nickalie.ngterm.core.ffi.ClipboardReadConsent
import com.nickalie.ngterm.core.ffi.ClipboardReadFacts
import com.nickalie.ngterm.core.ffi.ClipboardReply

/**
 * A device clipboard in memory, holding [contents] (each its own type), marked [sensitive] or not: what the clipboard
 * reads see in tests.
 */
class MemoryClipboard(
    @Volatile var contents: List<ClipboardPart> = emptyList(),
    @Volatile var sensitive: Boolean = false,
) : DeviceClipboard {
    /** Its text alone, as most tests set it; `null`: it holds nothing. */
    var text: String?
        get() = contents.firstOrNull { it.mime == "text/plain" }?.data?.decodeToString()
        set(value) {
            contents = listOfNotNull(value?.let { part("text/plain", it) })
        }

    /** How many times its data was read. */
    @Volatile var reads = 0
        private set

    override fun take(
        mimes: List<String>,
        list: Boolean,
    ): ClipboardSnapshot {
        if (mimes.isNotEmpty()) reads++
        val held = contents
        return ClipboardSnapshot(
            contents = mimes.mapNotNull { mime -> held.firstOrNull { it.mime == mime } },
            available = if (list) held.map { it.mime } else emptyList(),
            sensitive = sensitive,
        )
    }
}

/**
 * What the core's `clipboard_read_consent` answers, for the app's tests, which run without the native library
 * (`AndroidClipboardDeviceTest` holds the same rule to the core's on a device).
 */
fun fakeClipboardReadConsent(facts: ClipboardReadFacts): ClipboardReadConsent =
    when {
        !facts.discloses -> ClipboardReadConsent.UNASKED
        facts.sensitive -> ClipboardReadConsent.ASK_ONCE
        facts.granted || facts.trusted -> ClipboardReadConsent.UNASKED
        else -> ClipboardReadConsent.ASK
    }

fun part(
    mime: String,
    text: String,
) = ClipboardPart(mime, text.toByteArray())

/** A part as it compares in a test: its type and its bytes (a `ByteArray` compares by identity). */
fun ClipboardPart.key() = mime to data.toList()

/** A reply as it compares in a test. */
fun ClipboardReply.key(): Any =
    when (this) {
        is ClipboardReply.Allow -> Triple(contents.map { it.key() }, available, remember)
        ClipboardReply.Deny -> "deny"
    }

/** An Allow handing over [contents] and [available], keeping a grant with [remember], as it compares. */
fun allowed(
    vararg contents: ClipboardPart,
    available: List<String> = emptyList(),
    remember: Boolean = false,
): Any = ClipboardReply.Allow(contents.toList(), available, remember).key()

/** Ghostty's `clipboard-multipart.py` image, a 2x2 red PNG of 73 bytes (`crates/ngterm-ghostty-vt/tests/data`). */
val RED_PNG: ByteArray =
    java.util.Base64.getDecoder().decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR42mP4z8AARAwQCgAf7gP9Y167WwAAAABJRU5ErkJggg==",
    )
