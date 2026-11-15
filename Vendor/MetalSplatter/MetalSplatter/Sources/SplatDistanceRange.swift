import simd

/// Distances are in scan/source units, before the app's metres-per-unit transform.
public struct SplatDistanceRange: Sendable, Equatable {
    public var minimum: Float
    public var maximum: Float
    public init(minimum: Float = 0, maximum: Float = .greatestFiniteMagnitude) {
        self.minimum = minimum
        self.maximum = maximum
    }
    public func contains(squaredDistance: Float) -> Bool {
        squaredDistance >= minimum * minimum && squaredDistance <= maximum * maximum
    }
    /// Conservative block rejection; intersecting blocks are tested per splat.
    public func intersects(minimum low: SIMD3<Float>, maximum high: SIMD3<Float>, center: SIMD3<Float>) -> Bool {
        let closest = simd_max(simd_max(low - center, center - high), .zero)
        let farthest = simd_max(simd_abs(low - center), simd_abs(high - center))
        return simd_length_squared(closest) <= maximum * maximum && simd_length_squared(farthest) >= minimum * minimum
    }
}
