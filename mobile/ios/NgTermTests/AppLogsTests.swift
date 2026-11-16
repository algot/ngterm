import Foundation
import Testing
import UIKit

@testable import NgTerm

/// The process's diagnostic log as the app opens it: the line every later one is read against, on this device.
@Suite("the app's log")
internal struct AppLogsTests {
    @Test("the log opens with the app's version, the system's and the device's model")
    @MainActor
    internal func started() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AppLogsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = AppLogs.open(in: directory)
        let line = log.tail(maxBytes: 4_096).split(separator: "\n").last { $0.contains(" I app: started ") }
        #expect(line?.contains("device=\(AppLogs.deviceModel)") == true)
        #expect(line?.contains(" ios=\(UIDevice.current.systemVersion) ") == true)
        #expect(line?.contains(" version=") == true)
    }

    @Test("the device's model is its identifier, the simulated one's on a simulator")
    internal func deviceModel() {
        let model = AppLogs.deviceModel
        #expect(model.contains(","), "\(model) is no model identifier")
    }
}
