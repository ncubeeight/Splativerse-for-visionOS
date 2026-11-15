import XCTest
@testable import SplativerseCore

final class RenderSessionGateTests: XCTestCase, @unchecked Sendable {
    func testNewSessionWaitsForCleanupAndStaleReleaseCannotUnlockIt() async throws {
        let gate = RenderSessionGate(), first = UUID(), second = UUID()
        try await gate.acquire(first)
        let next = Task { try await gate.acquire(second); return await gate.activeSession }
        try await Task.sleep(for: .milliseconds(80))
        var owner = await gate.activeSession
        XCTAssertEqual(owner,first)
        await gate.release(UUID())
        owner = await gate.activeSession; XCTAssertEqual(owner,first)
        await gate.release(first)
        let result = try await next.value; XCTAssertEqual(result,second)
        await gate.release(first)
        owner = await gate.activeSession; XCTAssertEqual(owner,second)
        await gate.release(second)
    }
    func testCanceledWaitingSessionDoesNotBlockNextLoad() async throws {
        let gate = RenderSessionGate(), first = UUID(), second = UUID()
        try await gate.acquire(first)
        let canceled = Task { try await gate.acquire(second) }
        canceled.cancel()
        do { try await canceled.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        await gate.release(first)
        try await gate.acquire(second)
        let owner = await gate.activeSession; XCTAssertEqual(owner,second)
        await gate.release(second)
    }
}
