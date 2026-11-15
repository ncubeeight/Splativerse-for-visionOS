import XCTest
import CryptoKit
import simd
@testable import SplativerseCore

@MainActor
final class SplativerseCoreTests: XCTestCase {
    private func fixture() throws -> (URL, ScanLibrary) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SplativerseTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, ScanLibrary(documentsDirectory: root.appendingPathComponent("Documents"), supportDirectory: root.appendingPathComponent("Support"), fileAccess: LocalFileAccess()))
    }
    private func source(_ root: URL, name: String, content: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return url
    }
    func testFirstRunCreatesAppFolderAndRestoresLibrary() async throws {
        let (root, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try await library.prepare()
        XCTAssertTrue(initial.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.directory.path))
        let file = try source(root, name: "Downloads/room.ply", content: "room data")
        let imported = await library.importFiles([file])
        XCTAssertEqual(imported.imported, 1)
        XCTAssertEqual(try Data(contentsOf: file), Data("room data".utf8), "Import must not change source files")
        let records = await library.allRecords()
        try XCTSkipIf(records.isEmpty, "No imported record")
        var settings = ScanSettings(); settings.metresPerUnit = 0.01; settings.upAxis = .zUp; settings.bubbleRadius = 180
        try await library.updateSettings(id: records[0].id, settings: settings)
        let restored = ScanLibrary(documentsDirectory: root.appendingPathComponent("Documents"), supportDirectory: root.appendingPathComponent("Support"), fileAccess: LocalFileAccess())
        let restoredRecords = try await restored.prepare()
        XCTAssertEqual(restoredRecords[0].id, records[0].id)
        XCTAssertEqual(restoredRecords[0].settings, settings)
    }
    func testDuplicateContentAndFilenameCollisions() async throws {
        let (root, library) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await library.prepare()
        let a = try source(root, name: "A/room.ply", content: "first")
        let b = try source(root, name: "B/room.ply", content: "second")
        let same = try source(root, name: "C/copy.ply", content: "first")
        let result = await library.importFiles([a, b, same, a])
        XCTAssertEqual(result.imported, 2); XCTAssertEqual(result.duplicates, 2)
        let records = await library.allRecords()
        XCTAssertEqual(Set(records.map(\.filename)).count, 2)
        let data = try records.map { try Data(contentsOf: library.directory.appendingPathComponent($0.filename)) }
        XCTAssertEqual(Set(data), Set([Data("first".utf8), Data("second".utf8)]))
    }
    func testMultiChunkImportPreservesDigestAndDeduplicates() async throws {
        let (root, library) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await library.prepare()
        // Cross two full hash chunks and exercise the final partial chunk.
        var content = Data(repeating: 0x5a, count: 2 * 1024 * 1024 + 17)
        content[1024 * 1024] = 0xa5
        content[content.count - 1] = 0xff
        let file = root.appendingPathComponent("large.ply")
        try content.write(to: file)
        let expected = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let report = await library.importFiles([file, file])
        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(report.duplicates, 1)
        XCTAssertTrue(report.failures.isEmpty)
        let records = await library.allRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.digest, expected)
        XCTAssertEqual(records.first?.byteCount, Int64(content.count))
        XCTAssertEqual(try Data(contentsOf: library.directory.appendingPathComponent("large.ply")), content)
    }

    func testDownloadsBookmarkRecursiveScanAndRepeatImport() async throws {
        let (root, library) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await library.prepare()
        _ = try source(root, name: "Downloads/a.PLY", content: "first")
        _ = try source(root, name: "Downloads/nested/b.spz", content: "second")
        _ = try source(root, name: "Downloads/unrelated.txt", content: "ignored")
        let first = try await library.connectDownloads(root.appendingPathComponent("Downloads"))
        XCTAssertEqual(first.imported, 2); XCTAssertTrue(first.failures.isEmpty)
        let repeatScan = try await library.rescanDownloads()
        XCTAssertEqual(repeatScan.imported, 0); XCTAssertEqual(repeatScan.duplicates, 2)
    }
    func testPartialImportAndExternalFilesDiscovery() async throws {
        let (root, library) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await library.prepare()
        let file = try source(root, name: "a.ply", content: "valid copy")
        let text = try source(root, name: "readme.txt", content: "unsupported")
        let result = await library.importFiles([text, file, root.appendingPathComponent("missing.spz")])
        XCTAssertEqual(result.imported, 1, result.failures.joined(separator: "; ")); XCTAssertEqual(result.failures.count, 2)
        try Data("external".utf8).write(to: library.directory.appendingPathComponent("external.spz"))
        let refreshed = try await library.refresh()
        XCTAssertEqual(refreshed.count, 2)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: library.directory.path).contains { $0.hasPrefix(".incoming") })
    }
    func testSnapTurnKeepsCurrentHeadPositionAndStepsFollowView() {
        var pose = NavigationPose()
        var head = translation(SIMD3<Float>(3, 1.7, 4))
        pose.begin(at: head)
        head = translation(SIMD3<Float>(4, 1.7, 4))
        let before = (pose.worldFromTracking * head).columns.3
        pose.snapTurn(radians: .pi / 2, head: head)
        let after = (pose.worldFromTracking * head).columns.3
        XCTAssertLessThan(simd_length(before - after), 0.0001, "Snap turn must pivot at the user, not the origin")
        pose.step(forward: 1, right: 0, head: head)
        let moved = (pose.worldFromTracking * head).columns.3
        XCTAssertEqual(moved.x, before.x - 1, accuracy: 0.0001)
        XCTAssertEqual(moved.z, before.z, accuracy: 0.0001)
        XCTAssertEqual(moved.y, 1.65, accuracy: 0.0001)
    }
    func testAxisConversionsPreserveDistances() {
        for axis in ScanUpAxis.allCases {
            let transform = sourceOrientation(axis)
            let p = transform * SIMD4<Float>(15, 20, 30, 0)
            XCTAssertEqual(simd_length(p), simd_length(SIMD4<Float>(15, 20, 30, 0)), accuracy: 0.0001)
        }
        XCTAssertEqual((sourceOrientation(.yDown) * SIMD4<Float>(0, -5, 0, 0)).y, 5, accuracy: 0.0001)
        XCTAssertEqual((sourceOrientation(.zUp) * SIMD4<Float>(0, 0, 5, 0)).y, 5, accuracy: 0.0001)
    }
}

// Unit tests exercise copy/dedupe/manifest logic without the host's unavailable
// File Provider and ScopedBookmarksAgent services. Device checks cover that boundary.
private struct LocalFileAccess: LibraryFileAccess {
    func copy(from source: URL, to destination: URL) throws { try FileManager.default.copyItem(at: source, to: destination) }
    func bookmark(for url: URL) throws -> Data { Data(url.absoluteString.utf8) }
    func resolve(_ data: Data, stale: inout Bool) throws -> URL { URL(string: String(decoding: data, as: UTF8.self))! }
}
