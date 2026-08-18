import Foundation

/// A file or image attached to a draft message.
struct ComposerAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let name: String
    let isImage: Bool

    init(url: URL, isImage: Bool? = nil) {
        self.id = UUID()
        self.url = url
        self.name = url.lastPathComponent
        let detected = Self.imageExtensions.contains(url.pathExtension.lowercased())
        self.isImage = isImage ?? detected
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff",
    ]
}