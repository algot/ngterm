package com.nickalie.ngterm.android.data

import com.nickalie.ngterm.core.ffi.AppLogInterface
import com.nickalie.ngterm.core.ffi.LogLevel

/**
 * Where the app writes its own lines of the diagnostic log (the core writes its own): the process's [log], set once
 * the application has opened it, and nothing before. A line says what happened in the app (a destination opened, the
 * app left the screen, a message was not sent and why), never what the user typed, a message's text, terminal
 * output, a key or a passphrase.
 */
object Diagnostics {
    /** The process's log; `null` until the application opens it (and in tests that set none). */
    @Volatile var log: AppLogInterface? = null

    /** Writes an ordinary event of the component [tag]. */
    fun info(
        tag: String,
        message: String,
    ) = write(LogLevel.INFO, tag, message)

    /** Writes something that went wrong but the app went on from. */
    fun warn(
        tag: String,
        message: String,
    ) = write(LogLevel.WARN, tag, message)

    /** Writes a failure. */
    fun error(
        tag: String,
        message: String,
    ) = write(LogLevel.ERROR, tag, message)

    private fun write(
        level: LogLevel,
        tag: String,
        message: String,
    ) {
        log?.append(level, tag, message)
    }
}

/** The app's own component tags. */
object LogTag {
    /** The process: started, on screen or not, the network, a crash. */
    const val APP = "app"

    /** Where the user went. */
    const val NAV = "nav"

    /** The chat view's own decisions about a message. */
    const val CHAT_UI = "chat-ui"

    /** The Logs screen's actions. */
    const val LOGS = "logs"
}

/**
 * Logs an uncaught exception before the handler that was there ([next]) ends the process: its class, its thread and
 * the frame it was thrown from, and each cause's class. Never its message, which may quote what the user typed or a
 * machine printed.
 */
class CrashLogger(
    private val next: Thread.UncaughtExceptionHandler?,
) : Thread.UncaughtExceptionHandler {
    override fun uncaughtException(
        thread: Thread,
        error: Throwable,
    ) {
        Diagnostics.error(LogTag.APP, crashLine(thread.name, error))
        next?.uncaughtException(thread, error)
    }

    companion object {
        /** Puts a [CrashLogger] before the process's handler. */
        fun install() {
            Thread.setDefaultUncaughtExceptionHandler(CrashLogger(Thread.getDefaultUncaughtExceptionHandler()))
        }
    }
}

private const val MAX_CAUSES = 4

/** What the log says of an uncaught [error] on [thread]. */
internal fun crashLine(
    thread: String,
    error: Throwable,
): String {
    val causes = generateSequence(error.cause) { it.cause }.take(MAX_CAUSES).map { it.javaClass.name }.toList()
    val at = error.stackTrace.firstOrNull()?.let { "${it.className}.${it.methodName}:${it.lineNumber}" } ?: "unknown"
    val caused = if (causes.isEmpty()) "" else " caused-by=${causes.joinToString(",")}"
    return "uncaught exception class=${error.javaClass.name} thread=$thread at=$at$caused"
}
