import NgtermPlatform
import Testing

@testable import NgTerm

/// The fake world's network, which the UI tests rely on: always online, whatever the simulator's network is.
@MainActor
@Suite("the fake world's network")
internal struct FakeNetworkTests {
    @Test("each start reports one path that can carry traffic, and a stop changes nothing")
    internal func alwaysOnline() {
        let source = FakeNetwork()
        var paths: [NetworkPath] = []
        source.start { path in paths.append(path) }
        source.stop()
        source.start { path in paths.append(path) }
        #expect(paths == [FakeNetwork.path, FakeNetwork.path])
        #expect(FakeNetwork.path.isSatisfied)
    }

    @Test("the fake world's graph starts a fake network, not the system's, and is online at once")
    internal func graphOnline() {
        let graph = FakeWorld.graph(arguments: [CoreChoice.fakeArgument, CoreChoice.fakeKeyArgument])
        // the system's network is online until its first path, which comes on a later turn of the main queue: only
        // the count of starts tells which network the graph follows
        let before = FakeNetwork.starts
        graph.start()
        #expect(FakeNetwork.starts == before + 1)
        #expect(graph.network.isOnline)
    }
}
