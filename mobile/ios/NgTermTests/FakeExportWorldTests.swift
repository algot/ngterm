import Foundation
import NgtermFeatures
import NgtermPlatform
import Testing

@testable import NgTerm

/// The fake world's key export, which the UI tests rely on: the device's owner confirms at once, a launch can leave the
/// device without a passcode, and the exported file is offered under the name the launch gives.
@MainActor
@Suite("the fake world's key export")
internal struct FakeExportWorldTests {
    private func graph(_ arguments: [String]) -> AppGraph {
        FakeWorld.graph(arguments: [CoreChoice.fakeArgument] + arguments)
    }

    @Test("the owner confirms at once, and the key waits under its usual name")
    internal func confirms() async throws {
        let exports = graph([]).exports
        #expect(exports.auth.isSecured)
        #expect(await exports.auth.confirm(reason: "export") == .confirmed)
        let staged = try exports.files.stage(Data("fake".utf8))
        defer { exports.files.discard(staged) }
        #expect(staged.lastPathComponent == KeyExportFiles.defaultName)
    }

    @Test("a launch can leave the device without a passcode, and name the exported file")
    internal func asked() async throws {
        let exports = graph([CoreChoice.fakeNoPasscodeArgument, CoreChoice.fakeExportNameArgument, "run-key"]).exports
        #expect(!exports.auth.isSecured)
        #expect(await exports.auth.confirm(reason: "export") == .failed(reason: "no passcode"))
        let staged = try exports.files.stage(Data("fake".utf8))
        defer { exports.files.discard(staged) }
        #expect(staged.lastPathComponent == "run-key")
        // a name left out falls back to the usual one
        let unnamed = graph([CoreChoice.fakeExportNameArgument]).exports
        let other = try unnamed.files.stage(Data("fake".utf8))
        defer { unnamed.files.discard(other) }
        #expect(other.lastPathComponent == KeyExportFiles.defaultName)
    }

    @Test("the app says why it asks for Face ID")
    internal func faceIDUsage() throws {
        let usage = try #require(Bundle.main.object(forInfoDictionaryKey: "NSFaceIDUsageDescription") as? String)
        #expect(usage.contains("exports a private key"))
    }
}
