package com.nickalie.ngterm.android.ui.logs

import android.content.Context
import android.content.Intent
import android.text.format.Formatter
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.nickalie.ngterm.android.R
import com.nickalie.ngterm.android.ui.components.Banner
import com.nickalie.ngterm.android.ui.components.ConfirmDialog
import com.nickalie.ngterm.android.ui.components.CopyButton
import com.nickalie.ngterm.android.ui.components.KeyPlate
import com.nickalie.ngterm.android.ui.components.ScreenExit
import com.nickalie.ngterm.android.ui.components.ScreenFrame
import com.nickalie.ngterm.android.ui.theme.NgtermTheme
import com.nickalie.ngterm.android.ui.theme.StatusTone
import com.nickalie.ngterm.core.ffi.AppLogInterface
import java.io.File

/**
 * Settings' Logs page over the diagnostic [log]: the screen, with Share handing the exported file to the system's
 * share sheet through the app's file provider.
 */
@Composable
fun LogsRoute(
    log: AppLogInterface,
    exit: ScreenExit,
    modifier: Modifier = Modifier,
    model: LogsViewModel =
        LocalContext.current.let { context ->
            viewModel { LogsViewModel(log, File(context.cacheDir, LogsViewModel.EXPORT_DIR)) }
        },
) {
    val state by model.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val title = stringResource(R.string.logs_share_title)
    val exported = (state as? LogsUiState.Ready)?.exported
    LaunchedEffect(exported) {
        if (exported != null) {
            context.shareLog(exported, title)
            model.shared()
        }
    }
    LogsScreen(
        state = state,
        exit = exit,
        actions = LogsActions(onCopied = model::copied, onShare = model::export, onClear = model::clear),
        modifier = modifier,
    )
}

/**
 * The diagnostic log: what it holds and never holds, Copy (the lines shown), Share (the whole log as a file) and
 * Clear logs (confirmed), then the newest lines first on one plate, in mono, selectable. A line is its time, its
 * component and what happened; a warning or an error says so in a word, in the attention or error color.
 */
@Composable
fun LogsScreen(
    state: LogsUiState,
    exit: ScreenExit,
    actions: LogsActions,
    modifier: Modifier = Modifier,
) {
    ScreenFrame(modifier = modifier, title = stringResource(R.string.logs_title), exit = exit) {
        About()
        when (state) {
            LogsUiState.Loading -> Quiet(stringResource(R.string.logs_loading))
            is LogsUiState.Ready -> Log(state, actions)
        }
    }
}

@Composable
private fun About() {
    Column(verticalArrangement = Arrangement.spacedBy(NgtermTheme.spacing.sm)) {
        Text(
            stringResource(R.string.logs_holds),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            stringResource(R.string.logs_never),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface,
        )
    }
}

@Composable
private fun Quiet(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun Log(
    state: LogsUiState.Ready,
    actions: LogsActions,
) {
    var confirming by rememberSaveable { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(NgtermTheme.spacing.lg)) {
        if (state.exportFailed) Banner(StatusTone.Error, stringResource(R.string.logs_export_failed))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(NgtermTheme.spacing.sm)) {
            CopyButton(state.shown, label = stringResource(R.string.logs_copy), onCopy = actions.onCopied)
            TextButton(onClick = actions.onShare) { Text(stringResource(R.string.logs_share)) }
            TextButton(onClick = { confirming = true }) {
                Text(stringResource(R.string.logs_clear), color = MaterialTheme.colorScheme.error)
            }
        }
        Quiet(extent(state))
        if (state.lines.isEmpty()) {
            Quiet(stringResource(R.string.logs_empty))
        } else {
            KeyPlate(text = logText(state.lines), style = NgtermTheme.mono.small)
        }
    }
    if (confirming) {
        ConfirmDialog(
            title = stringResource(R.string.logs_clear_title),
            body = stringResource(R.string.logs_clear_body),
            confirmLabel = stringResource(R.string.logs_clear),
            onConfirm = {
                confirming = false
                actions.onClear()
            },
            onDismiss = { confirming = false },
        )
    }
}

// how much of the log is on screen, and that Share sends all of it
@Composable
private fun extent(state: LogsUiState.Ready): String {
    val size = Formatter.formatShortFileSize(LocalContext.current, state.totalBytes)
    val count = state.lines.size
    return if (state.cut) {
        pluralStringResource(R.plurals.logs_extent_cut, count, count, size)
    } else {
        pluralStringResource(R.plurals.logs_extent_whole, count, count, size)
    }
}

// the lines as one text: a day's date above its lines, each line's time quiet, its component strong, and a warning or
// an error named in its color
@Composable
private fun logText(lines: List<LogLine>): AnnotatedString {
    val quiet = MaterialTheme.colorScheme.onSurfaceVariant
    val words =
        mapOf(
            LogLineLevel.Warn to (stringResource(R.string.logs_level_warning) to NgtermTheme.status.attention),
            LogLineLevel.Error to (stringResource(R.string.logs_level_error) to NgtermTheme.status.error),
        )
    return buildAnnotatedString {
        var day: String? = null
        lines.forEachIndexed { index, line ->
            if (index > 0) append('\n')
            if (line.day != day && line.day.isNotEmpty()) {
                day = line.day
                withStyle(SpanStyle(color = quiet, fontWeight = FontWeight.SemiBold)) { append(line.day) }
                append('\n')
            }
            appendLine(line, quiet, words[line.level])
        }
    }
}

private fun AnnotatedString.Builder.appendLine(
    line: LogLine,
    quiet: Color,
    level: Pair<String, Color>?,
) {
    if (line.time.isNotEmpty()) {
        withStyle(SpanStyle(color = quiet)) { append(line.time) }
        append(' ')
    }
    if (line.tag.isNotEmpty()) {
        withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append(line.tag) }
        append(' ')
    }
    if (level != null) {
        withStyle(SpanStyle(color = level.second, fontWeight = FontWeight.SemiBold)) { append(level.first) }
        append(' ')
    }
    append(line.text)
}

// hands the exported file to the system's share sheet, readable by the app the user picks
private fun Context.shareLog(
    file: File,
    title: String,
) {
    val uri = FileProvider.getUriForFile(this, "$packageName.logs", file)
    val send =
        Intent(Intent.ACTION_SEND)
            .setType("text/plain")
            .putExtra(Intent.EXTRA_SUBJECT, title)
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    send.clipData = android.content.ClipData.newRawUri(title, uri)
    startActivity(Intent.createChooser(send, title))
}
