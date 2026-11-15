// Splativerse integration: bounded, lossless streaming between decoding and GPU upload.
import Foundation

public func splativerseYield<Element: Sendable>(_ element: Element, to continuation: AsyncThrowingStream<Element, Error>.Continuation) async throws {
    while true {
        try Task.checkCancellation()
        switch continuation.yield(element) {
        case .enqueued: return
        case .dropped: try await Task.sleep(for: .milliseconds(1))
        case .terminated: throw CancellationError()
        @unknown default: throw CancellationError()
        }
    }
}
