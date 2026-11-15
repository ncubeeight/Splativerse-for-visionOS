import Foundation

protocol LibraryFileAccess: Sendable {
    func copy(from source: URL, to destination: URL) throws
    func bookmark(for url: URL) throws -> Data
    func resolve(_ data: Data, stale: inout Bool) throws -> URL
}
struct SystemLibraryFileAccess: LibraryFileAccess {
    func copy(from source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
            do {
                let info = try readable.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true else { throw LibraryError.unsupportedFile }
                let size = info.fileSize ?? 0
                if let available = try? destination.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
                   Int64(size) + 64 * 1024 * 1024 > available { throw LibraryError.outOfSpace }
                try FileManager.default.copyItem(at: readable, to: destination)
            } catch { copyError = error }
        }
        if let error = coordinationError ?? (copyError as NSError?) { throw error }
    }
    func bookmark(for url: URL) throws -> Data {
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = [.minimalBookmark]
        #endif
        return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    func resolve(_ data: Data, stale: inout Bool) throws -> URL {
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        return try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
