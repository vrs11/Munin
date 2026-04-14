import AppKit
import CryptoKit
import Foundation
import os

@MainActor
final class ClipboardStore: ObservableObject {
    static let maxEntries = 100

    @Published private(set) var entries: [ClipboardEntry] = []

    private let pasteboard: NSPasteboard
    private let fileManager: FileManager
    private let persistenceURL: URL
    private let logger: Logger

    private var timer: Timer?
    private var lastChangeCount: Int
    private var suppressedChangeCount: Int?
    private var pendingCaptureRetries: [DispatchWorkItem] = []

    private var recentSignatures: [String] = []
    private var recentSignatureSet: Set<String> = []

    private static let pollInterval: TimeInterval = 0.2
    private static let pollTolerance: TimeInterval = 0.05
    private static let captureRetryDelays: [TimeInterval] = [0.06, 0.18]
    private static let dedupeSignatureWindow = 250

    init(pasteboard: NSPasteboard = .general, fileManager: FileManager = .default) {
        self.pasteboard = pasteboard
        self.fileManager = fileManager
        self.lastChangeCount = pasteboard.changeCount

        let subsystem = Bundle.main.bundleIdentifier ?? "com.studio11.munin"
        self.logger = Logger(subsystem: subsystem, category: "ClipboardStore")

        let supportDirectory = Self.makeSupportDirectory(using: fileManager)
        self.persistenceURL = supportDirectory.appendingPathComponent("clipboard-history.json")

        loadFromDisk()
        rebuildSignatureCache()
        startMonitoring()
        Self.writeStartupLog("ClipboardStore initialized")
    }

    func startMonitoring() {
        guard timer == nil else { return }

        let createdTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForPasteboardChanges()
            }
        }
        createdTimer.tolerance = Self.pollTolerance
        RunLoop.main.add(createdTimer, forMode: .common)
        timer = createdTimer
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        cancelPendingCaptureRetries()
    }

    func requestImmediateCheck() {
        checkForPasteboardChanges()
    }

    func deleteEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        rebuildSignatureCache()
        persist()
    }

    func copyEntryToPasteboard(_ entry: ClipboardEntry) {
        pasteboard.clearContents()

        let writeSucceeded: Bool
        switch entry.kind {
        case .text:
            guard let text = entry.text else { return }
            writeSucceeded = pasteboard.setString(text, forType: .string)
        case .image:
            guard let image = entry.nsImage else { return }
            writeSucceeded = pasteboard.writeObjects([image])
        }

        guard writeSucceeded else {
            logger.error("Failed to write entry to pasteboard")
            return
        }

        suppressedChangeCount = pasteboard.changeCount
    }

    private func checkForPasteboardChanges() {
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount

        cancelPendingCaptureRetries()

        if currentChangeCount == suppressedChangeCount {
            suppressedChangeCount = nil
            return
        }

        attemptCapture(forChangeCount: currentChangeCount, retryIndex: 0)
    }

    private func attemptCapture(forChangeCount changeCount: Int, retryIndex: Int) {
        guard pasteboard.changeCount == changeCount else { return }

        guard let captured = captureCurrentPasteboardEntry() else {
            scheduleCaptureRetry(forChangeCount: changeCount, retryIndex: retryIndex)
            return
        }

        addEntry(captured.entry, signature: captured.signature)
    }

    private func scheduleCaptureRetry(forChangeCount changeCount: Int, retryIndex: Int) {
        guard retryIndex < Self.captureRetryDelays.count else { return }

        let delay = Self.captureRetryDelays[retryIndex]
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.attemptCapture(forChangeCount: changeCount, retryIndex: retryIndex + 1)
            }
        }

        pendingCaptureRetries.append(workItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelPendingCaptureRetries() {
        pendingCaptureRetries.forEach { $0.cancel() }
        pendingCaptureRetries.removeAll(keepingCapacity: true)
    }

    private func captureCurrentPasteboardEntry() -> CapturedEntry? {
        if let text = readTextFromPasteboard() {
            let normalized = normalizeTextForSignature(text)
            guard !normalized.isEmpty else { return nil }
            return CapturedEntry(
                entry: ClipboardEntry(text: text),
                signature: signatureForText(normalized)
            )
        }

        if let imagePayload = readImageFromPasteboard() {
            return CapturedEntry(
                entry: ClipboardEntry(imagePNGData: imagePayload.pngData),
                signature: signatureForImage(imagePayload.image, fallbackData: imagePayload.pngData)
            )
        }

        return nil
    }

    private func readTextFromPasteboard() -> String? {
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            return string
        }

        if let textObject = pasteboard.readObjects(forClasses: [NSString.self], options: nil)?.first as? NSString {
            let text = String(textObject)
            if !text.isEmpty {
                return text
            }
        }

        if let rtfData = pasteboard.data(forType: .rtf),
           let attributed = try? NSAttributedString(
               data: rtfData,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           ) {
            let string = attributed.string
            if !string.isEmpty {
                return string
            }
        }

        if let htmlData = pasteboard.data(forType: .html),
           let attributed = try? NSAttributedString(
               data: htmlData,
               options: [.documentType: NSAttributedString.DocumentType.html],
               documentAttributes: nil
           ) {
            let string = attributed.string
            if !string.isEmpty {
                return string
            }
        }

        return nil
    }

    private func readImageFromPasteboard() -> (image: NSImage, pngData: Data)? {
        if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
           let pngData = image.pngData() {
            return (image, pngData)
        }

        if let pngData = pasteboard.data(forType: .png),
           let image = NSImage(data: pngData) {
            return (image, pngData)
        }

        if let tiffData = pasteboard.data(forType: .tiff),
           let image = NSImage(data: tiffData),
           let pngData = image.pngData() {
            return (image, pngData)
        }

        return nil
    }

    private func addEntry(_ entry: ClipboardEntry, signature: String) {
        guard !recentSignatureSet.contains(signature) else { return }

        entries.insert(entry, at: 0)
        registerSignature(signature)

        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }

        persist()
    }

    private func registerSignature(_ signature: String) {
        guard !recentSignatureSet.contains(signature) else { return }

        recentSignatures.insert(signature, at: 0)
        recentSignatureSet.insert(signature)

        if recentSignatures.count > Self.dedupeSignatureWindow {
            let overflowCount = recentSignatures.count - Self.dedupeSignatureWindow
            let overflow = recentSignatures.suffix(overflowCount)
            recentSignatures.removeLast(overflowCount)
            for value in overflow {
                recentSignatureSet.remove(value)
            }
        }
    }

    private func rebuildSignatureCache() {
        recentSignatures.removeAll(keepingCapacity: true)
        recentSignatureSet.removeAll(keepingCapacity: true)

        for entry in entries {
            guard let signature = signature(forStoredEntry: entry) else { continue }
            registerSignature(signature)
        }
    }

    private func signature(forStoredEntry entry: ClipboardEntry) -> String? {
        switch entry.kind {
        case .text:
            guard let text = entry.text else { return nil }
            let normalized = normalizeTextForSignature(text)
            guard !normalized.isEmpty else { return nil }
            return signatureForText(normalized)
        case .image:
            guard let pngData = entry.imagePNGData else { return nil }
            if let image = NSImage(data: pngData) {
                return signatureForImage(image, fallbackData: pngData)
            }
            return "i:fallback:\(sha256Hex(pngData))"
        }
    }

    private func normalizeTextForSignature(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
    }

    private func signatureForText(_ normalizedText: String) -> String {
        "t:\(sha256Hex(Data(normalizedText.utf8)))"
    }

    private func signatureForImage(_ image: NSImage, fallbackData: Data) -> String {
        if let normalizedPixels = image.normalizedPixelSignatureData() {
            return "i:pixel:\(sha256Hex(normalizedPixels))"
        }
        return "i:fallback:\(sha256Hex(fallbackData))"
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func loadFromDisk() {
        guard fileManager.fileExists(atPath: persistenceURL.path) else { return }

        do {
            let data = try Data(contentsOf: persistenceURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([ClipboardEntry].self, from: data)
            entries = Array(decoded.prefix(Self.maxEntries))
        } catch {
            logger.error("Failed to load clipboard history: \(error.localizedDescription)")
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            logger.error("Failed to persist clipboard history: \(error.localizedDescription)")
        }
    }

    private static func makeSupportDirectory(using fileManager: FileManager) -> URL {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)

        let bundleID = Bundle.main.bundleIdentifier ?? "com.studio11.munin"
        let appDirectory = baseDirectory.appendingPathComponent(bundleID, isDirectory: true)

        if !fileManager.fileExists(atPath: appDirectory.path) {
            do {
                try fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
            } catch {
                // If directory creation fails, persist/load will fail and be logged by their call sites.
            }
        }

        return appDirectory
    }

    private static func writeStartupLog(_ message: String) {
        let url = URL(fileURLWithPath: "/tmp/munin-startup.log")
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
            }
            return
        }

        try? data.write(to: url, options: .atomic)
    }
}

private struct CapturedEntry {
    let entry: ClipboardEntry
    let signature: String
}

private extension NSImage {
    func pngData() -> Data? {
        guard
            let tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffRepresentation)
        else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }

    func normalizedPixelSignatureData() -> Data? {
        guard let image = cgImageForSignature() else { return nil }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let pixelByteCount = height * bytesPerRow
        var pixels = Data(count: pixelByteCount)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        let rendered = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            guard
                let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                )
            else {
                return false
            }

            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard rendered else { return nil }

        var signatureData = Data()
        signatureData.appendUInt32BigEndian(UInt32(width))
        signatureData.appendUInt32BigEndian(UInt32(height))
        signatureData.append(pixels)
        return signatureData
    }

    private func cgImageForSignature() -> CGImage? {
        var proposedRect = NSRect(origin: .zero, size: size)
        if let cgImage = cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
            return cgImage
        }

        guard
            let tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffRepresentation)
        else {
            return nil
        }

        return bitmap.cgImage
    }
}

private extension Data {
    mutating func appendUInt32BigEndian(_ value: UInt32) {
        var bigEndianValue = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndianValue) { bytes in
            append(bytes.bindMemory(to: UInt8.self))
        }
    }
}
