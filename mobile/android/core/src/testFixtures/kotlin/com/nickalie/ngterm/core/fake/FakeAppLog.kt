package com.nickalie.ngterm.core.fake

import com.nickalie.ngterm.core.ffi.AppLogInterface
import com.nickalie.ngterm.core.ffi.LogException
import com.nickalie.ngterm.core.ffi.LogLevel
import java.io.File

/**
 * The core's diagnostic log, kept in memory for the app's tests: lines in the core's format, each stamped a second
 * after the one before from [FIRST_SECOND] of 15 November 2026, so a screen's golden never changes with the clock.
 * [core] adds a line as the core itself would write it (its level's letter, its tag, its text).
 */
class FakeAppLog : AppLogInterface {
    private val kept = mutableListOf<String>()
    private var second = FIRST_SECOND

    /** Makes [export] fail, as a file that can't be written would. */
    @Volatile var failExport = false

    /** The lines the log holds, oldest first, without their timestamps. */
    val lines: List<String> get() = synchronized(kept) { kept.map { it.substringAfter(' ') } }

    @Synchronized
    private fun stamp(): String {
        val at = second++
        return "2026-11-15T%02d:%02d:%02d.000Z".format(at / HOUR % DAY_HOURS, at / MINUTE % MINUTE, at % MINUTE)
    }

    /** A line of the core's own: [letter] is its level's (`I`, `W`, `E`). */
    fun core(
        letter: Char,
        tag: String,
        text: String,
    ) {
        val line = "${stamp()} $letter $tag: $text"
        synchronized(kept) { kept += line }
    }

    override fun append(
        level: LogLevel,
        tag: String,
        message: String,
    ) {
        val letter =
            when (level) {
                LogLevel.INFO -> 'I'
                LogLevel.WARN -> 'W'
                LogLevel.ERROR -> 'E'
            }
        core(letter, tag, message.replace('\n', ' '))
    }

    override fun text(): String = synchronized(kept) { kept.joinToString("") { "$it\n" } }

    override fun tail(maxBytes: UInt): String {
        val all = text()
        if (all.length <= maxBytes.toInt()) return all
        return all.takeLast(maxBytes.toInt()).substringAfter('\n')
    }

    override fun export(path: String): ULong {
        if (failExport) throw LogException.Io("the file could not be written")
        val text = text()
        File(path).writeText(text)
        return text.toByteArray().size.toULong()
    }

    override fun size(): ULong = text().toByteArray().size.toULong()

    override fun clear() {
        synchronized(kept) { kept.clear() }
        core('I', "log", "log cleared")
    }

    private companion object {
        const val FIRST_SECOND = 36_000
        const val HOUR = 3600
        const val MINUTE = 60
        const val DAY_HOURS = 24
    }
}
