import Foundation
import simd

public func translation(_ p: SIMD3<Float>) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4(p, 1)
    return m
}
public func rotationY(_ angle: Float) -> simd_float4x4 {
    simd_float4x4(simd_quatf(angle: angle, axis: SIMD3(0, 1, 0)))
}
public func sourceOrientation(_ axis: ScanUpAxis) -> simd_float4x4 {
    switch axis {
    case .yUp: matrix_identity_float4x4
    case .yDown: simd_float4x4(simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0)))
    case .zUp: simd_float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0)))
    }
}

/// Physical head pose stays untouched. This matrix maps the tracked room into scan space.
public struct NavigationPose: Sendable {
    public var worldFromTracking = matrix_identity_float4x4
    public init() {}
    public mutating func begin(at head: simd_float4x4, facing yaw: Float? = nil) {
        let position = SIMD3(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        let currentYaw = atan2(head.columns.2.x, head.columns.2.z)
        let orientation = yaw.map { rotationY($0 - currentYaw) } ?? matrix_identity_float4x4
        worldFromTracking = translation(SIMD3(0, 1.65, 0)) * orientation * translation(-position)
    }
    public mutating func step(forward: Float, right: Float, up: Float = 0, head: simd_float4x4) {
        let virtualHead = worldFromTracking * head
        var direction = -SIMD3(virtualHead.columns.2.x, 0, virtualHead.columns.2.z)
        if simd_length_squared(direction) < 0.001 { direction = SIMD3(0, 0, -1) }
        direction = simd_normalize(direction)
        let lateral = simd_cross(direction, SIMD3(0, 1, 0))
        worldFromTracking = translation(direction * forward + lateral * right + SIMD3(0, up, 0)) * worldFromTracking
    }
    public mutating func snapTurn(radians: Float, head: simd_float4x4) {
        let p = (worldFromTracking * head).columns.3
        let pivot = SIMD3(p.x, p.y, p.z)
        worldFromTracking = translation(pivot) * rotationY(radians) * translation(-pivot) * worldFromTracking
    }
}
