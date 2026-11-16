import Darwin
import Foundation

/// What the log says of a crash (mobile/android's `crashLine`): its class and the frame it came from.
///
/// Never its message, which may quote what the user typed or a machine printed.
public enum CrashLines {
    // the Mach exception types (mach/exception_types.h)
    private static let exceptions: [Int32: String] = [
        EXC_BAD_ACCESS: "EXC_BAD_ACCESS", EXC_BAD_INSTRUCTION: "EXC_BAD_INSTRUCTION", EXC_ARITHMETIC: "EXC_ARITHMETIC",
        EXC_EMULATION: "EXC_EMULATION", EXC_SOFTWARE: "EXC_SOFTWARE", EXC_BREAKPOINT: "EXC_BREAKPOINT",
        EXC_SYSCALL: "EXC_SYSCALL", EXC_MACH_SYSCALL: "EXC_MACH_SYSCALL", EXC_RPC_ALERT: "EXC_RPC_ALERT",
        EXC_CRASH: "EXC_CRASH", EXC_RESOURCE: "EXC_RESOURCE", EXC_GUARD: "EXC_GUARD",
        EXC_CORPSE_NOTIFY: "EXC_CORPSE_NOTIFY",
    ]
    // the signals a crash ends with (sys/signal.h)
    private static let signals: [Int32: String] = [
        SIGILL: "SIGILL", SIGTRAP: "SIGTRAP", SIGABRT: "SIGABRT", SIGEMT: "SIGEMT", SIGFPE: "SIGFPE",
        SIGKILL: "SIGKILL", SIGBUS: "SIGBUS", SIGSEGV: "SIGSEGV", SIGSYS: "SIGSYS", SIGPIPE: "SIGPIPE",
        SIGTERM: "SIGTERM",
    ]

    /// An Objective-C exception no one caught.
    ///
    /// It names the exception's `name`, its `thread` (`main`, else `other`), and the first frame of `symbols` (its call
    /// stack) past the runtime's throw.
    public static func exception(name: String, thread: String, symbols: [String]) -> String {
        let frames = symbols.compactMap(frame)
        let thrower = frames.firstIndex { $0.contains(":objc_exception_throw") || $0.contains(":__cxa_throw") }
        let thrown = thrower.flatMap { frames.indices.contains($0 + 1) ? frames[$0 + 1] : nil } ?? frames.first
        return "uncaught exception class=\(name) thread=\(thread) at=\(thrown ?? "unknown")"
    }

    /// A crash of an earlier run the system reported (MetricKit).
    ///
    /// It names the Mach `exceptionType` and the `signal`, the top frame of the crashed thread in `callStacks` (the
    /// call stack tree as JSON), and when it happened (`time`).
    public static func reported(exceptionType: Int?, signal: Int?, callStacks: Data, time: Date) -> String {
        let kind = exceptionType.map { exceptions[Int32(clamping: $0)] ?? "EXC_\($0)" } ?? "unknown"
        let ended = signal.map { signals[Int32(clamping: $0)] ?? "SIG\($0)" } ?? "unknown"
        let top = topFrame(callStacks) ?? "unknown"
        let when = time.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
        return "earlier crash class=\(kind) signal=\(ended) at=\(top) time=\(when)Z"
    }

    // a line of `callStackSymbols` (`3   NgTerm   0x0000000102a4  $s6NgTerm4MainV3runyyF + 52`) as
    // `NgTerm:$s6NgTerm4MainV3runyyF+52`
    private static func frame(_ symbol: String) -> String? {
        let format = /^\d+\s+(\S+)\s+0x[0-9a-fA-F]+\s+(.+?)(?:\s+\+\s+(\d+))?$/
        guard let match = symbol.wholeMatch(of: format) else {
            return nil
        }
        let offset = match.3.map { "+\($0)" } ?? ""
        return "\(match.1):\(match.2)\(offset)"
    }

    // the first root frame of the thread the crash is attributed to, as `binary+0xoffset`
    private static func topFrame(_ json: Data) -> String? {
        guard let tree = try? JSONDecoder().decode(CallStackTree.self, from: json) else {
            return nil
        }
        let stack = tree.callStacks.first(where: \.isAttributed) ?? tree.callStacks.first
        guard let top = stack?.callStackRootFrames.first else {
            return nil
        }
        let offset = top.offsetIntoBinaryTextSegment.map { String(format: "+0x%llx", $0) } ?? ""
        return "\(top.binaryName ?? "unknown")\(offset)"
    }
}
