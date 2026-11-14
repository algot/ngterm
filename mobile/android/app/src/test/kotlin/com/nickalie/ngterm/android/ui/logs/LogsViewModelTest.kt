package com.nickalie.ngterm.android.ui.logs

import com.nickalie.ngterm.android.data.Diagnostics
import com.nickalie.ngterm.core.fake.FakeAppLog
import com.nickalie.ngterm.core.ffi.LogLevel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/** The Logs screen's model over an in-memory log: what it shows, and what Copy, Share and Clear do. */
@OptIn(ExperimentalCoroutinesApi::class)
class LogsViewModelTest {
    @get:Rule val dir = TemporaryFolder()
    private val dispatcher = UnconfinedTestDispatcher()
    private val log = FakeAppLog()

    @Before fun setUp() {
        Dispatchers.setMain(dispatcher)
        Diagnostics.log = log
    }

    @After fun tearDown() {
        Diagnostics.log = null
        Dispatchers.resetMain()
    }

    private fun model() = LogsViewModel(log, File(dir.root, "export"), dispatcher)

    private fun LogsViewModel.ready() = state.value as LogsUiState.Ready

    @Test
    fun theNewestLinesComeFirstParsedAndALineInAnotherFormatKeepsItsText() {
        log.core('I', "link", "connect asked machine=m1")
        log.core('W', "ssh", "connect failed machine=m1 class=refused")
        log.append(LogLevel.ERROR, "app", "uncaught exception class=java.lang.Error")
        val ready = model().ready()
        assertEquals(
            listOf(
                LogLine(
                    "2026-11-15",
                    "10:00:02",
                    LogLineLevel.Error,
                    "app",
                    "uncaught exception class=java.lang.Error",
                ),
                LogLine("2026-11-15", "10:00:01", LogLineLevel.Warn, "ssh", "connect failed machine=m1 class=refused"),
                LogLine("2026-11-15", "10:00:00", LogLineLevel.Info, "link", "connect asked machine=m1"),
            ),
            ready.lines,
        )
        assertFalse(ready.cut)
        assertEquals(log.text(), ready.shown)
        assertEquals(log.text().length.toLong(), ready.totalBytes)
        assertEquals(
            listOf(LogLine("", "", LogLineLevel.Info, "", "not a log line")),
            parseLog("not a log line\n\n", 10),
        )
    }

    @Test
    fun aLongLogShowsItsNewestWindowAndSaysItIsCut() {
        repeat(2000) { log.core('I', "pane", "attached session=S$it pane=P1") }
        val ready = model().ready()
        assertTrue(ready.cut)
        assertEquals(LogsViewModel.MAX_LINES, ready.lines.size)
        assertEquals("attached session=S1999 pane=P1", ready.lines.first().text)
        assertTrue(ready.shown.length <= LogsViewModel.WINDOW_BYTES)
        assertTrue(ready.totalBytes > LogsViewModel.WINDOW_BYTES)
    }

    @Test
    fun shareWritesTheWholeLogToAFileAndHandsItOverOnce() {
        repeat(2000) { log.core('I', "pane", "attached session=S$it pane=P1") }
        val whole = log.text()
        val model = model()
        model.export()
        val file = requireNotNull(model.ready().exported)
        assertEquals(File(dir.root, "export/ngterm-log.txt"), file)
        assertEquals(whole, file.readText())
        assertFalse(model.ready().exportFailed)
        assertTrue(log.lines.last().startsWith("I logs: exported bytes="))
        model.shared()
        assertNull(model.ready().exported)
    }

    @Test
    fun aShareThatCannotWriteItsFileSaysSoAndIsLogged() {
        log.core('I', "link", "connect asked machine=m1")
        log.failExport = true
        val model = model()
        model.export()
        assertTrue(model.ready().exportFailed)
        assertNull(model.ready().exported)
        assertEquals("W logs: export failed: the file could not be written", log.lines.last())
        log.failExport = false
        model.export()
        assertFalse(model.ready().exportFailed)
    }

    @Test
    fun clearEmptiesTheLogAndCopyIsLogged() {
        repeat(5) { log.core('I', "link", "connect asked machine=m$it") }
        val model = model()
        model.copied()
        assertEquals(
            "copied the shown lines",
            model
                .ready()
                .lines
                .first()
                .text,
        )
        model.clear()
        assertEquals(listOf("log cleared"), model.ready().lines.map { it.text })
    }
}
