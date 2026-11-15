import simd

public struct EstimatedSpawn: Sendable {
    /// Position in oriented, metre-scaled scan coordinates, before app alignment.
    public let eye: SIMD3<Float>
    public let densityCenter: SIMD3<Float>
    public let yaw: Float
}

/// A bounded, deterministic reservoir avoids keeping another full scan in memory.
/// Splats describe surfaces, not camera poses: this is a geometric starting estimate.
public struct DensitySpawnEstimator: Sendable {
    public static let sampleLimit = 65_536
    private var points: [SIMD3<Float>] = []
    private var seen: UInt64 = 0
    private var randomState: UInt64 = 0x53504c4154495645
    public init() { points.reserveCapacity(Self.sampleLimit) }
    public var sampleCount: Int { points.count }
    public mutating func add(_ point: SIMD3<Float>, opacity: Float = 1) {
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite,
              simd_reduce_max(simd_abs(point)) < 1e12, opacity >= 0.05 else { return }
        seen += 1
        if points.count < Self.sampleLimit { points.append(point); return }
        randomState &+= 0x9e3779b97f4a7c15
        var z = randomState
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        z ^= z >> 31
        let index = z % seen
        if index < UInt64(Self.sampleLimit) { points[Int(index)] = point }
    }
    private struct Cell: Hashable, Comparable {
        let x: Int64, y: Int64, z: Int64
        init(_ point: SIMD3<Float>) {
            x = Int64(floor(Double(point.x) / 4)); y = Int64(floor(Double(point.y) / 4)); z = Int64(floor(Double(point.z) / 4))
        }
        init(x: Int64, y: Int64, z: Int64) { self.x = x; self.y = y; self.z = z }
        static func < (a: Self, b: Self) -> Bool {
            if a.x != b.x { return a.x < b.x }
            if a.y != b.y { return a.y < b.y }
            return a.z < b.z
        }
        func neighbors(_ other: Cell) -> Bool { abs(x - other.x) <= 1 && abs(y - other.y) <= 1 && abs(z - other.z) <= 1 }
    }
    public func estimate() -> EstimatedSpawn? {
        guard !points.isEmpty else { return nil }
        var counts: [Cell: Int] = [:]
        for p in points { counts[Cell(p), default: 0] += 1 }
        var winner: Cell?
        var bestCount = 0
        // Include neighboring cells to keep a dense cluster spanning a grid boundary together.
        for cell in counts.keys {
            var count = 0
            for x in -1...1 { for y in -1...1 { for z in -1...1 {
                count += counts[Cell(x: cell.x + Int64(x), y: cell.y + Int64(y), z: cell.z + Int64(z)), default: 0]
            } } }
            if count > bestCount || (count == bestCount && (winner == nil || cell < winner!)) { winner = cell; bestCount = count }
        }
        guard let winner else { return nil }
        let local = points.filter { winner.neighbors(Cell($0)) }
        let sum = local.reduce(SIMD3<Double>.zero) { $0 + SIMD3<Double>($1) }
        let center = SIMD3<Float>(sum / Double(local.count))
        // A local low percentile is less sensitive to isolated ground outliers than min-Y.
        let heights = local.map(\.y).sorted()
        let floorY = heights[min(heights.count - 1, heights.count / 20)]
        let eyeY = floorY + 1.65
        func clearance(_ candidate: SIMD3<Float>) -> Float {
            var squared = Float.greatestFiniteMagnitude
            for p in local where p.y > floorY + 0.2 && p.y < eyeY + 0.25 {
                let d = SIMD2(p.x - candidate.x, p.z - candidate.z)
                squared = min(squared, simd_length_squared(d))
            }
            return squared
        }
        var eye = SIMD3(center.x, eyeY, center.z)
        var bestClearance = clearance(eye)
        // Prefer the density centre. If occupied, choose the nearest sampled opening.
        if bestClearance < 0.25 {
            search: for radius: Float in [0.5, 1, 1.5, 2, 3] {
                for index in 0..<16 {
                    let angle = Float(index) * .pi / 8
                    let candidate = SIMD3(center.x + cos(angle) * radius, eyeY, center.z + sin(angle) * radius)
                    let candidateClearance = clearance(candidate)
                    if candidateClearance > bestClearance { eye = candidate; bestClearance = candidateClearance }
                    if candidateClearance >= 0.25 { eye = candidate; break search }
                }
            }
        }
        let direction = SIMD2(center.x - eye.x, center.z - eye.z)
        let yaw: Float = simd_length_squared(direction) > 0.0625 ? atan2(-direction.x, -direction.y) : 0
        return EstimatedSpawn(eye: eye, densityCenter: center, yaw: yaw)
    }
}
