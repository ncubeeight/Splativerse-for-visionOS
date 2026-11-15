import Foundation
import simd

/// Value-only events cross from the compositor's main-thread callback to rendering.
public struct FlightPanelEvent: Sendable {
    public enum Phase: Sendable { case active, ended, cancelled }
    public let id: UUID
    public let phase: Phase
    public let origin: SIMD3<Float>?
    public let direction: SIMD3<Float>?
    public let point: SIMD3<Float>?
    public init(id: UUID, phase: Phase, origin: SIMD3<Float>? = nil, direction: SIMD3<Float>? = nil, point: SIMD3<Float>? = nil) {
        self.id = id; self.phase = phase; self.origin = origin; self.direction = direction; self.point = point
    }
}

/// Captures a button at pinch-down, commits once on release, and cancels drags off it.
/// Only system-provided selection rays are used; the app never estimates eye gaze.
public struct FlightPanelInput: Sendable {
    private struct Capture: Sendable { let target: FlightPanelAction?; var inside: Bool }
    private var captures: [UUID: Capture] = [:]
    public init() {}
    public var pressed: Set<FlightPanelAction> { Set(captures.values.compactMap { $0.inside ? $0.target : nil }) }
    public mutating func reset() { captures.removeAll() }
    public mutating func update(_ event: FlightPanelEvent, panel: simd_float4x4, enabled: Bool,
                                canGoPrevious: Bool, canGoNext: Bool) -> FlightPanelAction? {
        guard enabled else { reset(); return nil }
        func allowed(_ action: FlightPanelAction) -> Bool {
            switch action { case .previous: canGoPrevious; case .next: canGoNext; default: true }
        }
        if event.phase == .cancelled { captures.removeValue(forKey: event.id); return nil }
        let hit = Self.hit(event, panel: panel).flatMap { allowed($0) ? $0 : nil }
        if event.phase == .active {
            if var capture = captures[event.id] {
                capture.inside = capture.target != nil && hit == capture.target
                captures[event.id] = capture
            } else {
                captures[event.id] = Capture(target: hit, inside: hit != nil)
            }
            return nil
        }
        guard let capture = captures.removeValue(forKey: event.id), let target = capture.target, allowed(target) else { return nil }
        let hasLocation = event.origin != nil || event.direction != nil || event.point != nil
        return (hasLocation ? hit == target : capture.inside) ? target : nil
    }
    private static func hit(_ event: FlightPanelEvent, panel: simd_float4x4) -> FlightPanelAction? {
        func finite(_ p: SIMD3<Float>) -> Bool { p.x.isFinite && p.y.isFinite && p.z.isFinite }
        let inverse = panel.inverse
        let local: SIMD3<Float>
        if let origin = event.origin, let direction = event.direction {
            guard finite(origin), finite(direction) else { return nil }
            let p = inverse * SIMD4(origin,1), d = inverse * SIMD4(direction,0)
            // Accept only the top face, never a ray aimed away or parallel to it.
            guard d.y < -0.00001 else { return nil }
            let t = (FlightController.buttonCenter(.menu).y-p.y)/d.y
            guard t.isFinite, t >= 0 else { return nil }
            local = SIMD3(p.x,p.y,p.z)+t*SIMD3(d.x,d.y,d.z)
        } else if let point = event.point, finite(point) {
            let p = inverse * SIMD4(point,1); local = SIMD3(p.x,p.y,p.z)
        } else { return nil }
        guard finite(local) else { return nil }
        return FlightPanelAction.allCases.first {
            let delta = simd_abs(local-FlightController.buttonCenter($0))
            return delta.x <= 0.035 && delta.y <= 0.03 && delta.z <= 0.024
        }
    }
}
