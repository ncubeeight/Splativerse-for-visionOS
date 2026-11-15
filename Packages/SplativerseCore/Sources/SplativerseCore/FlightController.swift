import Foundation
import simd

public struct FlightHand: Sendable {
    public enum Side: Int, Sendable, CaseIterable { case left, right }
    public let side: Side
    public let position: SIMD3<Float>
    public let orientation: simd_quatf
    public let pinchDistance: Float
    public init(side: Side, position: SIMD3<Float>, orientation: simd_quatf, pinchDistance: Float) {
        self.side = side; self.position = position; self.orientation = orientation; self.pinchDistance = pinchDistance
    }
    fileprivate var valid: Bool {
        position.x.isFinite && position.y.isFinite && position.z.isFinite && pinchDistance.isFinite && pinchDistance >= 0
    }
}

public enum FlightPanelAction: Sendable, Hashable, CaseIterable { case menu, exit, previous, next }

public struct FlightMotion: Sendable {
    public var forward: Float = 0
    public var yaw: Float = 0
    /// Current physical headset viewing direction, including pitch.
    public var trackingForward = SIMD3<Float>(0,0,-1)
    public init() {}
}

public struct FlightStick: Sendable {
    public fileprivate(set) var isHeld = false
    public fileprivate(set) var deflection = SIMD2<Float>.zero
    fileprivate var neutral = SIMD3<Float>.zero
    fileprivate var filtered = SIMD2<Float>.zero
    fileprivate mutating func release() { isHeld = false; deflection = .zero; filtered = .zero }
}

/// A single flight lever and a separate placement handle in physical space.
/// Panel placement survives release, head turns, pauses and navigation commands.
public struct FlightController: Sendable {
    public private(set) var stick = FlightStick()
    public private(set) var panelAction: FlightPanelAction?
    private var buttonArmed: Set<FlightHand.Side> = []
    public static func buttonCenter(_ action: FlightPanelAction) -> SIMD3<Float> {
        switch action {
        case .menu: SIMD3(-0.115,0.014,-0.035)
        case .exit: SIMD3(-0.115,0.014,0.035)
        case .previous: SIMD3(0.115,0.014,-0.035)
        case .next: SIMD3(0.115,0.014,0.035)
        }
    }
    public private(set) var canFly = false
    public private(set) var previousEnabled = false
    public private(set) var nextEnabled = false
    public private(set) var panelTransform = matrix_identity_float4x4
    public private(set) var hasPlacement = false
    public var isHeld: Bool { stick.isHeld }
    public var isMovingPanel: Bool { movingSide != nil }
    public static let leverLength: Float = 0.11
    public static let fullTravel: Float = 0.065
    public static let moveHandleCenter = SIMD3<Float>(0,0.028,0.11)
    private var owner: FlightHand.Side?
    private var armed: Set<FlightHand.Side> = []
    private var movingSide: FlightHand.Side?
    private var dragLocalPoint = SIMD3<Float>.zero
    private var dragLastHand = SIMD3<Float>.zero
    public init() {}
    /// Stop interaction without changing the chosen position.
    public mutating func reset() { stick.release(); owner = nil; movingSide = nil; armed.removeAll(); buttonArmed.removeAll(); panelAction = nil }
    public static func restingPanel(head: simd_float4x4) -> simd_float4x4 {
        let yaw = atan2(head.columns.2.x,head.columns.2.z)
        let eye = SIMD3(head.columns.3.x,head.columns.3.y,head.columns.3.z)
        return translation(eye) * rotationY(yaw) * translation(SIMD3(0,-0.40,-0.28))
    }
    public static func restingHandle(head: simd_float4x4) -> SIMD3<Float> {
        let p = restingPanel(head: head) * SIMD4<Float>(0,leverLength,0,1)
        return SIMD3(p.x,p.y,p.z)
    }
    public mutating func bringPanelHere(head: simd_float4x4) {
        reset(); panelTransform = Self.restingPanel(head: head); hasPlacement = true
    }
    /// Window controls nudge the fixed panel, rather than changing head-follow offsets.
    public mutating func adjustPanel(height: Float, distance: Float, head: simd_float4x4) {
        guard height.isFinite, distance.isFinite else { return }
        if !hasPlacement { bringPanelHere(head: head) }
        reset()
        var p = panelTransform.columns.3
        if height != 0 { p.y = min(head.columns.3.y-0.15,max(head.columns.3.y-0.85,p.y+height)) }
        if distance != 0 {
            var direction = SIMD2(p.x-head.columns.3.x,p.z-head.columns.3.z)
            let length = simd_length(direction)
            direction = length > 0.001 ? direction/length : -SIMD2(panelTransform.columns.2.x,panelTransform.columns.2.z)
            let reach = min(0.85,max(0.18,length+distance))
            p.x = head.columns.3.x + direction.x*reach; p.z = head.columns.3.z + direction.y*reach
        }
        let towardHead = SIMD2(head.columns.3.x-p.x,head.columns.3.z-p.z)
        let yaw = simd_length_squared(towardHead) > 0.000001 ? atan2(towardHead.x,towardHead.y) : atan2(panelTransform.columns.2.x,panelTransform.columns.2.z)
        panelTransform = translation(SIMD3(p.x,p.y,p.z)) * rotationY(yaw)
    }
    public static func leverDirection(_ deflection: SIMD2<Float>) -> SIMD3<Float> {
        simd_normalize(SIMD3(deflection.x*fullTravel,leverLength,-deflection.y*fullTravel))
    }
    public mutating func update(head: simd_float4x4, hands: [FlightHand], deltaTime: Float, enabled: Bool, flightAllowed: Bool = true, canGoPrevious: Bool = false, canGoNext: Bool = false, panelButtonsEnabled: Bool = true) -> FlightMotion {
        panelAction = nil
        canFly = flightAllowed; previousEnabled = flightAllowed && canGoPrevious; nextEnabled = flightAllowed && canGoNext
        if enabled && !hasPlacement { bringPanelHere(head: head) }
        guard enabled, deltaTime.isFinite, deltaTime > 0, deltaTime <= 0.15 else { reset(); return FlightMotion() }
        let valid = hands.filter(\.valid)
        // Menu/Exit accept a fresh pinch from either hand, including a free hand
        // while flying. They stop motion before dispatching the scene action.
        for side in panelButtonsEnabled ? FlightHand.Side.allCases : [] {
            guard let hand = valid.first(where: { $0.side == side }) else { buttonArmed.remove(side); continue }
            if hand.pinchDistance > 0.04 { buttonArmed.insert(side) }
            if hand.pinchDistance <= 0.025, buttonArmed.remove(side) != nil {
                let p = panelTransform.inverse * SIMD4(hand.position,1)
                for action in [FlightPanelAction.menu,.exit,.previous,.next] {
                    if action == .previous && !previousEnabled { continue }
                    if action == .next && !nextEnabled { continue }
                    let delta = simd_abs(SIMD3(p.x,p.y,p.z)-Self.buttonCenter(action))
                    if delta.x <= 0.035 && delta.y <= 0.03 && delta.z <= 0.024 {
                        reset(); panelAction = action; return FlightMotion()
                    }
                }
            }
        }
        if let side = movingSide {
            // Placement mode is exclusive: no flight while grasping or releasing the rail.
            guard let hand = valid.first(where: { $0.side == side }), hand.pinchDistance < 0.04,
                  simd_distance(hand.position,dragLastHand) <= 0.20 else { reset(); return FlightMotion() }
            // Radial placement: the front edge faces the physical headset, while
            // the exact point grasped on the rail remains under the pinch.
            let v = SIMD2(head.columns.3.x-hand.position.x,head.columns.3.z-hand.position.z)
            let lengthSquared = simd_length_squared(v)
            var yaw = atan2(panelTransform.columns.2.x,panelTransform.columns.2.z)
            if lengthSquared > 0.000001 {
                let localZ = sqrt(max(0,lengthSquared-dragLocalPoint.x*dragLocalPoint.x))
                yaw = atan2(v.x,v.y)-atan2(-dragLocalPoint.x,localZ)
            }
            let rotation = rotationY(yaw)
            let offset = rotation * SIMD4(dragLocalPoint,0)
            panelTransform = translation(hand.position-SIMD3(offset.x,offset.y,offset.z)) * rotation
            dragLastHand = hand.position
            return FlightMotion()
        }
        if !flightAllowed { stick.release(); owner = nil }
        if let owner {
            guard let hand = valid.first(where: { $0.side == owner }), hand.pinchDistance < 0.04,
                  simd_distance(hand.position,stick.neutral) < 0.30 else { reset(); return FlightMotion() }
            let delta = hand.position-stick.neutral
            let frame = panelTransform
            let lateral = SIMD3(frame.columns.0.x,frame.columns.0.y,frame.columns.0.z)
            let forward = -SIMD3(frame.columns.2.x,frame.columns.2.y,frame.columns.2.z)
            let travel = SIMD2(simd_dot(delta,lateral),simd_dot(delta,forward))
            stick.deflection = simd_clamp(travel/Self.fullTravel,SIMD2(repeating: -1),SIMD2(repeating: 1))
            let requested = SIMD2(Self.axis(travel.x),Self.axis(travel.y))
            let alpha = 1-exp(-min(deltaTime,1/30)/0.06)
            stick.filtered += (requested-stick.filtered)*alpha
            for i in 0..<2 where requested[i] == 0 { stick.filtered[i] = 0 }
            var motion = FlightMotion()
            motion.forward = stick.filtered.y*2; motion.yaw = -stick.filtered.x * .pi/4
            motion.trackingForward = simd_normalize(-SIMD3(head.columns.2.x,head.columns.2.y,head.columns.2.z))
            return motion
        }
        for side in FlightHand.Side.allCases {
            guard let hand = valid.first(where: { $0.side == side }) else { armed.remove(side); continue }
            if hand.pinchDistance > 0.04 { armed.insert(side) }
            if hand.pinchDistance <= 0.025 {
                guard armed.remove(side) != nil else { continue }
                let local4 = panelTransform.inverse * SIMD4(hand.position,1)
                let local = SIMD3(local4.x,local4.y,local4.z)
                // Capsule hit region for the horizontal move rail, separated from the stick.
                let nearest = Self.moveHandleCenter + SIMD3(min(0.05,max(-0.05,local.x)),0,0)
                if simd_distance(local,nearest) < 0.03 {
                    movingSide = side; dragLocalPoint = local; dragLastHand = hand.position
                    armed.removeAll()
                    return FlightMotion()
                }
                if flightAllowed && simd_distance(local,SIMD3(0,Self.leverLength,0)) <= 0.055 {
                    owner = side; stick.isHeld = true; stick.neutral = hand.position; armed.removeAll()
                    return FlightMotion()
                }
            }
        }
        return FlightMotion()
    }
    private static func axis(_ value: Float) -> Float {
        let magnitude = max(0,min(1,(abs(value)-0.01)/(fullTravel-0.01)))
        return value < 0 ? -magnitude : magnitude
    }
}

extension NavigationPose {
    public mutating func fly(_ motion: FlightMotion, deltaTime: Float, head: simd_float4x4) {
        guard deltaTime.isFinite, deltaTime > 0, deltaTime <= 0.15 else { return }
        let dt = min(deltaTime,1/30)
        snapTurn(radians: motion.yaw*dt,head: head)
        let direction = worldFromTracking * SIMD4(motion.trackingForward,0)
        // Translate along the live gaze vector; only yaw changes virtual orientation.
        worldFromTracking = translation(SIMD3(direction.x,direction.y,direction.z)*motion.forward*dt) * worldFromTracking
    }
}
