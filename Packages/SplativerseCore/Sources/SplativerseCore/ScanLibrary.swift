import Foundation
import CryptoKit

public enum ScanUpAxis: String, Codable, CaseIterable, Sendable {
    case yDown, yUp, zUp
    public var label: String {
        switch self { case .yDown: "Y down (3DGS / SPZ)"; case .yUp: "Y up"; case .zUp: "Z up" }
    }
}

public struct ScanSettings: Codable, Hashable, Sendable {
    public var metresPerUnit: Float = 1
    public var upAxis: ScanUpAxis = .yDown
    public var floorOffset: Float = 0
    public var bubbleRadius: Float = BubbleConfiguration.defaultRadius
    public init() {}
    private enum CodingKeys: String, CodingKey { case metresPerUnit, upAxis, floorOffset, bubbleRadius }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        metresPerUnit = try values.decode(Float.self, forKey: .metresPerUnit)
        upAxis = try values.decode(ScanUpAxis.self, forKey: .upAxis)
        floorOffset = try values.decode(Float.self, forKey: .floorOffset)
        // Accept previous 5–420 m catalogs, then clamp to the current range without losing the library.
        bubbleRadius = try values.decodeIfPresent(Float.self, forKey: .bubbleRadius) ?? BubbleConfiguration.defaultRadius
        guard bubbleRadius.isFinite, (5...420).contains(bubbleRadius) else {
            throw DecodingError.dataCorruptedError(forKey: .bubbleRadius, in: values, debugDescription: "Saved bubble radius is outside the supported catalog range (5–420 metres).")
        }
        bubbleRadius = BubbleConfiguration(radius: bubbleRadius).radius
    }
}

public struct ScanRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var filename: String
    public var byteCount: Int64
    public var digest: String
    public var modifiedAt: Date
    public var settings: ScanSettings
    public var title: String { URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent }
}

public struct ImportReport: Sendable {
    public var imported = 0
    public var duplicates = 0
    public var failures: [String] = []
    public var summary: String {
        "\(imported) imported, \(duplicates) already in library" + (failures.isEmpty ? "." : ". \(failures.count) could not be imported.")
    }
    public init() {}
}

public enum LibraryError: LocalizedError {
    case unsupportedFile, noDownloadsFolder, notDirectory, invalidSettings, outOfSpace
    public var errorDescription: String? {
        switch self {
        case .unsupportedFile: "Choose a PLY, SPZ, or SPLAT scan."
        case .noDownloadsFolder: "Choose your Downloads folder in Files to grant access."
        case .notDirectory: "Choose a folder in Files."
        case .invalidSettings: "Scan scale must be positive and finite, floor adjustment finite, and bubble radius between 60 and 420 metres."
        case .outOfSpace: "There is not enough free storage to copy this scan."
        }
    }
}

/// All disk work is serialized here, off the UI actor. Import only copies source files.
public actor ScanLibrary {
    public nonisolated let directory: URL
    private let support: URL
    private var records: [ScanRecord] = []
    private let fileAccess: any LibraryFileAccess
    private let fm = FileManager.default
    private let allowed = Set(["ply", "spz", "splat"])
    private var manifest: URL { support.appendingPathComponent("library.json") }
    private var bookmark: URL { support.appendingPathComponent("downloads.bookmark") }

    public init(documentsDirectory: URL, supportDirectory: URL) {
        directory = documentsDirectory.appendingPathComponent("Scans", isDirectory: true)
        support = supportDirectory
        fileAccess = SystemLibraryFileAccess()
    }

    // Test seam for file-provider coordination and security-scoped bookmarks.
    init(documentsDirectory: URL, supportDirectory: URL, fileAccess: any LibraryFileAccess) {
        directory = documentsDirectory.appendingPathComponent("Scans", isDirectory: true)
        support = supportDirectory
        self.fileAccess = fileAccess
    }

    public func prepare() throws -> [ScanRecord] {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        if fm.fileExists(atPath: manifest.path) {
            // A corrupt manifest is reported, never silently overwritten.
            records = try JSONDecoder().decode([ScanRecord].self, from: Data(contentsOf: manifest))
        }
        return try refresh()
    }

    public func refresh() throws -> [ScanRecord] {
        let files = try fm.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: .skipsHiddenFiles)
            .filter { allowed.contains($0.pathExtension.lowercased()) }
        var refreshed: [ScanRecord] = []
        for file in files {
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { continue }
            let bytes = Int64(info.fileSize ?? 0), modified = info.contentModificationDate ?? .distantPast
            if var existing = records.first(where: { $0.filename == file.lastPathComponent }) {
                if existing.byteCount != bytes || existing.modifiedAt != modified {
                    existing.digest = try Self.sha256(file)
                    existing.byteCount = bytes
                    existing.modifiedAt = modified
                }
                refreshed.append(existing)
            } else {
                refreshed.append(ScanRecord(id: UUID(), filename: file.lastPathComponent, byteCount: bytes,
                    digest: try Self.sha256(file), modifiedAt: modified, settings: ScanSettings()))
            }
        }
        records = refreshed.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        try persist()
        return records
    }

    public func allRecords() -> [ScanRecord] { records }
    public func hasDownloadsFolder() -> Bool { fm.fileExists(atPath: bookmark.path) }
    public func fileURL(for record: ScanRecord) -> URL { directory.appendingPathComponent(record.filename) }

    public func updateSettings(id: UUID, settings: ScanSettings) throws {
        guard settings.metresPerUnit.isFinite, settings.metresPerUnit > 0, settings.floorOffset.isFinite, settings.bubbleRadius.isFinite, BubbleConfiguration.radiusLimits.contains(settings.bubbleRadius) else { throw LibraryError.invalidSettings }
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let old = records[index].settings
        records[index].settings = settings
        do { try persist() } catch { records[index].settings = old; throw error }
    }

    public func connectDownloads(_ url: URL) throws -> ImportReport {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw LibraryError.notDirectory }
        let data = try fileAccess.bookmark(for: url)
        try data.write(to: bookmark, options: .atomic)
        return try importFolderContents(url)
    }

    public func rescanDownloads() throws -> ImportReport {
        guard fm.fileExists(atPath: bookmark.path) else { throw LibraryError.noDownloadsFolder }
        var stale = false
        let url = try fileAccess.resolve(Data(contentsOf: bookmark), stale: &stale)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if stale { return try connectDownloads(url) }
        return try importFolderContents(url)
    }

    private func importFolderContents(_ url: URL) throws -> ImportReport {
        var report = ImportReport()
        var enumerationErrors: [String] = []
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { failedURL, error in
                enumerationErrors.append("\(failedURL.lastPathComponent): \(error.localizedDescription)")
                return true
            }) else { throw LibraryError.notDirectory }
        for case let file as URL in walker {
            if file.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") || file.standardizedFileURL == directory.standardizedFileURL {
                walker.skipDescendants(); continue
            }
            do {
                let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if info.isSymbolicLink == true { walker.skipDescendants(); continue }
                guard info.isRegularFile == true, allowed.contains(file.pathExtension.lowercased()) else { continue }
                if try importOne(file) { report.imported += 1 } else { report.duplicates += 1 }
            } catch { report.failures.append("\(file.lastPathComponent): \(error.localizedDescription)") }
        }
        report.failures.append(contentsOf: enumerationErrors)
        return report
    }

    public func importFiles(_ urls: [URL]) -> ImportReport {
        var report = ImportReport()
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                if try importOne(url) { report.imported += 1 } else { report.duplicates += 1 }
            } catch { report.failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        return report
    }

    private func importOne(_ source: URL) throws -> Bool {
        guard allowed.contains(source.pathExtension.lowercased()) else { throw LibraryError.unsupportedFile }
        // Copy while coordinated: this also asks cloud/File Provider sources to materialize the file.
        let staged = directory.appendingPathComponent(".incoming-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staged) }
        try fileAccess.copy(from: source, to: staged)
        let digest = try Self.sha256(staged)
        if records.contains(where: { $0.digest == digest && fm.fileExists(atPath: directory.appendingPathComponent($0.filename).path) }) { return false }
        var name = source.lastPathComponent
        if fm.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = "\(source.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(8)).\(source.pathExtension.lowercased())"
        }
        let destination = directory.appendingPathComponent(name)
        try fm.moveItem(at: staged, to: destination)
        do {
            let values = try destination.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            records.append(ScanRecord(id: UUID(), filename: name, byteCount: Int64(values.fileSize ?? 0), digest: digest,
                modifiedAt: values.contentModificationDate ?? Date(), settings: ScanSettings()))
            try persist()
        } catch {
            records.removeAll { $0.filename == name }
            // Keep the completed copy: the next refresh can rediscover it.
            throw error
        }
        return true
    }

    private func persist() throws { try JSONEncoder().encode(records).write(to: manifest, options: .atomic) }
    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        // FileHandle's Foundation buffers can remain autoreleased until this entire
        // synchronous actor operation returns. Drain each chunk before reading the
        // next, so multi-gigabyte scans do not accumulate in memory during hashing.
        while try autoreleasepool(invoking: {
            guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
            hash.update(data: data)
            return true
        }) { }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
