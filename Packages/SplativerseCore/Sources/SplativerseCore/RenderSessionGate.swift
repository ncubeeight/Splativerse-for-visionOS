import Foundation

/// Prevent a new scan allocating its buffers before the previous session drains.
public actor RenderSessionGate {
    private var owner: UUID?
    public init() {}
    public func acquire(_ id: UUID, shouldStop: @Sendable () -> Bool = { false }) async throws {
        while owner != nil {
            try Task.checkCancellation()
            if shouldStop() { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        if shouldStop() { throw CancellationError() }
        owner = id
    }
    public func release(_ id: UUID) { if owner == id { owner = nil } }
    public var activeSession: UUID? { owner }
}
