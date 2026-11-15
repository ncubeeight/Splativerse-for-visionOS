import Foundation
import os
import simd
import SplativerseCore

struct RenderRequest: Codable, Hashable, Sendable {
    let id: UUID
    let scanID: UUID
    let fileURL: URL
    let title: String
    let settings: ScanSettings
}

enum NavigationCommand: Sendable {
    case step(forward: Float, right: Float, up: Float)
    case turn(Float)
    case recenter
    case refreshBackground
    case setBubbleRadius(Float)
    case setFlightEnabled(Bool)
    case adjustFlightPanel(height: Float, distance: Float)
    case bringFlightPanelHere
    case loadScan(RenderRequest)
}

struct RenderStatus: Sendable {
    var sessionID: UUID?
    var message = ""
    var splatCount = 0
    var visibleSplatCount = 0
    var bubbleRadius: Float = BubbleConfiguration.defaultRadius
    var flightAvailable = false
    var flightEnabled = true
    var flightHeld = false
    var flightMovingPanel = false
    var flightMessage = "Preparing flight control…"
    var exitRequested = false
    var menuSequence: UInt64 = 0
    var scanStepSequence: UInt64 = 0
    var scanStep = 0
    var scanSwitchPending = false
    var canGoPrevious = false
    var canGoNext = false
    var ready = false
    var closed = false
    var failure: String?
}

/// The SwiftUI actor and render thread exchange only snapshots and queued commands.
final class RenderControl: Sendable {
    static let shared = RenderControl()
    private struct State: Sendable {
        var status = RenderStatus()
        var commands: [NavigationCommand] = []
        var stop = false
        var interactionActive = true
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())
    func begin(_ id: UUID) {
        lock.withLock { $0 = State(status: RenderStatus(sessionID: id, message: "Loading scan…")) }
    }
    func enqueue(_ command: NavigationCommand) {
        lock.withLock {
            guard $0.status.ready, !$0.stop else { return }
            if case .setBubbleRadius = command {
                $0.commands.removeAll { if case .setBubbleRadius = $0 { return true }; return false }
            }
            $0.commands.append(command)
        }
    }
    @discardableResult
    func enqueueScan(_ request: RenderRequest) -> Bool {
        lock.withLock {
            guard $0.status.sessionID == request.id, !$0.stop, $0.status.scanSwitchPending else { return false }
            // A tracking interruption must not silently discard an accepted switch.
            $0.commands.removeAll()
            $0.commands.append(.loadScan(request))
            return true
        }
    }
    func commands(for id: UUID) -> [NavigationCommand] {
        lock.withLock { state in
            guard state.status.sessionID == id else { return [] }
            let commands = state.commands
            state.commands.removeAll(keepingCapacity: true)
            return commands
        }
    }
    func setInteractionActive(_ active: Bool, for id: UUID? = nil) { lock.withLock { if id == nil || $0.status.sessionID == id { $0.interactionActive = active } } }
    func interactionActive() -> Bool { lock.withLock { $0.interactionActive && !$0.stop } }
    func panelAction(_ action: FlightPanelAction, for id: UUID) {
        lock.withLock { state in
            guard state.status.sessionID == id, !state.stop else { return }
            switch action {
            case .menu: state.status.menuSequence &+= 1
            case .exit: state.status.exitRequested = true; state.stop = true
            case .previous, .next:
                guard state.status.ready, !state.status.scanSwitchPending,
                      action == .previous ? state.status.canGoPrevious : state.status.canGoNext else { return }
                state.status.scanStep = action == .previous ? -1 : 1
                state.status.scanStepSequence &+= 1; state.status.scanSwitchPending = true
            }
        }
    }
    func snapshot() -> RenderStatus { lock.withLock { $0.status } }
    func shouldStop(_ id: UUID) -> Bool { lock.withLock { $0.stop || $0.status.sessionID != id } }
    func stop(_ id: UUID) { lock.withLock { if $0.status.sessionID == id { $0.stop = true } } }
    func report(_ id: UUID, _ change: @Sendable (inout RenderStatus) -> Void) {
        lock.withLock { if $0.status.sessionID == id { change(&$0.status) } }
    }
}
