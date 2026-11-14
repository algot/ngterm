package com.nickalie.ngterm.android.data

import com.nickalie.ngterm.core.fake.FakeAppLog
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** The app's own lines of the diagnostic log, and what a crash leaves in it. */
class DiagnosticsTest {
    @After fun tearDown() {
        Diagnostics.log = null
    }

    @Test
    fun aLineGoesToTheProcessLogWithItsLevelAndTagAndNowhereBeforeOneIsSet() {
        Diagnostics.info(LogTag.APP, "lost")
        val log = FakeAppLog()
        Diagnostics.log = log
        Diagnostics.info(LogTag.NAV, "destination=settings")
        Diagnostics.warn(LogTag.CHAT_UI, "action not sent: the pane is not shown")
        Diagnostics.error(LogTag.APP, "failed")
        assertEquals(
            listOf(
                "I nav: destination=settings",
                "W chat-ui: action not sent: the pane is not shown",
                "E app: failed",
            ),
            log.lines,
        )
    }

    @Test
    fun aCrashIsLoggedByClassThreadAndFrameWithoutItsMessageThenHandedOn() {
        val log = FakeAppLog()
        Diagnostics.log = log
        var handed: Throwable? = null
        val logger = CrashLogger { _, error -> handed = error }
        val error = IllegalStateException("typed s3cret text", java.io.IOException("s3cret too"))

        logger.uncaughtException(Thread.currentThread(), error)

        assertSame(error, handed)
        val line = log.lines.single()
        assertTrue(line, line.startsWith("E app: uncaught exception class=java.lang.IllegalStateException thread="))
        assertTrue(
            line,
            " at=${javaClass.name}.aCrashIsLoggedByClassThreadAndFrameWithoutItsMessageThenHandedOn:" in line,
        )
        assertTrue(line, line.endsWith(" caused-by=java.io.IOException"))
        assertFalse(line, "s3cret" in line)
    }

    @Test
    fun aCrashWithNoHandlerBehindAndNoFramesIsStillLogged() {
        val log = FakeAppLog()
        Diagnostics.log = log
        val bare = RuntimeException().apply { stackTrace = emptyArray() }
        CrashLogger(null).uncaughtException(Thread.currentThread(), bare)
        assertTrue(log.lines.single().endsWith(" at=unknown"))
    }

    @Test
    fun installingKeepsTheHandlerThatWasThere() {
        val before = Thread.getDefaultUncaughtExceptionHandler()
        var handed = false
        try {
            Thread.setDefaultUncaughtExceptionHandler { _, _ -> handed = true }
            CrashLogger.install()
            Thread.getDefaultUncaughtExceptionHandler()?.uncaughtException(Thread.currentThread(), Error("x"))
            assertTrue(handed)
        } finally {
            Thread.setDefaultUncaughtExceptionHandler(before)
        }
    }
}
