import AppKit
import CryptoKit
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

@MainActor
final class ClipboardStore: ObservableObject {
    static let maxEntries = 100

    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var isMonitoringPaused = false

    private let pasteboard: NSPasteboard
    private let fileManager: FileManager
    private let persistenceURL: URL
    private let logger: Logger

    private var timer: Timer?
    private var lastChangeCount: Int
    private var suppressedChangeCount: Int?
    private var pendingCaptureRetries: [DispatchWorkItem] = []
    private var captureProcessingTask: Task<Void, Never>?
    private var pendingPersistTask: Task<Void, Never>?

    private var recentSignatures: [String] = []
    private var recentSignatureSet: Set<String> = []
    private let persistenceWriter = ClipboardHistoryPersistenceWriter()

    private static let pollInterval: TimeInterval = 0.2
    private static let pollTolerance: TimeInterval = 0.05
    private static let captureRetryDelays: [TimeInterval] = [0.06, 0.18]
    private static let dedupeSignatureWindow = 250
    private static let persistenceDebounceNanoseconds: UInt64 = 350_000_000

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
        cancelPendingCaptureWork()
        flushPendingPersistence()
    }

    func requestImmediateCheck() {
        guard !isMonitoringPaused else { return }
        checkForPasteboardChanges()
    }

    func setMonitoringPaused(_ paused: Bool) {
        isMonitoringPaused = paused
        if paused {
            cancelPendingCaptureWork()
            lastChangeCount = pasteboard.changeCount
        }
    }

    func clearHistory() {
        entries.removeAll(keepingCapacity: true)
        rebuildSignatureCache()
        schedulePersist()
    }

    func deleteEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        rebuildSignatureCache()
        schedulePersist()
    }

    func copyEntryToPasteboard(_ entry: ClipboardEntry) {
        let writableObjects: [NSPasteboardWriting]
        let stringToWrite: String?
        switch entry.kind {
        case .text:
            guard let text = entry.text else { return }
            writableObjects = []
            stringToWrite = text
        case .image:
            guard let image = entry.nsImage else { return }
            writableObjects = [image]
            stringToWrite = nil
        }

        pasteboard.clearContents()

        let writeSucceeded: Bool
        if let stringToWrite {
            writeSucceeded = pasteboard.setString(stringToWrite, forType: .string)
        } else {
            writeSucceeded = pasteboard.writeObjects(writableObjects)
        }

        guard writeSucceeded else {
            logger.error("Failed to write entry to pasteboard")
            return
        }

        suppressedChangeCount = pasteboard.changeCount
    }

    private func checkForPasteboardChanges() {
        guard !isMonitoringPaused else {
            lastChangeCount = pasteboard.changeCount
            return
        }

        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount

        cancelPendingCaptureWork()

        if currentChangeCount == suppressedChangeCount {
            suppressedChangeCount = nil
            return
        }

        attemptCapture(forChangeCount: currentChangeCount, retryIndex: 0)
    }

    private func attemptCapture(forChangeCount changeCount: Int, retryIndex: Int) {
        guard pasteboard.changeCount == changeCount else { return }

        guard let snapshot = snapshotCurrentPasteboardPayload() else {
            scheduleCaptureRetry(forChangeCount: changeCount, retryIndex: retryIndex)
            return
        }

        captureProcessingTask?.cancel()
        captureProcessingTask = Task.detached(priority: .utility) { [weak self] in
            guard let captured = ClipboardPayloadProcessor.process(snapshot) else { return }

            await MainActor.run { [weak self] in
                self?.completeCapture(captured, forChangeCount: changeCount)
            }
        }
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

    private func cancelPendingCaptureWork() {
        cancelPendingCaptureRetries()
        captureProcessingTask?.cancel()
        captureProcessingTask = nil
    }

    private func completeCapture(_ captured: CapturedEntry, forChangeCount changeCount: Int) {
        guard !isMonitoringPaused else { return }
        guard pasteboard.changeCount == changeCount else { return }

        addEntry(captured.entry, signature: captured.signature)
    }

    private func snapshotCurrentPasteboardPayload() -> ClipboardPayload? {
        let types = pasteboard.types ?? []

        if let textPayload = snapshotTextPayload(types: types) {
            return textPayload
        }

        if let imagePayload = snapshotImagePayload(types: types) {
            return imagePayload
        }

        return nil
    }

    private func snapshotTextPayload(types: [NSPasteboard.PasteboardType]) -> ClipboardPayload? {
        if types.contains(.string) {
            if let data = pasteboard.data(forType: .string) {
                guard data.count <= ClipboardLimits.maxCapturedTextUTF8Bytes else { return nil }
                return .plainTextData(data)
            }

            if let string = pasteboard.string(forType: .string),
               !string.isEmpty,
               string.utf8.count <= ClipboardLimits.maxCapturedTextUTF8Bytes {
                return .plainText(string)
            }
        }

        if types.contains(.rtf),
           let data = pasteboard.data(forType: .rtf),
           data.count <= ClipboardLimits.maxRichTextDataBytes {
            return .richTextData(data, .rtf)
        }

        if types.contains(.html),
           let data = pasteboard.data(forType: .html),
           data.count <= ClipboardLimits.maxRichTextDataBytes {
            return .richTextData(data, .html)
        }

        return nil
    }

    private func snapshotImagePayload(types: [NSPasteboard.PasteboardType]) -> ClipboardPayload? {
        if types.contains(.png),
           let data = pasteboard.data(forType: .png),
           data.count <= ClipboardLimits.maxRawImageBytes {
            return .imageData(data, .png)
        }

        if types.contains(.tiff),
           let data = pasteboard.data(forType: .tiff),
           data.count <= ClipboardLimits.maxRawImageBytes {
            return .imageData(data, .tiff)
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

        schedulePersist()
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
            guard let signature = ClipboardPayloadProcessor.signature(forStoredEntry: entry) else { continue }
            registerSignature(signature)
        }
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

    private func schedulePersist() {
        pendingPersistTask?.cancel()

        let entriesSnapshot = entries
        let url = persistenceURL
        let writer = persistenceWriter

        pendingPersistTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.persistenceDebounceNanoseconds)
                try Task.checkCancellation()
                try await writer.write(entriesSnapshot, to: url)
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in
                    self?.logger.error("Failed to persist clipboard history: \(error.localizedDescription)")
                }
            }
        }
    }

    private func flushPendingPersistence() {
        pendingPersistTask?.cancel()
        pendingPersistTask = nil

        do {
            try ClipboardHistoryPersistenceWriter.writeImmediately(entries, to: persistenceURL)
        } catch {
            logger.error("Failed to persist clipboard history: \(error.localizedDescription)")
        }
    }
}

private enum ClipboardLimits {
    static let maxCapturedTextUTF8Bytes = 1_000_000
    static let maxRichTextDataBytes = 2_000_000
    static let maxRawImageBytes = 40_000_000
    static let maxCapturedImagePixels = 8_000_000
    static let maxPersistedImagePNGBytes = 20_000_000
}

private enum ClipboardPayload: Sendable {
    case plainText(String)
    case plainTextData(Data)
    case richTextData(Data, RichTextDocumentKind)
    case imageData(Data, ImageRepresentation)
}

private enum RichTextDocumentKind: Sendable {
    case rtf
    case html

    var documentType: NSAttributedString.DocumentType {
        switch self {
        case .rtf: return .rtf
        case .html: return .html
        }
    }
}

private enum ImageRepresentation: Sendable {
    case png
    case tiff
}

private struct CapturedEntry: Sendable {
    let entry: ClipboardEntry
    let signature: String
}

private enum ClipboardPayloadProcessor {
    static func process(_ payload: ClipboardPayload) -> CapturedEntry? {
        if Task.isCancelled { return nil }

        switch payload {
        case .plainText(let text):
            return processText(text)
        case .plainTextData(let data):
            guard data.count <= ClipboardLimits.maxCapturedTextUTF8Bytes else { return nil }
            guard let text = decodePlainText(data) else { return nil }
            return processText(text)
        case .richTextData(let data, let kind):
            guard data.count <= ClipboardLimits.maxRichTextDataBytes else { return nil }
            guard let text = extractPlainText(from: data, kind: kind) else { return nil }
            return processText(text)
        case .imageData(let data, let representation):
            return processImage(data, representation: representation)
        }
    }

    static func signature(forStoredEntry entry: ClipboardEntry) -> String? {
        switch entry.kind {
        case .text:
            guard let text = entry.text else { return nil }
            let normalized = normalizeTextForSignature(text)
            guard !normalized.isEmpty else { return nil }
            return signatureForText(normalized)
        case .image:
            guard let pngData = entry.imagePNGData else { return nil }
            if let normalizedPixels = normalizedPixelSignatureData(from: pngData) {
                return "i:pixel:\(sha256Hex(normalizedPixels))"
            }
            return "i:fallback:\(sha256Hex(pngData))"
        }
    }

    private static func processText(_ text: String) -> CapturedEntry? {
        guard text.utf8.count <= ClipboardLimits.maxCapturedTextUTF8Bytes else { return nil }

        let normalized = normalizeTextForSignature(text)
        guard !normalized.isEmpty else { return nil }

        return CapturedEntry(
            entry: ClipboardEntry(text: text),
            signature: signatureForText(normalized)
        )
    }

    private static func processImage(_ data: Data, representation: ImageRepresentation) -> CapturedEntry? {
        guard data.count <= ClipboardLimits.maxRawImageBytes else { return nil }
        guard let normalizedPixels = normalizedPixelSignatureData(from: data) else { return nil }
        guard let pngData = pngData(from: data, representation: representation) else { return nil }
        guard pngData.count <= ClipboardLimits.maxPersistedImagePNGBytes else { return nil }

        return CapturedEntry(
            entry: ClipboardEntry(imagePNGData: pngData),
            signature: "i:pixel:\(sha256Hex(normalizedPixels))"
        )
    }

    private static func decodePlainText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .utf16LittleEndian)
            ?? String(data: data, encoding: .utf16BigEndian)
    }

    private static func extractPlainText(from data: Data, kind: RichTextDocumentKind) -> String? {
        let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: kind.documentType],
            documentAttributes: nil
        )
        let text = attributed?.string ?? ""
        return text.isEmpty ? nil : text
    }

    private static func normalizeTextForSignature(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
    }

    private static func signatureForText(_ normalizedText: String) -> String {
        "t:\(sha256Hex(Data(normalizedText.utf8)))"
    }

    private static func normalizedPixelSignatureData(from data: Data) -> Data? {
        guard let image = makeCGImage(from: data) else { return nil }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        guard width <= ClipboardLimits.maxCapturedImagePixels / height else { return nil }

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

    private static func pngData(from data: Data, representation: ImageRepresentation) -> Data? {
        switch representation {
        case .png:
            return data.count <= ClipboardLimits.maxPersistedImagePNGBytes ? data : nil
        case .tiff:
            guard let image = makeCGImage(from: data) else { return nil }

            let pngData = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                pngData,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                return nil
            }

            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return pngData as Data
        }
    }

    private static func makeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        guard
            let width = integerProperty(kCGImagePropertyPixelWidth, in: properties),
            let height = integerProperty(kCGImagePropertyPixelHeight, in: properties),
            width > 0,
            height > 0,
            width <= ClipboardLimits.maxCapturedImagePixels / height
        else {
            return nil
        }

        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func integerProperty(_ key: CFString, in properties: [CFString: Any]) -> Int? {
        if let value = properties[key] as? Int {
            return value
        }

        if let value = properties[key] as? NSNumber {
            return value.intValue
        }

        return nil
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension ClipboardStore {
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

private actor ClipboardHistoryPersistenceWriter {
    func write(_ entries: [ClipboardEntry], to url: URL) throws {
        try Self.writeImmediately(entries, to: url)
    }

    nonisolated static func writeImmediately(_ entries: [ClipboardEntry], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: url, options: .atomic)
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
