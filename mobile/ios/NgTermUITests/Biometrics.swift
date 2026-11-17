import XCTest

/// The simulator's Face ID or Touch ID, as its Features menu drives it.
///
/// It is enrolled or not, and it shows a matching or a non-matching face or finger to the system's prompt that is up.
/// The menu posts Darwin notifications and sets one's state, which the test runner, a process of the same simulator,
/// does too. The state calls are looked up at run time: an `import notify` sorts one way for SwiftLint and the other
/// for swift-format.
internal enum Biometrics {
    private typealias RegisterCheck = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<Int32>) -> UInt32
    private typealias SetState = @convention(c) (Int32, UInt64) -> UInt32
    private typealias GetState = @convention(c) (Int32, UnsafeMutablePointer<UInt64>) -> UInt32
    private typealias Cancel = @convention(c) (Int32) -> UInt32

    private static let enrollment = "com.apple.BiometricKit.enrollmentChanged"
    // the Face ID ("pearl") and Touch ID ("fingerTouch") sensors: a simulator has one of them, and the other's
    // notification reaches nothing
    private static let sensors = ["pearl", "fingerTouch"]
    // dlsym's RTLD_DEFAULT on Apple platforms, a handle that looks in every image loaded
    private static let defaultHandle = -2

    private static var everyImage: UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: defaultHandle)
    }

    /// Enrolls a face or a finger, and puts the earlier state back when `test` ends.
    internal static func enroll(for test: XCTestCase) {
        let before = withToken { token, _ in
            var value: UInt64 = 0
            _ = function("notify_get_state", as: GetState.self)?(token, &value)
            return value != 0
        }
        setEnrolled(true)
        test.addTeardownBlock {
            setEnrolled(before ?? false)
        }
    }

    /// Shows the system's prompt a matching face or finger.
    internal static func match() {
        post("match")
    }

    /// Shows the system's prompt a face or a finger that doesn't match.
    internal static func noMatch() {
        post("nomatch")
    }

    private static func post(_ outcome: String) {
        for sensor in sensors {
            post(name: "com.apple.BiometricKit_Sim.\(sensor).\(outcome)")
        }
    }

    private static func post(name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    private static func function<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(everyImage, name).map { unsafeBitCast($0, to: type) }
    }

    // runs `body` with a token for the enrollment's notification, then lets the token go
    private static func withToken<T>(_ body: (Int32, SetState) -> T) -> T? {
        guard let register = function("notify_register_check", as: RegisterCheck.self),
            let setState = function("notify_set_state", as: SetState.self),
            let cancel = function("notify_cancel", as: Cancel.self)
        else {
            return nil
        }
        var token: Int32 = 0
        guard register(enrollment, &token) == 0 else {
            return nil
        }
        defer { _ = cancel(token) }
        return body(token, setState)
    }

    private static func setEnrolled(_ enrolled: Bool) {
        let done = withToken { token, setState in
            setState(token, enrolled ? 1 : 0) == 0
        }
        XCTAssertTrue(done ?? false, "the simulator's biometric enrollment can't be changed")
        post(name: enrollment)
    }
}
