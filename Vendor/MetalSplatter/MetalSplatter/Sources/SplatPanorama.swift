import Foundation
import Metal
import simd

/// Six cached views of distant geometry, sampled as an inside-facing sky sphere.
/// Capture runs off the compositor thread; draw only samples the completed cube.
public final class SplatPanorama: @unchecked Sendable {
    public enum Error: LocalizedError {
        case allocation, gpu(String)
        public var errorDescription: String? {
            switch self {
            case .allocation: "Could not allocate the distant-scene panorama."
            case .gpu(let message): "Could not capture distant scenery: \(message)"
            }
        }
    }
    public static let faceSize = 1024
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let renderer: SplatRenderer
    private let clearColor: MTLClearColor
    private let colorFormat: MTLPixelFormat

    public init(device: MTLDevice, renderer: SplatRenderer, colorFormat: MTLPixelFormat,
                depthFormat: MTLPixelFormat, clearColor: MTLClearColor) throws {
        self.device = device; self.renderer = renderer
        self.clearColor = clearColor; self.colorFormat = colorFormat
        guard let queue = device.makeCommandQueue() else { throw Error.allocation }
        self.queue = queue
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "panoramaVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "panoramaFragment")
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        descriptor.depthAttachmentPixelFormat = depthFormat
        descriptor.maxVertexAmplificationCount = 2
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .always
        depth.isDepthWriteEnabled = false
        guard let state = device.makeDepthStencilState(descriptor: depth) else { throw Error.allocation }
        depthState = state
    }

    /// World-space camera axes matching Metal's six cube faces (+X,-X,+Y,-Y,+Z,-Z).
    public static func camera(face: Int, at position: SIMD3<Float>) -> simd_float4x4 {
        let forward: [SIMD3<Float>] = [SIMD3(1,0,0), SIMD3(-1,0,0), SIMD3(0,1,0), SIMD3(0,-1,0), SIMD3(0,0,1), SIMD3(0,0,-1)]
        let up: SIMD3<Float> = face == 2 ? SIMD3(0,0,-1) : face == 3 ? SIMD3(0,0,1) : SIMD3(0,1,0)
        let f = forward[face]
        // Cube texture coordinates are left-handed. Reflect the camera's X basis
        // so +X faces run from +Z at the left edge to -Z at the right edge.
        // Keeping projection focal lengths positive preserves covariance clamping.
        return simd_float4x4(SIMD4(simd_cross(up, f), 0), SIMD4(up, 0), SIMD4(-f, 0), SIMD4(position, 1))
    }

    public func capture(at worldPosition: SIMD3<Float>, worldFromSource: simd_float4x4) async throws -> MTLTexture {
        try Task.checkCancellation()
        let source = worldFromSource.inverse * SIMD4(worldPosition, 1)
        try await renderer.prepareSort(at: SIMD3(source.x, source.y, source.z))
        let descriptor = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: colorFormat, size: Self.faceSize, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead, .pixelFormatView]
        guard let cube = device.makeTexture(descriptor: descriptor) else { throw Error.allocation }
        cube.label = "Splativerse static distant scenery"
        let projection = simd_float4x4(SIMD4(1,0,0,0), SIMD4(0,1,0,0), SIMD4(0,0,0,-1), SIMD4(0,0,0.05,0))
        for face in 0..<6 {
            try Task.checkCancellation()
            guard let target = cube.makeTextureView(pixelFormat: colorFormat, textureType: .type2D,
                                                   levels: 0..<1, slices: face..<(face + 1)),
                  let command = queue.makeCommandBuffer() else { throw Error.allocation }
            let view = SplatRenderer.ViewportDescriptor(
                viewport: MTLViewport(originX: 0, originY: 0, width: Double(Self.faceSize), height: Double(Self.faceSize), znear: 0, zfar: 1),
                projectionMatrix: projection, viewMatrix: Self.camera(face: face, at: worldPosition).inverse * worldFromSource,
                screenSize: SIMD2(Self.faceSize, Self.faceSize))
            let rendered = try renderer.render(viewports: [view], colorTexture: target, colorStoreAction: .store,
                                               depthTexture: nil, rasterizationRateMap: nil, renderTargetArrayLength: 1,
                                               accessTimeout: 0.1, sortTimeout: 0.1, sortingPosition: SIMD3(source.x, source.y, source.z), to: command)
            let missedGeometry = !rendered && renderer.renderedSplatCount > 0
            if !rendered {
                // A scan with no distant points still has a valid light-blue background.
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = clearColor
                guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw Error.allocation }
                encoder.endEncoding()
            }
            // Submit one face at a time to avoid a six-face GPU burst while walking.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Swift.Error>) in
                command.addCompletedHandler { buffer in
                    if buffer.status == .error {
                        continuation.resume(throwing: Error.gpu(buffer.error?.localizedDescription ?? "GPU command failed"))
                    } else { continuation.resume() }
                }
                command.commit()
            }
            if missedGeometry { throw Error.gpu("The capture renderer was temporarily unavailable. Try entering the space again.") }
            await Task.yield()
        }
        return cube
    }

    public func draw(cube: MTLTexture, worldFromClip: [simd_float4x4], viewports: [MTLViewport],
                     color: MTLTexture, depth: MTLTexture, rateMap: MTLRasterizationRateMap?, arrayLength: Int,
                     to command: MTLCommandBuffer) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 0
        pass.rasterizationRateMap = rateMap
        pass.renderTargetArrayLength = arrayLength
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw Error.allocation }
        encoder.label = "Splativerse cached sky sphere"
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setViewports(viewports)
        if viewports.count > 1 {
            var mappings = viewports.indices.map { MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0), renderTargetArrayIndexOffset: UInt32($0)) }
            encoder.setVertexAmplificationCount(viewports.count, viewMappings: &mappings)
        }
        var transforms = worldFromClip
        if transforms.count == 1 { transforms.append(transforms[0]) }
        transforms.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.setFragmentTexture(cube, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    // A full-screen triangle samples the same directions as the inside of a sphere;
    // it avoids tessellation and has no binocular translation/parallax at infinity.
    public static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct PanoramaOut { float4 position [[position]]; float3 direction; };
    vertex PanoramaOut panoramaVertex(uint vertexID [[vertex_id]], ushort eye [[amplification_id]],
                                       constant float4x4 *worldFromClip [[buffer(0)]]) {
        float2 p = float2(vertexID == 2 ? 3.0 : -1.0, vertexID == 0 ? -3.0 : 1.0);
        PanoramaOut out;
        out.position = float4(p, 0, 1);
        out.direction = (worldFromClip[min(uint(eye), 1u)] * float4(p, 1, 1)).xyz;
        return out;
    }
    fragment half4 panoramaFragment(PanoramaOut in [[stage_in]], texturecube<half> cube [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return half4(cube.sample(s, normalize(in.direction)).rgb, 1);
    }
    """
}
