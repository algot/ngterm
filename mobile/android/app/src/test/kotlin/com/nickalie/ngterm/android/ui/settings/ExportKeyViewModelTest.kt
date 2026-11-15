package com.nickalie.ngterm.android.ui.settings

import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.nickalie.ngterm.android.FakeKeyExports
import com.nickalie.ngterm.android.TestGraph
import com.nickalie.ngterm.android.data.AppKeys
import com.nickalie.ngterm.android.fakeExport
import com.nickalie.ngterm.android.platform.KeyWrapper
import com.nickalie.ngterm.android.platform.KeystoreKeyVault
import com.nickalie.ngterm.android.testStore
import com.nickalie.ngterm.core.ffi.ExportProtection
import com.nickalie.ngterm.core.ffi.KeyException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import java.io.File
import java.io.IOException
import java.security.GeneralSecurityException
import java.util.concurrent.CountDownLatch

/** A key leaves only after its owner unlocked it, for a while, the way they chose, and its bytes are wiped after. */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(AndroidJUnit4::class)
class ExportKeyViewModelTest {
    @get:Rule
    val dir = TemporaryFolder()

    private lateinit var test: TestGraph
    private val exports = FakeKeyExports()
    private var now = 0L
    private val locked = ExportProtection.Passphrase("correct horse")
    private val target = Uri.parse("content://documents/ngterm-private-key")
    private val stored = "fake private key 1"

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        test = TestGraph(dir.root)
    }

    @After
    fun tearDown() {
        test.close()
        Dispatchers.resetMain()
    }

    private fun model() = ExportKeyViewModel(test.graph.keys, exports) { now }

    private fun ExportKeyViewModel.settled(): ExportWork {
        val deadline = System.currentTimeMillis() + 10_000
        while (work.value.busy) {
            check(System.currentTimeMillis() < deadline) { "the export never ended" }
            Thread.sleep(10)
        }
        return work.value
    }

    @Test
    fun nothingLeavesBeforeTheOwnerUnlocksTheKey() {
        test.seedKey()
        val model = model()

        model.copy(locked)
        model.save(target, locked)

        assertEquals(ExportWork(), model.settled())
        assertTrue(exports.copied.isEmpty() && exports.saved.isEmpty())
        assertTrue(test.maker.exportedFrom.isEmpty())
        assertEquals("the document made for it is removed", listOf(target), exports.discarded)
    }

    @Test
    fun anUnlockedKeyIsCopiedUnderItsPassphraseAndTheBytesHandedOverAreWiped() {
        val key = test.seedKey()
        val model = model()
        model.unlock(key.id)

        model.copy(locked)

        assertEquals(ExportWork(keyId = key.id, done = ExportDone.Copied), model.settled())
        assertEquals(listOf(fakeExport(stored, "correct horse")), exports.copied)
        assertTrue(exports.handed.single().all { it == 0.toByte() })
        assertTrue(
            test.maker.exportedFrom
                .single()
                .all { it == 0.toByte() },
        )
    }

    @Test
    fun anUnlockedKeyIsSavedIntoTheDocumentTheUserMade() {
        val key = test.seedKey()
        val model = model()
        model.unlock(key.id)

        model.save(target, ExportProtection.Unprotected)

        assertEquals(ExportDone.Saved, model.settled().done)
        assertEquals(mapOf(target to stored), exports.saved)
        assertTrue(exports.handed.single().all { it == 0.toByte() })
        assertTrue(exports.discarded.isEmpty())
    }

    @Test
    fun aSaveThatFailsSaysWhyAndStillWipesTheBytes() {
        val key = test.seedKey()
        val model = model()
        model.unlock(key.id)
        exports.saveFailure = IOException("no space left")

        model.save(target, locked)

        assertEquals(ExportWork(keyId = key.id, problem = ExportProblem.Failed("no space left")), model.settled())
        assertTrue(exports.handed.single().all { it == 0.toByte() })
    }

    @Test
    fun aProvidersOwnRefusalIsAProblemInWordsNotACrash() {
        val key = test.seedKey()
        val model = model()
        model.unlock(key.id)
        exports.saveFailure = UnsupportedOperationException("mode wt is not supported")

        model.save(target, locked)

        assertEquals(
            ExportWork(keyId = key.id, problem = ExportProblem.Failed("mode wt is not supported")),
            model.settled(),
        )
        assertTrue(exports.handed.single().all { it == 0.toByte() })
    }

    @Test
    fun aSaveWithNoExportToWriteRemovesTheDocumentMadeForIt() {
        val key = test.seedKey()
        val model = model()
        model.unlock(key.id)
        test.maker.exportFailure = KeyException.Invalid("not a stored key")
        model.save(target, locked)
        assertEquals(ExportProblem.Failed("not a stored key"), model.settled().problem)
        assertEquals(listOf(target), exports.discarded)

        test.vault.delete(key.id)
        model.save(target, locked)
        assertEquals(ExportProblem.Gone, model.settled().problem)
        assertEquals(listOf(target, target), exports.discarded)
        assertTrue(exports.handed.isEmpty() && exports.saved.isEmpty())

        model.copy(locked)
        assertEquals(ExportProblem.Gone, model.settled().problem)
        assertEquals("a copy made no document", 2, exports.discarded.size)
    }

    @Test
    fun theUnlockRunsOutAfterFiveMinutesAndLeavingLocksAtOnce() {
        val key = test.seedKey()
        val model = model()
        model.unlock(key.id)
        now += 5 * 60 * 1000L
        model.copy(locked)
        assertEquals(ExportDone.Copied, model.settled().done)

        now += 1
        model.copy(locked)
        model.save(target, locked)

        assertEquals(ExportWork(keyId = key.id, problem = ExportProblem.Expired), model.settled())
        assertEquals(1, exports.copied.size)
        assertEquals(listOf(target), exports.discarded)

        model.unlock(key.id)
        model.close()
        model.copy(locked)
        assertEquals(ExportWork(), model.settled())
        assertEquals(1, exports.copied.size)
    }

    @Test
    fun aSaveWhoseProtectionWasLostWritesNothingAndSaysSo() {
        val key = test.seedKey()
        val model = model()
        model.unlock(key.id)

        model.save(target, null)

        assertEquals(ExportWork(keyId = key.id, problem = ExportProblem.Interrupted), model.settled())
        assertTrue(exports.saved.isEmpty() && test.maker.exportedFrom.isEmpty())
        assertEquals(listOf(target), exports.discarded)
    }

    @Test
    fun oneExportAtATimeAndOneThatEndsAfterTheScreenWasLeftSaysNothing() {
        val key = test.seedKey()
        val model = model()
        model.unlock(key.id)
        val gate = CountDownLatch(1)
        test.maker.exportGate = gate

        model.copy(locked)
        assertTrue(model.work.value.busy)
        model.copy(locked)
        model.close()
        gate.countDown()
        val deadline = System.currentTimeMillis() + 10_000
        while (test.maker.exports.isEmpty() || test.maker.exports.any { export -> export.any { it != 0.toByte() } }) {
            check(System.currentTimeMillis() < deadline) { "the export never ended" }
            Thread.sleep(10)
        }

        assertEquals("one export was made", 1, test.maker.exports.size)
        assertTrue("a copy ready after the screen was left stays off the clipboard", exports.copied.isEmpty())
        assertEquals(ExportWork(), model.work.value)
    }

    @Test
    fun leavingTheScreenClearsTheCopiedKeyFromTheClipboardAndNothingElse() {
        val key = test.seedKey()
        val model = model()
        model.unlock(key.id)
        model.copy(locked)
        assertEquals(ExportDone.Copied, model.settled().done)
        assertEquals(fakeExport(stored, "correct horse"), exports.clipboard)

        model.close()
        assertEquals("the key left the clipboard with the screen", null, exports.clipboard)

        model.unlock(key.id)
        model.copy(locked)
        model.settled()
        exports.clipboard = "another app's text"
        model.close()
        assertEquals("another app's text", exports.clipboard)
    }

    @Test
    fun aClipboardThatRefusesToBeClearedDoesNotKeepTheScreenOpen() {
        val key = test.seedKey()
        val model = model()
        model.unlock(key.id)
        exports.clearFailure = SecurityException("the clipboard is not this app's now")

        model.close()

        assertEquals(ExportWork(), model.work.value)
    }

    @Test
    fun aPassphraseTheCoreFindsTooShortIsSaidWithItsMinimum() {
        val key = test.seedKey()
        val model = model()
        model.unlock(key.id)
        test.maker.exportFailure = KeyException.PassphraseTooShort(8u)

        model.copy(ExportProtection.Passphrase("short"))

        assertEquals(ExportProblem.ShortPassphrase(8), model.settled().problem)
        assertTrue(exports.copied.isEmpty())
    }

    @Test
    fun aKeyTheCoreRefusesOrTheDeviceLostIsAProblemInWords() {
        val key = test.seedKey()
        val model = model()
        model.unlock(key.id)
        test.maker.exportFailure = KeyException.Invalid("not a stored key")
        model.copy(locked)
        assertEquals(ExportProblem.Failed("not a stored key"), model.settled().problem)

        test.vault.delete(key.id)
        model.copy(locked)
        assertEquals(ExportProblem.Gone, model.settled().problem)
    }

    @Test
    fun aKeyTheKeystoreCannotOpenIsAProblemWithItsReason() {
        val key = test.seedKey()
        val broken =
            object : KeyWrapper {
                override fun wrap(plain: ByteArray) = plain

                override fun unwrap(sealed: ByteArray): ByteArray = throw GeneralSecurityException("locked")
            }
        val keys =
            AppKeys(
                com.nickalie.ngterm.android
                    .testStore(dir.root, "other"),
                KeystoreKeyVault(File(dir.root, "keys"), broken),
                test.maker,
                "ngterm@test",
            )
        val model = ExportKeyViewModel(keys, exports) { now }
        model.unlock(key.id)

        model.copy(locked)

        assertEquals(
            ExportProblem.Failed("the key could not be unlocked: GeneralSecurityException"),
            model.settled().problem,
        )
    }
}
