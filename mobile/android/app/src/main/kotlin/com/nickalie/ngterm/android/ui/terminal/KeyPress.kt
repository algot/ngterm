package com.nickalie.ngterm.android.ui.terminal

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.PressInteraction
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.AwaitPointerEventScope
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.changedToUp
import androidx.compose.ui.input.pointer.isOutOfBounds
import androidx.compose.ui.input.pointer.pointerInput

/**
 * How long a repeating key is held before its first key goes (Android's tap timeout, the time a touch has to turn
 * into a scroll or a system gesture), how long before it repeats, and how often it repeats then.
 */
private const val HOLD_DELAY_MS = 100L
private const val REPEAT_DELAY_MS = 400L
private const val REPEAT_INTERVAL_MS = 50L

/** How a press ends: the finger lifts inside the key, or the press is lost. */
private enum class PressEnd { Lifted, Lost }

/**
 * A press on the key, shown through [interactions]: [onDown] as a finger or a button goes down, [onKey] as it lifts
 * inside the key. A press that leaves the key, that moves past the touch slop, that another handler takes or that the
 * system cancels runs no [onKey]. A key that [repeats] also runs [onKey] once held a moment, then again (with
 * [onDown]) steadily until the press ends, and may drift inside the key from then on.
 */
internal fun Modifier.keyPress(
    interactions: MutableInteractionSource,
    repeats: Boolean,
    onDown: () -> Unit,
    onKey: () -> Unit,
): Modifier =
    pointerInput(interactions, repeats) {
        awaitEachGesture {
            val down = awaitFirstDown()
            down.consume()
            val pressed = PressInteraction.Press(down.position)
            interactions.tryEmit(pressed)
            onDown()
            var shown: PressInteraction = PressInteraction.Cancel(pressed)
            try {
                val end = if (repeats) held(down.position, onDown, onKey) else tapped(down.position, onKey)
                if (end == PressEnd.Lifted) shown = PressInteraction.Release(pressed)
            } finally {
                interactions.tryEmit(shown)
            }
        }
    }

private suspend fun AwaitPointerEventScope.tapped(
    from: Offset,
    onKey: () -> Unit,
): PressEnd {
    val end = pressEnd(still = from)
    if (end == PressEnd.Lifted) onKey()
    return end
}

private suspend fun AwaitPointerEventScope.held(
    from: Offset,
    onDown: () -> Unit,
    onKey: () -> Unit,
): PressEnd {
    var end = endWithin(HOLD_DELAY_MS, still = from)
    if (end == PressEnd.Lifted) onKey()
    if (end != null) return end
    onKey()
    end = endWithin(REPEAT_DELAY_MS - HOLD_DELAY_MS)
    while (end == null) {
        onDown()
        onKey()
        end = endWithin(REPEAT_INTERVAL_MS)
    }
    return end
}

/** How the press ends within [millis], or null while it is still held then. */
private suspend fun AwaitPointerEventScope.endWithin(
    millis: Long,
    still: Offset? = null,
): PressEnd? = withTimeoutOrNull(millis) { pressEnd(still) }

/** Waits for the press to end; a press that must stay [still] is also lost once it moves past the touch slop. */
private suspend fun AwaitPointerEventScope.pressEnd(still: Offset?): PressEnd {
    var end: PressEnd? = null
    while (end == null) {
        val event = awaitPointerEvent(PointerEventPass.Main)
        val lost =
            event.changes.any {
                it.isConsumed ||
                    it.isOutOfBounds(size, extendedTouchPadding) ||
                    (still != null && (it.position - still).getDistance() > viewConfiguration.touchSlop)
            }
        end =
            when {
                lost -> {
                    PressEnd.Lost
                }

                event.changes.all { it.changedToUp() } -> {
                    event.changes.forEach { it.consume() }
                    PressEnd.Lifted
                }

                awaitPointerEvent(PointerEventPass.Final).changes.any { it.isConsumed } -> {
                    PressEnd.Lost
                }

                else -> {
                    null
                }
            }
    }
    return end
}
