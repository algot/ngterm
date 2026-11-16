/// MetricKit's call stack tree of a crash, as much of it as ``CrashLines`` needs: each thread's stack, whether the
/// crash is attributed to it, and its root frames (the top of the stack first).
internal struct CallStackTree: Decodable {
    /// One thread's stack.
    internal struct Stack: Decodable {
        private enum Key: CodingKey {
            case callStackRootFrames
            case threadAttributed
        }

        /// Whether the crash is attributed to this thread.
        internal let isAttributed: Bool
        /// The stack's root frames: the frame it stopped in first.
        internal let callStackRootFrames: [Frame]

        internal init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            isAttributed = try container.decodeIfPresent(Bool.self, forKey: .threadAttributed) ?? false
            callStackRootFrames = try container.decode([Frame].self, forKey: .callStackRootFrames)
        }
    }

    /// A frame: the binary it is in, and where in its text.
    internal struct Frame: Decodable {
        /// The binary's name.
        internal let binaryName: String?
        /// The frame's offset into the binary's text segment.
        internal let offsetIntoBinaryTextSegment: UInt64?
    }

    /// Each thread's stack.
    internal let callStacks: [Stack]
}
