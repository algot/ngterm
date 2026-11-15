package com.nickalie.ngterm.android.ui.logs

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.nickalie.ngterm.android.data.LogTag
import com.nickalie.ngterm.core.ffi.AppLogInterface
import com.nickalie.ngterm.core.ffi.LogException
import com.nickalie.ngterm.core.ffi.LogLevel
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

/** What the Logs screen's controls do. */
data class LogsActions(
    val onCopied: () -> Unit,
    val onShare: () -> Unit,
    val onClear: () -> Unit,
)

/** What the Logs screen shows. */
sealed interface LogsUiState {
    /** The log is being read. */
    data object Loading : LogsUiState

    /**
     * The newest [lines] (newest first) and the same lines as the log wrote them, oldest first ([shown], what
     * Copy takes), out of a log of [totalBytes]; [cut] when the log holds more than is shown. [exportFailed] after
     * a Share that could not write its file; [exported] is a file ready to share, until [LogsViewModel.shared].
     */
    data class Ready(
        val lines: List<LogLine>,
        val shown: String,
        val totalBytes: Long,
        val cut: Boolean,
        val exportFailed: Boolean = false,
        val exported: File? = null,
    ) : LogsUiState
}

/**
 * The Logs screen over the diagnostic [log]: its newest window ([WINDOW_BYTES], at most [MAX_LINES] lines), read off
 * the main thread ([io]); Share writes the whole log as [EXPORT_NAME] into a directory of its own under [exportDir],
 * in place of the export before it; Clear empties it. Its own lines go to the same [log].
 */
class LogsViewModel(
    private val log: AppLogInterface,
    private val exportDir: File,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) : ViewModel() {
    private val ui = MutableStateFlow<LogsUiState>(LogsUiState.Loading)

    /** What the screen shows. */
    val state: StateFlow<LogsUiState> = ui.asStateFlow()

    init {
        refresh()
    }

    /** Reads the log again. */
    fun refresh() {
        viewModelScope.launch { ui.value = read() }
    }

    private suspend fun read(): LogsUiState.Ready =
        withContext(io) {
            val tail = log.tail(WINDOW_BYTES.toUInt())
            val total = log.size().toLong()
            val read = tail.lineSequence().filter { it.isNotBlank() }.toList()
            val shown = read.takeLast(MAX_LINES).joinToString("") { "$it\n" }
            val cut = total > tail.toByteArray().size || read.size > MAX_LINES
            LogsUiState.Ready(lines = parseLog(shown, MAX_LINES), shown = shown, totalBytes = total, cut = cut)
        }

    /** The shown lines were copied to the clipboard. */
    fun copied() {
        log.append(LogLevel.INFO, LogTag.LOGS, "copied the shown lines")
        refresh()
    }

    /** Writes the whole log to a file for the share sheet. */
    fun export() {
        viewModelScope.launch {
            val file =
                withContext(io) {
                    // a file of its own each time: an app that still reads an earlier share never gets this one
                    exportDir.deleteRecursively()
                    val target = File(File(exportDir, UUID.randomUUID().toString()), EXPORT_NAME)
                    target.parentFile?.mkdirs()
                    try {
                        val bytes = log.export(target.path)
                        log.append(LogLevel.INFO, LogTag.LOGS, "exported bytes=$bytes")
                        target
                    } catch (_: LogException) {
                        log.append(LogLevel.WARN, LogTag.LOGS, "export failed: the file could not be written")
                        null
                    }
                }
            val read = read()
            ui.value = read.copy(exported = file, exportFailed = file == null)
        }
    }

    /** The exported file went to the share sheet. */
    fun shared() {
        ui.update { if (it is LogsUiState.Ready) it.copy(exported = null) else it }
    }

    /** Deletes every line. */
    fun clear() {
        viewModelScope.launch {
            withContext(io) { log.clear() }
            ui.value = read()
        }
    }

    companion object {
        /** The most of the log's end the screen reads. */
        const val WINDOW_BYTES = 48 * 1024

        /** The most lines the screen shows. */
        const val MAX_LINES = 300

        /** The exported file's name. */
        const val EXPORT_NAME = "ngterm-log.txt"

        /** The directory under the app's cache the exports are written under (res/xml/log_paths.xml shares it). */
        const val EXPORT_DIR = "logs-export"
    }
}
