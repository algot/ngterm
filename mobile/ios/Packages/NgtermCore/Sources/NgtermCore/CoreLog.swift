import Foundation
import NgtermCoreBindings

/// The process's diagnostic log (the core's `app_log`).
public enum CoreLog {
    /// Opens the process's log in `directory`, and sends the core's own lines to it.
    ///
    /// The directory is made when missing and kept out of backups. Later calls hand back the same log whatever their
    /// directory. The app calls it once, before it makes its core, so the core's first lines are in it.
    public static func open(directory: URL) -> any AppLogProtocol {
        var folder = directory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        return appLog(dir: folder.path)
    }
}
