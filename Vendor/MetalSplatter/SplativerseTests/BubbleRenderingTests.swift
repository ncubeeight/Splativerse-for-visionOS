import XCTest
import Metal
import simd
import SplatIO
@testable import MetalSplatter

final class BubbleRenderingTests: XCTestCase, @unchecked Sendable {
    func testSwiftUniformLayoutMatchesMetalHeader() {
        XCTAssertEqual(MemoryLayout<SplatRenderer.Uniforms>.offset(of: \.fadeRange), 184)
        XCTAssertEqual(MemoryLayout<SplatRenderer.Uniforms>.stride, 192)
    }
    func testThirtyMetreSphereInEveryDirection() {
        let range = SplatDistanceRange(maximum: 30)
        for axis in [SIMD3<Float>(1,0,0), SIMD3(-1,0,0), SIMD3(0,1,0), SIMD3(0,-1,0), SIMD3(0,0,1), SIMD3(0,0,-1)] {
            XCTAssertTrue(range.contains(squaredDistance: simd_length_squared(axis * 30)))
            XCTAssertFalse(range.contains(squaredDistance: simd_length_squared(axis * 30.01)))
        }
        XCTAssertFalse(range.contains(squaredDistance: simd_length_squared(SIMD3<Float>(20,20,20))), "Must be spherical, not a 60 m cube")
    }
    func testRadiusRespectsScanUnits() {
        for units: Float in [1, 0.01, 0.001] {
            let range = SplatDistanceRange(maximum: 30 / units)
            XCTAssertTrue(range.contains(squaredDistance: pow(29 / units, 2)))
            XCTAssertFalse(range.contains(squaredDistance: pow(31 / units, 2)))
        }
    }
    func testSpatialBlocksRejectOnlyOutsideTheRange() {
        let near = SplatDistanceRange(maximum: 30)
        XCTAssertFalse(near.intersects(minimum: SIMD3(31,0,0), maximum: SIMD3(40,1,1), center: .zero))
        XCTAssertTrue(near.intersects(minimum: SIMD3(29,-1,-1), maximum: SIMD3(40,1,1), center: .zero))
        XCTAssertTrue(near.intersects(minimum: SIMD3(99,-1,-1), maximum: SIMD3(101,1,1), center: SIMD3(100,0,0)))
        let far = SplatDistanceRange(minimum: 25)
        XCTAssertFalse(far.intersects(minimum: SIMD3(-1,-1,-1), maximum: SIMD3(1,1,1), center: .zero))
        XCTAssertTrue(far.intersects(minimum: SIMD3(24,0,0), maximum: SIMD3(26,1,1), center: .zero))
    }
    func testCubeDirectionsAndSharedEdgeAgree() {
        let directions: [SIMD3<Float>] = [SIMD3(1,0,0), SIMD3(-1,0,0), SIMD3(0,1,0), SIMD3(0,-1,0), SIMD3(0,0,1), SIMD3(0,0,-1)]
        for face in 0..<6 {
            let camera = SplatPanorama.camera(face: face, at: SIMD3(10,20,30))
            let ray = camera * SIMD4<Float>(0,0,-1,0)
            XCTAssertLessThan(simd_distance(SIMD3(ray.x, ray.y, ray.z), directions[face]), 0.0001)
            XCTAssertEqual(simd_determinant(camera), -1, accuracy: 0.0001, "Cube face basis includes the texture-coordinate reflection")
        }
        let positiveXLeft = SplatPanorama.camera(face: 0, at: .zero) * SIMD4<Float>(-1,0,-1,0)
        let positiveZRight = SplatPanorama.camera(face: 4, at: .zero) * SIMD4<Float>(1,0,-1,0)
        XCTAssertLessThan(simd_distance(positiveXLeft, positiveZRight), 0.0001)
    }
    private func device() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable in this host environment") }
        return device
    }
    private func point(_ p: SIMD3<Float>, color: SIMD3<UInt8> = SIMD3(255,0,0)) -> SplatPoint {
        SplatPoint(position: p, color: .sRGBUInt8(color), opacity: .linearFloat(1), scale: .linearFloat(SIMD3(repeating: 3)), rotation: simd_quatf(angle: 0, axis: SIMD3(0,1,0)))
    }
    func testSorterMovesBubbleAndHandlesEmptyRegions() async throws {
        let device = try device()
        let chunk = try SplatChunk(device: device, from: [point(.zero), point(SIMD3(29,0,0)), point(SIMD3(31,0,0)), point(SIMD3(100,0,0))])
        let sorter = try SplatSorter(device: device, distanceRange: .init(maximum: 30), deferSortingUntilPrepared: true)
        defer { sorter.stop() }
        sorter.setChunks([SplatSorter.ChunkReference(chunkIndex: 0, buffer: chunk.splats)])
        try await sorter.prepare(position: .zero)
        XCTAssertEqual(sorter.latestSplatCount, 2)
        try await sorter.prepare(position: SIMD3(100,0,0))
        XCTAssertEqual(sorter.latestSplatCount, 1)
        try await sorter.prepare(position: SIMD3(1000,0,0))
        XCTAssertEqual(sorter.latestSplatCount, 0)
    }
    func testPanoramaCapturesAllSixDirections() async throws {
        let device = try device()
        let colors: [SIMD3<UInt8>] = [SIMD3(255,0,0), SIMD3(0,255,0), SIMD3(0,0,255), SIMD3(255,255,0), SIMD3(255,0,255), SIMD3(0,255,255)]
        let points = (0..<6).map { face -> SplatPoint in
            let ray = SplatPanorama.camera(face: face, at: .zero) * SIMD4<Float>(0,0,-50,1)
            return point(SIMD3(ray.x, ray.y, ray.z), color: colors[face])
        }
        let blue = MTLClearColor(red: 0.603827, green: 0.791298, blue: 0.955973, alpha: 1)
        let renderer = try SplatRenderer(device: device, colorFormat: .bgra8Unorm_srgb, depthFormat: .invalid,
            sampleCount: 1, maxViewCount: 1, maxSimultaneousRenders: 1, highQualityDepth: false,
            clearColor: blue, distanceRange: .init(minimum: 25), deferSortingUntilPrepared: true)
        defer { renderer.stopSorting() }
        await renderer.addChunk(try SplatChunk(device: device, from: points))
        let panorama = try SplatPanorama(device: device, renderer: renderer, colorFormat: .bgra8Unorm_srgb, depthFormat: .depth32Float, clearColor: blue)
        let cube = try await panorama.capture(at: .zero, worldFromSource: matrix_identity_float4x4)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let buffer = try XCTUnwrap(device.makeBuffer(length: 6 * 256, options: .storageModeShared))
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        for face in 0..<6 {
            blit.copy(from: cube, sourceSlice: face, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 512, y: 512, z: 0), sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                      to: buffer, destinationOffset: face * 256, destinationBytesPerRow: 256, destinationBytesPerImage: 256)
        }
        blit.endEncoding()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            command.addCompletedHandler { _ in continuation.resume() }; command.commit()
        }
        XCTAssertEqual(command.status, .completed)
        let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
        for face in 0..<6 {
            let expected = colors[face]
            for (channel, value) in [expected.z, expected.y, expected.x].enumerated() {
                XCTAssertEqual(Int(bytes[face * 256 + channel]), Int(value), accuracy: 25, "Cube face \(face), channel \(channel)")
            }
        }
    }
    func testVeryLargeProjectedSplatAndInvalidCovarianceDoNotProduceBlack() async throws {
        let device = try device()
        for invalid in [false,true] {
            let renderer = try SplatRenderer(device: device,colorFormat: .bgra8Unorm_srgb,depthFormat: .invalid,
                sampleCount: 1,maxViewCount: 1,maxSimultaneousRenders: 1,highQualityDepth: false,
                clearColor: MTLClearColor(red: 0.603827,green: 0.791298,blue: 0.955973,alpha: 1),deferSortingUntilPrepared: true)
            defer { renderer.stopSorting() }
            // scale=200 produces projected axes larger than Float16's range;
            // scale=100000 overflows the packed covariance itself and must be culled.
            let p = SplatPoint(position: SIMD3(0,0,-1),color: .sRGBUInt8(SIMD3(255,0,0)),opacity: .linearFloat(1),
                scale: .linearFloat(SIMD3(repeating: invalid ? 100000 : 200)),rotation: simd_quatf(angle: 0,axis: SIMD3(0,1,0)))
            await renderer.addChunk(try SplatChunk(device: device,from: [p]))
            let panorama = try SplatPanorama(device: device,renderer: renderer,colorFormat: .bgra8Unorm_srgb,depthFormat: .depth32Float,
                clearColor: MTLClearColor(red: 0.603827,green: 0.791298,blue: 0.955973,alpha: 1))
            let cube = try await panorama.capture(at: .zero,worldFromSource: matrix_identity_float4x4)
            let queue = try XCTUnwrap(device.makeCommandQueue()), command = try XCTUnwrap(queue.makeCommandBuffer())
            let buffer = try XCTUnwrap(device.makeBuffer(length: 256,options: .storageModeShared))
            let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
            blit.copy(from: cube,sourceSlice: 5,sourceLevel: 0,sourceOrigin: MTLOrigin(x: 512,y: 512,z: 0),sourceSize: MTLSize(width: 1,height: 1,depth: 1),
                to: buffer,destinationOffset: 0,destinationBytesPerRow: 256,destinationBytesPerImage: 256)
            blit.endEncoding()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in
                command.addCompletedHandler { _ in continuation.resume() }; command.commit()
            }
            XCTAssertEqual(command.status,.completed)
            let pixel = buffer.contents().assumingMemoryBound(to: UInt8.self)
            if invalid {
                XCTAssertEqual(Int(pixel[0]),250,accuracy: 5); XCTAssertEqual(Int(pixel[1]),230,accuracy: 5); XCTAssertEqual(Int(pixel[2]),204,accuracy: 5)
            } else { XCTAssertGreaterThan(pixel[2],240); XCTAssertLessThan(pixel[1],40); XCTAssertLessThan(pixel[0],40) }
        }
    }

}
