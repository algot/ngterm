import Foundation
import Testing

@testable import NgtermFeatures

/// What the log says of a crash (mobile/android's `crashLine` tests): its class and its frame, never its message.
@Suite("crash lines")
internal struct CrashLinesTests {
    // a crash's call stack tree as MetricKit writes it (its shape, made up values)
    private static let tree = Data(
        """
        {"callStackPerThread": true, "callStacks": [
            {"threadAttributed": false, "callStackRootFrames": [
                {"binaryName": "libsystem_kernel.dylib", "offsetIntoBinaryTextSegment": 4096, "subFrames": []}]},
            {"threadAttributed": true, "callStackRootFrames": [
                {"binaryName": "NgTerm", "offsetIntoBinaryTextSegment": 1715004, "address": 4300000000,
                    "subFrames": [{"binaryName": "SwiftUI", "offsetIntoBinaryTextSegment": 12}]}]}]}
        """.utf8
    )

    @Test("an uncaught exception names its class, its thread and the frame that threw it")
    internal func exception() {
        let symbols = [
            "0   CoreFoundation                      0x00000001804b9100 __exceptionPreprocess + 160",
            "1   libobjc.A.dylib                     0x0000000180092da8 objc_exception_throw + 72",
            "2   CoreFoundation                      0x00000001804cf5a4 -[__NSArrayI objectAtIndex:] + 312",
            "3   NgTerm                              0x0000000102a4b2c0 $s6NgTerm4MainV3runyyF + 52",
        ]
        let line = CrashLines.exception(name: "NSRangeException", thread: "main", symbols: symbols)
        let thrower = "CoreFoundation:-[__NSArrayI objectAtIndex:]+312"
        #expect(line == "uncaught exception class=NSRangeException thread=main at=\(thrower)")
    }

    @Test("an exception with no throw frame takes its first frame, and one with no frames says unknown")
    internal func exceptionFrames() {
        let line = CrashLines.exception(
            name: "NSInvalidArgumentException",
            thread: "other",
            symbols: ["not a frame", "4   NgTerm   0x0000000102a4b2c0 main"]
        )
        #expect(line == "uncaught exception class=NSInvalidArgumentException thread=other at=NgTerm:main")
        #expect(CrashLines.exception(name: "E", thread: "main", symbols: []).hasSuffix("at=unknown"))
        let thrownLast = ["1   libobjc.A.dylib   0x0000000180092da8 objc_exception_throw + 72"]
        let last = CrashLines.exception(name: "E", thread: "main", symbols: thrownLast)
        #expect(last.hasSuffix("objc_exception_throw+72"))
    }

    @Test("a crash the system reported names its exception, its signal and the crashed thread's top frame")
    internal func reported() {
        let time = Date(timeIntervalSince1970: 1_763_201_472)
        let line = CrashLines.reported(exceptionType: 6, signal: 5, callStacks: Self.tree, time: time)
        let told = "earlier crash class=EXC_BREAKPOINT signal=SIGTRAP at=NgTerm+0x1a2b3c time=2025-11-15T10:11:12Z"
        #expect(line == told)
    }

    @Test("a report with unknown numbers or no readable stack still makes a line")
    internal func reportedUnknown() {
        let time = Date(timeIntervalSince1970: 0)
        let line = CrashLines.reported(exceptionType: 99, signal: 77, callStacks: Data("{}".utf8), time: time)
        #expect(line == "earlier crash class=EXC_99 signal=SIG77 at=unknown time=1970-01-01T00:00:00Z")
        let none = CrashLines.reported(
            exceptionType: nil,
            signal: nil,
            callStacks: Data(#"{"callStacks": [{"callStackRootFrames": [{}]}]}"#.utf8),
            time: time
        )
        #expect(none == "earlier crash class=unknown signal=unknown at=unknown time=1970-01-01T00:00:00Z")
        let empty = CrashLines.reported(
            exceptionType: 1,
            signal: 11,
            callStacks: Data(#"{"callStacks": []}"#.utf8),
            time: time
        )
        #expect(empty.hasPrefix("earlier crash class=EXC_BAD_ACCESS signal=SIGSEGV at=unknown"))
    }
}
