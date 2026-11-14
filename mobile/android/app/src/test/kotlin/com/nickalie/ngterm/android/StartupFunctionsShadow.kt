package com.nickalie.ngterm.android

import com.nickalie.ngterm.core.fake.FakeAppLog
import com.nickalie.ngterm.core.ffi.AppLog
import com.nickalie.ngterm.core.ffi.KeyPair
import com.nickalie.ngterm.core.ffi.LogLevel
import com.nickalie.ngterm.core.ffi.NoHandle
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements

/**
 * The core's native top-level functions: [coreVersion] for the activity, [generateKey] for the application's key
 * maker (NativeKeyMaker), so a key made in a test is this fake pair, and [appLog] for the application's diagnostic
 * log ([StartupAppLog]); all activity, settings and navigation code stays real.
 */
@Implements(className = "com.nickalie.ngterm.core.ffi.Ngterm_mobileKt", isInAndroidSdk = false)
object StartupFunctionsShadow {
    private const val VERSION = "test-core-version"

    @JvmStatic
    @Implementation
    fun coreVersion(): String = VERSION

    @JvmStatic
    @Implementation
    fun appLog(dir: String): AppLog = StartupAppLog.also { it.dir = dir }

    @JvmStatic
    @Implementation
    fun generateKey(comment: String): KeyPair =
        KeyPair("test private bytes".toByteArray(), "ssh-ed25519 test $comment", "SHA256:test")
}

/** The process's log as the native `app_log` hands it out, over the in-memory [fake]: one per process, in [dir]. */
object StartupAppLog : AppLog(NoHandle) {
    val fake = FakeAppLog()

    /** The directory the application last opened it in. */
    var dir: String? = null

    override fun append(
        level: LogLevel,
        tag: String,
        message: String,
    ) = fake.append(level, tag, message)

    override fun clear() = fake.clear()

    override fun export(path: String): ULong = fake.export(path)

    override fun size(): ULong = fake.size()

    override fun tail(maxBytes: UInt): String = fake.tail(maxBytes)

    override fun text(): String = fake.text()
}
