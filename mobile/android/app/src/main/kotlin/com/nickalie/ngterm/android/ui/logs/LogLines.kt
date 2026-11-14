package com.nickalie.ngterm.android.ui.logs

/** A line's level, as the log writes it. */
enum class LogLineLevel { Info, Warn, Error }

/**
 * One line of the diagnostic log as the screen shows it: its [day] (`2026-11-15`) and [time] (`10:11:12`), both UTC
 * as written, its [level], its component [tag] and its [text]. A line not in the log's format keeps all of it as its
 * text.
 */
data class LogLine(
    val day: String,
    val time: String,
    val level: LogLineLevel,
    val tag: String,
    val text: String,
)

private const val DAY = 1
private const val TIME = 2
private const val LEVEL = 3
private const val TAG = 4
private const val TEXT = 5

private val Line = Regex("""^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})\.\d{3}Z ([IWE]) ([^ :]+): (.*)$""")

/** [raw] (the log's text, oldest line first) as lines, newest first, at most [limit] of them. */
fun parseLog(
    raw: String,
    limit: Int,
): List<LogLine> =
    raw
        .lineSequence()
        .filter { it.isNotBlank() }
        .toList()
        .takeLast(limit)
        .asReversed()
        .map(::parseLine)

private fun parseLine(line: String): LogLine {
    val match = Line.matchEntire(line) ?: return LogLine("", "", LogLineLevel.Info, "", line)
    val part = match.groupValues
    val level =
        when (part[LEVEL]) {
            "W" -> LogLineLevel.Warn
            "E" -> LogLineLevel.Error
            else -> LogLineLevel.Info
        }
    return LogLine(part[DAY], part[TIME], level, part[TAG], part[TEXT])
}
