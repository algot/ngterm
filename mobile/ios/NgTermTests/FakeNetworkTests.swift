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

    @Test("the fake world's graph is online once started")
    internal func graphOnline() {
        let graph = FakeWorld.graph(arguments: [CoreChoice.fakeArgument, CoreChoice.fakeKeyArgument])
        graph.start()
        #expect(graph.network.isOnline)
    }
}
