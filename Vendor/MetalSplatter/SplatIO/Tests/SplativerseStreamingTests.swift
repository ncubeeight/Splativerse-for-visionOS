import XCTest
import SplatIO
import simd

final class SplativerseStreamingTests: XCTestCase {
    private func points(_ count: Int) -> [SplatPoint] {
        (0..<count).map { i in
            SplatPoint(position: SIMD3(Float(i) / 1000, -1, 0),
                color: .sRGBUInt8(SIMD3(100, 160, 200)), opacity: .linearFloat(0.9),
                scale: .linearFloat(SIMD3(repeating: 0.05)), rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)))
        }
    }
    func testSlowConsumerLosesNoPLYPoints() async throws {
        let input = points(12_345)
        let writer = try SplatPLYSceneWriter(to: .memory)
        try await writer.start(sphericalHarmonicDegree: 0, pointCount: input.count)
        try await writer.write(input); try await writer.close()
        let data = await writer.writtenData!
        let reader = try SplatPLYSceneReader(data)
        var count = 0
        for try await batch in try await reader.read() {
            count += batch.count
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(count, input.count)
    }
    func testSlowConsumerLosesNoSPZPoints() async throws {
        let input = points(35_010)
        let writer = try SPZSceneWriter(to: .memory)
        try await writer.start(numPoints: input.count)
        try await writer.write(input); try await writer.close()
        let data = await writer.writtenData!
        let reader = try SPZSceneReader(data)
        var count = 0
        for try await batch in try await reader.read() {
            count += batch.count
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(count, input.count)
    }
    func testTruncatedPLYPropagatesError() async throws {
        let input = points(100)
        for binary in [true, false] {
            let writer = try SplatPLYSceneWriter(to: .memory)
            try await writer.start(sphericalHarmonicDegree: 0, binary: binary, pointCount: input.count)
            try await writer.write(input); try await writer.close()
            let full = await writer.writtenData!
            let data = Data(full.dropLast(200))
            do {
                let reader = try SplatPLYSceneReader(data)
                _ = try await reader.readAll()
                XCTFail("Truncated \(binary ? "binary" : "ASCII") PLY should fail")
            } catch { /* expected */ }
        }
    }
    func testUnsupportedXPropertyReportsActualAndExpectedTypes() async throws {
        let fixture = """
        ply
        format ascii 1.0
        element vertex 1
        property double x
        property float y
        property float z
        property float f_dc_0
        property float f_dc_1
        property float f_dc_2
        property float scale_0
        property float scale_1
        property float scale_2
        property float opacity
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        0 0 0 0 0 0 -3 -3 -3 2 1 0 0 0
        """ + "\n"
        do {
            _ = try await SplatPLYSceneReader(Data(fixture.utf8)).readAll()
            XCTFail("Unsupported coordinate storage must be reported, not misread")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("\"x\""),message)
            XCTAssertTrue(message.contains("double"),message)
            XCTAssertTrue(message.contains("expects float"),message)
        }
        // A bad scan must not poison the next reader in a browsing session.
        let supported = fixture.replacingOccurrences(of: "property double x",with: "property float x")
        let points = try await SplatPLYSceneReader(Data(supported.utf8)).readAll()
        XCTAssertEqual(points.count,1)
        XCTAssertEqual(points[0].position,.zero)
    }

}
