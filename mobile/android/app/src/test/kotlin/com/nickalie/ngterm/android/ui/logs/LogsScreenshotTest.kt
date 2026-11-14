package com.nickalie.ngterm.android.ui.logs

import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onRoot
import com.github.takahirom.roborazzi.captureRoboImage
import com.nickalie.ngterm.android.R
import com.nickalie.ngterm.android.ui.InScaffold
import com.nickalie.ngterm.android.ui.ScreensScreenshotTest
import com.nickalie.ngterm.android.ui.Window
import com.nickalie.ngterm.android.ui.WindowRule
import com.nickalie.ngterm.android.ui.components.ScreenExit
import com.nickalie.ngterm.android.ui.theme.NgtermTheme
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.annotation.GraphicsMode

private val SampleLog =
    listOf(
        "2026-11-15T10:12:44.120Z I chat: action action=prompt outcome=not-on-screen screen=unknown pane=B1",
        "2026-11-15T10:12:41.903Z I pane: role role=leader covered=false session=A1 pane=B1",
        "2026-11-15T10:12:40.377Z I sessions: listing answered answer=sessions peer=ngterm sessions=3 host=build-01",
        "2026-11-15T10:12:39.850Z I link: machine connected machine=m1",
        "2026-11-15T10:12:39.200Z I ssh: authenticated machine=m1",
        "2026-11-15T10:12:21.004Z W link: machine reconnecting machine=m1 next_in_ms=2000",
        "2026-11-15T10:12:20.998Z W link: connection lost machine=m1",
        "2026-11-14T23:58:02.611Z E app: uncaught exception class=java.lang.IllegalStateException thread=main",
        "2026-11-14T23:57:10.000Z I app: started version=0.2.4 android=36 device=Pixel 9",
    ).reversed().joinToString("") { "$it\n" }

private fun ready(
    text: String,
    cut: Boolean = false,
    failed: Boolean = false,
) = LogsUiState.Ready(
    lines = parseLog(text, LogsViewModel.MAX_LINES),
    shown = text,
    totalBytes = if (cut) 412_000 else text.length.toLong(),
    cut = cut,
    exportFailed = failed,
)

/**
 * The Logs screen rendered by Robolectric and compared with its goldens (src/test/screenshots/logs): a log with a
 * warning, an error and two days; a log longer than the screen shows after a Share that failed; one with nothing in
 * it; and the log being read, in the windows of [ScreensScreenshotTest].
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class LogsScreenshotTest(
    private val window: Window,
) {
    private val compose = createComposeRule()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(WindowRule(window)).around(compose)

    private fun capture(
        name: String,
        state: LogsUiState,
    ) {
        compose.setContent {
            NgtermTheme {
                InScaffold { LogsScreen(state, ScreenExit(R.drawable.ic_back, "Back") {}, LogsActions({}, {}, {})) }
            }
        }
        compose.onRoot().captureRoboImage("src/test/screenshots/logs/${name}_$window.png")
    }

    @Test fun lines() = capture("logs", ready(SampleLog))

    @Test fun cutAfterAFailedShare() = capture("logs_cut_failed", ready(SampleLog, cut = true, failed = true))

    @Test fun empty() = capture("logs_empty", ready(""))

    @Test fun loading() = capture("logs_loading", LogsUiState.Loading)

    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}")
        fun windows() = ScreensScreenshotTest.windows()
    }
}
