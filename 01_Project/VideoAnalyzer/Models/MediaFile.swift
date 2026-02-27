import Foundation

struct MediaFile: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let fileSize: Int64
    let modificationDate: Date?
    let formatInfo: String?

    init(
        id: UUID = UUID(),
        url: URL,
        fileSize: Int64,
        modificationDate: Date? = nil,
        formatInfo: String? = nil
    ) {
        self.id = id
        self.url = url
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.formatInfo = formatInfo
    }

    var fileName: String {
        url.lastPathComponent
    }

    var fileSizeFormatted: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }
}
