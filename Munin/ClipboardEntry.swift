import AppKit
import Foundation

struct ClipboardEntry: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case text
        case image
    }

    let id: UUID
    let createdAt: Date
    let kind: Kind
    let text: String?
    let imagePNGData: Data?

    init(id: UUID = UUID(), createdAt: Date = Date(), text: String) {
        self.id = id
        self.createdAt = createdAt
        self.kind = .text
        self.text = text
        self.imagePNGData = nil
    }

    init(id: UUID = UUID(), createdAt: Date = Date(), imagePNGData: Data) {
        self.id = id
        self.createdAt = createdAt
        self.kind = .image
        self.text = nil
        self.imagePNGData = imagePNGData
    }

    var previewTitle: String {
        switch kind {
        case .text:
            return "Text"
        case .image:
            return "Image"
        }
    }

    var previewText: String {
        switch kind {
        case .text:
            let value = text ?? ""
            return value.replacingOccurrences(of: "\n", with: " ")
        case .image:
            guard let nsImage else { return "Image preview unavailable" }
            let width = Int(nsImage.size.width)
            let height = Int(nsImage.size.height)
            return "\(width)x\(height) px"
        }
    }

    var nsImage: NSImage? {
        guard kind == .image, let imagePNGData else { return nil }
        return NSImage(data: imagePNGData)
    }

}
