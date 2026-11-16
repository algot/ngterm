import CoreTransferable
import UniformTypeIdentifiers

/// The whole log as a text file for the share sheet, written when the app the user picked asks for it.
internal struct LogExport: Transferable {
    internal static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { export in
            SentTransferredFile(try await export.model.export())
        }
        .suggestedFileName(LogsModel.exportName)
    }

    /// The page whose log it is.
    internal let model: LogsModel
}
