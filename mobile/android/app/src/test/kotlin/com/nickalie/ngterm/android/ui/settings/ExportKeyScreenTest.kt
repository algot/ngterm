package com.nickalie.ngterm.android.ui.settings

import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.text.TextLayoutResult
import com.nickalie.ngterm.android.FAKE_FINGERPRINT
import com.nickalie.ngterm.android.ui.theme.NgtermTheme
import com.nickalie.ngterm.core.ffi.ExportProtection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The export screen sends a key out only under a passphrase typed twice, or under none once that is confirmed. */
@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "w411dp-h891dp")
class ExportKeyScreenTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private var work by mutableStateOf(ExportWork(keyId = "k1"))
    private val saved = mutableListOf<ExportProtection>()
    private val copied = mutableListOf<ExportProtection>()
    private var back = 0

    private fun show(draft: ExportDraft = ExportDraft()) {
        compose.setContent {
            NgtermTheme {
                ExportKeyScreen(FAKE_FINGERPRINT, work, { saved += it }, { copied += it }, { back++ }, draft = draft)
            }
        }
    }

    private fun field(label: String) = compose.onNode(hasText(label) and hasSetTextAction())

    private fun tap(text: String) = compose.onNodeWithText(text).performScrollTo().performClick()

    @Test
    fun itSaysWhatTheKeyIsAndWhichOneAndKeepsTheWindowSecure() {
        show()

        compose.onNodeWithText("This is the key your machines trust.", substring = true).assertIsDisplayed()
        compose.onNodeWithText(FAKE_FINGERPRINT).assertIsDisplayed()
        compose
            .onNodeWithText(
                "A file is safer: other apps and your keyboard can read the clipboard. " +
                    "ngterm clears the key from it when you close this screen.",
            ).performScrollTo()
            .assertIsDisplayed()
        val flags = compose.activity.window.attributes.flags
        assertTrue(flags and WindowManager.LayoutParams.FLAG_SECURE != 0)
    }

    @Test
    fun nothingIsSentWithoutAPassphraseOrWithTwoThatDiffer() {
        show()

        compose.onNodeWithText("At least 8 characters.", substring = true).assertIsDisplayed()
        tap("Save to a file")
        compose.onNodeWithText("Use at least 8 characters.").assertIsDisplayed()
        field("Passphrase").performTextReplacement("correct horse")
        field("Passphrase again").performTextReplacement("correct hoarse")
        tap("Copy to the clipboard")
        compose.onNodeWithText("The two passphrases differ.").assertIsDisplayed()

        assertTrue(saved.isEmpty() && copied.isEmpty())
    }

    @Test
    fun aPassphraseUnderEightCharactersAsAPersonCountsThemSendsNothing() {
        // seven accented letters: 14 chars to the JVM, 7 to a person
        val seven = "e\u0301".repeat(7)
        show()
        field("Passphrase").performTextReplacement(seven)
        field("Passphrase again").performTextReplacement(seven)

        tap("Save to a file")
        tap("Copy to the clipboard")

        compose.onNodeWithText("Use at least 8 characters.").assertIsDisplayed()
        assertTrue(saved.isEmpty() && copied.isEmpty())

        field("Passphrase").performTextReplacement(seven + "x")
        compose.onNodeWithText("Use at least 8 characters.").assertDoesNotExist()
        compose.onNodeWithText("The two passphrases differ.").assertIsDisplayed()
        field("Passphrase again").performTextReplacement(seven + "x")
        tap("Copy to the clipboard")

        assertEquals(listOf<ExportProtection>(ExportProtection.Passphrase(seven + "x")), copied)
    }

    @Test
    fun charactersAreCountedAsAPersonCountsThem() {
        assertEquals(0, characters(""))
        assertEquals(8, characters("12345678"))
        assertEquals(8, characters("пароль12"))
        assertEquals(1, characters("e\u0301"))
    }

    @Test
    fun aPassphraseTypedTwiceGoesWithTheSaveOrTheCopy() {
        show()
        field("Passphrase").performTextReplacement("correct horse")
        field("Passphrase again").performTextReplacement("correct horse")

        tap("Save to a file")
        tap("Copy to the clipboard")

        assertEquals(listOf<ExportProtection>(ExportProtection.Passphrase("correct horse")), saved)
        assertEquals(listOf<ExportProtection>(ExportProtection.Passphrase("correct horse")), copied)
    }

    // what the two passphrase fields draw
    private fun drawn(): List<String> =
        listOf("Passphrase", "Passphrase again").map { label ->
            val layouts = mutableListOf<TextLayoutResult>()
            field(label).performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
            layouts
                .single()
                .layoutInput.text.text
        }

    @Test
    fun thePassphraseShowsOnlyWhileAsked() {
        val dots = "•".repeat("correct horse".length)
        show(ExportDraft("correct horse", "correct horse"))

        assertEquals(listOf(dots, dots), drawn())
        tap("Show passphrase")
        assertEquals(listOf("correct horse", "correct horse"), drawn())
        tap("Hide passphrase")
        assertEquals(listOf(dots, dots), drawn())
    }

    @Test
    fun exportingWithoutAPassphraseIsWarnedAndConfirmedFirst() {
        show()

        tap("Export without a passphrase")
        compose.onNodeWithText("Without a passphrase the exported key isn't encrypted", substring = true).assertExists()
        compose.onNode(hasText("Passphrase") and hasSetTextAction()).assertDoesNotExist()
        tap("Save to a file")
        compose.onNodeWithText("Export without a passphrase?").assertIsDisplayed()
        compose.onNodeWithText("Cancel").performClick()
        assertTrue(saved.isEmpty())

        tap("Copy to the clipboard")
        compose.onAllNodes(hasText("Export without a passphrase"))[1].performClick()

        assertEquals(listOf<ExportProtection>(ExportProtection.Unprotected), copied)
        assertTrue(saved.isEmpty())
        compose.onNodeWithText("Export without a passphrase?").assertDoesNotExist()
    }

    @Test
    fun itShowsTheExportWorkingThenHowItWent() {
        work = ExportWork(keyId = "k1", busy = true)
        show(ExportDraft("correct horse", "correct horse"))

        compose.onNodeWithText("Exporting the key").performScrollTo().performClick()
        compose.onNodeWithText("Copy to the clipboard").assertIsNotEnabled()
        assertTrue(saved.isEmpty())

        work = ExportWork(keyId = "k1", done = ExportDone.Saved)
        compose.onNodeWithText("Saved. Delete the file once you've imported the key.").assertExists()
        work = ExportWork(keyId = "k1", done = ExportDone.Copied)
        compose.onNodeWithText("Copied. Paste it", substring = true).assertExists()
        work = ExportWork(keyId = "k1", problem = ExportProblem.Failed("no space left"))
        compose.onNodeWithText("The key couldn't be exported: no space left").assertExists()
        work = ExportWork(keyId = "k1", problem = ExportProblem.Expired)
        compose.onNodeWithText("It's been a while since you unlocked. Go back and export again.").assertExists()
        work = ExportWork(keyId = "k1", problem = ExportProblem.Interrupted)
        compose.onNodeWithText("ngterm was restarted while you chose the file", substring = true).assertExists()
        work = ExportWork(keyId = "k1", problem = ExportProblem.ShortPassphrase(8))
        compose.onNodeWithText("Use at least 8 characters.").assertExists()
        work = ExportWork(keyId = "k1", problem = ExportProblem.Gone)
        compose.onNodeWithText("This key is no longer on this device.").assertExists()
    }

    @Test
    fun backLeaves() {
        show()

        compose
            .onNode(
                androidx.compose.ui.test
                    .hasContentDescription("Back"),
            ).performClick()

        assertEquals(1, back)
    }
}
