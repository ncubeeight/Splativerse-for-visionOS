import XCTest
import simd
@testable import SplativerseCore

final class SpawnAndRadiusTests: XCTestCase {
    func testLegacySettingsDefaultToSixtyMetres() throws {
        let legacy = Data(#"{"metresPerUnit":0.01,"upAxis":"zUp","floorOffset":0.25}"#.utf8)
        let settings = try JSONDecoder().decode(ScanSettings.self, from: legacy)
        XCTAssertEqual(settings.bubbleRadius, 60)
        XCTAssertEqual(settings.metresPerUnit, 0.01)
        var changed = settings; changed.bubbleRadius = 240
        XCTAssertEqual(try JSONDecoder().decode(ScanSettings.self, from: JSONEncoder().encode(changed)), changed)
    }
    func testLargeRadiusPresetsKeepOverlapValid() {
        for radius: Float in [60, 120, 180, 240, 300, 360] {
            let configuration = BubbleConfiguration(radius: radius)
            XCTAssertEqual(configuration.radius, radius)
            XCTAssertGreaterThan(configuration.fadeStart, 0)
            XCTAssertLessThan(configuration.fadeStart, radius)
            XCTAssertEqual(configuration.refreshDistance, configuration.overlap)
            XCTAssertLessThanOrEqual(configuration.overlap, 5)
        }
        XCTAssertEqual(BubbleConfiguration(radius: .nan).radius, 60)
        XCTAssertEqual(BubbleConfiguration(radius: 1).radius, 60)
        XCTAssertEqual(BubbleConfiguration(radius: 500).radius, 360)
    }
    func testOldRadiiIncluding420MigrateWithoutLosingOtherSettings() throws {
        for radius in [5,12,30,59,60,120,180,240,300,360,420] {
            let json = Data("{\"metresPerUnit\":0.01,\"upAxis\":\"zUp\",\"floorOffset\":1.5,\"bubbleRadius\":\(radius)}".utf8)
            let settings = try JSONDecoder().decode(ScanSettings.self,from: json)
            XCTAssertEqual(settings.bubbleRadius,Float(min(360,max(60,radius))))
            XCTAssertEqual(settings.floorOffset,1.5); XCTAssertEqual(settings.metresPerUnit,0.01)
        }
    }
    func testInvalidSavedRadiusIsRejected() {
        let json = Data(#"{"metresPerUnit":1,"upAxis":"yUp","floorOffset":0,"bubbleRadius":-1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ScanSettings.self, from: json))
    }
    func testDensitySpawnIgnoresSparseExtentAndTransparentOutliers() throws {
        var estimator = DensitySpawnEstimator()
        for x in 0..<30 { for z in 0..<30 {
            estimator.add(SIMD3(100 + Float(x) / 15, 0, 20 + Float(z) / 15))
        } }
        for i in 0..<20 { estimator.add(SIMD3(-1000 - Float(i) * 20, -200, -500)) }
        for _ in 0..<2000 { estimator.add(SIMD3(-500, 0, -500), opacity: 0.001) }
        let spawn = try XCTUnwrap(estimator.estimate())
        XCTAssertEqual(spawn.eye.x, 100.9667, accuracy: 0.05)
        XCTAssertEqual(spawn.eye.z, 20.9667, accuracy: 0.05)
        XCTAssertEqual(spawn.eye.y, 1.65, accuracy: 0.001)
    }
    func testClusterAcrossCellBoundaryStaysTogether() throws {
        var estimator = DensitySpawnEstimator()
        for _ in 0..<100 { estimator.add(SIMD3(3.9,0,3.9)); estimator.add(SIMD3(4.1,0,4.1)) }
        let spawn = try XCTUnwrap(estimator.estimate())
        XCTAssertEqual(spawn.densityCenter.x, 4, accuracy: 0.001)
        XCTAssertEqual(spawn.densityCenter.z, 4, accuracy: 0.001)
    }
    func testOccupiedDensityCenterUsesNearbyOpeningAndLooksBack() throws {
        var estimator = DensitySpawnEstimator()
        for y in 0..<20 { for z in 0..<40 { estimator.add(SIMD3(10, 0.5 + Float(y) * 0.075, 10 + Float(z) * 0.05)) } }
        for x in 0..<20 { for z in 0..<20 { estimator.add(SIMD3(9.5 + Float(x) * 0.05, 0, 10 + Float(z) * 0.1)) } }
        let spawn = try XCTUnwrap(estimator.estimate())
        XCTAssertGreaterThanOrEqual(abs(spawn.eye.x - 10), 0.45)
        XCTAssertEqual(spawn.eye.y, 1.65, accuracy: 0.001)
        let forward = rotationY(spawn.yaw) * SIMD4<Float>(0,0,-1,0)
        let direction = simd_normalize(SIMD2(spawn.densityCenter.x - spawn.eye.x, spawn.densityCenter.z - spawn.eye.z))
        XCTAssertGreaterThan(simd_dot(SIMD2(forward.x, forward.z), direction), 0.99)
    }
    func testSamplingIsBoundedAndDeterministic() throws {
        var a = DensitySpawnEstimator(), b = DensitySpawnEstimator()
        for i in 0..<100_000 {
            let point = SIMD3<Float>(Float(i % 10), 0, Float(i % 17))
            a.add(point); b.add(point)
        }
        XCTAssertEqual(a.sampleCount, DensitySpawnEstimator.sampleLimit)
        XCTAssertEqual(try XCTUnwrap(a.estimate()).eye, try XCTUnwrap(b.estimate()).eye)
        XCTAssertNil(DensitySpawnEstimator().estimate())
    }
    func testBeginAndReturnToStartAlignHeadToEstimatedHeading() {
        let head = translation(SIMD3(8,1.8,-4)) * rotationY(0.7)
        var pose = NavigationPose()
        pose.begin(at: head, facing: -.pi / 2)
        let virtual = pose.worldFromTracking * head
        XCTAssertLessThan(simd_distance(virtual.columns.3, SIMD4(0,1.65,0,1)), 0.0001)
        let forward = virtual * SIMD4<Float>(0,0,-1,0)
        XCTAssertEqual(forward.x, 1, accuracy: 0.0001)
        XCTAssertEqual(forward.z, 0, accuracy: 0.0001)
    }
}
