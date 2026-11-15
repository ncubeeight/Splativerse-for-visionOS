import CoreText
import Metal
import SplativerseCore
import simd

/// A small stereo mesh in physical tracking space. It never inherits the scan's
/// scale or virtual navigation transform. Buffers/textures are allocated once.
final class FlightJoystickRenderer {
    private struct Vertex { var position: SIMD4<Float>; var normal: SIMD4<Float> }
    private struct Instance { var model: simd_float4x4; var color: SIMD4<Float> }
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let maskPipeline: MTLRenderPipelineState
    private let maskDepthState: MTLDepthStencilState
    private let mesh: MTLBuffer
    private let quad: MTLBuffer
    private enum Shape: Int, CaseIterable { case box, cylinder }
    private let ranges: [Range<Int>]
    private let labels: [MTLTexture]
    enum Failure: LocalizedError {
        case allocation
        var errorDescription: String? { "Not enough graphics memory to create or draw the flight panel." }
    }

    init(device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) throws {
        let library = try device.makeLibrary(source: Self.source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "flightVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "flightFragment")
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        // Core Graphics labels use premultiplied alpha. Clear texels reveal metal.
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.depthAttachmentPixelFormat = depthFormat
        descriptor.maxVertexAmplificationCount = 2
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = library.makeFunction(name: "flightMaskFragment")
        descriptor.colorAttachments[0].writeMask = []
        maskPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .greaterEqual; depth.isDepthWriteEnabled = true
        guard let state = device.makeDepthStencilState(descriptor: depth) else { throw Failure.allocation }
        depthState = state
        depth.depthCompareFunction = .always
        guard let maskState = device.makeDepthStencilState(descriptor: depth) else { throw Failure.allocation }
        maskDepthState = maskState
        var vertices: [Vertex] = []
        func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, normals: [SIMD3<Float>]? = nil) {
            let normal = simd_normalize(simd_cross(b-a,c-a))
            for (i,p) in [a,b,c].enumerated() { vertices.append(Vertex(position: SIMD4(p,1),normal: SIMD4(normals?[i] ?? normal,0))) }
        }
        // Closed chamfered slab: top/bottom faces, bevels, and solid side walls.
        func ring(_ extent: Float, _ y: Float) -> [SIMD3<Float>] {
            let c: Float = 0.12
            return [SIMD3(-extent+c,y,-extent),SIMD3(extent-c,y,-extent),SIMD3(extent,y,-extent+c),SIMD3(extent,y,extent-c),
                    SIMD3(extent-c,y,extent),SIMD3(-extent+c,y,extent),SIMD3(-extent,y,extent-c),SIMD3(-extent,y,-extent+c)]
        }
        let rings = [ring(0.92,1),ring(1,0.84),ring(1,-0.84),ring(0.92,-1)]
        for i in 0..<8 {
            let j = (i+1)%8
            triangle(SIMD3(0,1,0),rings[0][j],rings[0][i])
            triangle(SIMD3(0,-1,0),rings[3][i],rings[3][j])
            for k in 0..<3 {
                triangle(rings[k][i],rings[k][j],rings[k+1][i])
                triangle(rings[k][j],rings[k+1][j],rings[k+1][i])
            }
        }
        let boxEnd = vertices.count
        for i in 0..<32 {
            let a = Float(i) * .pi / 16, b = Float(i+1) * .pi / 16
            let n1 = SIMD3<Float>(cos(a),0,sin(a)), n2 = SIMD3<Float>(cos(b),0,sin(b))
            let bottom1 = n1 - SIMD3(0,1,0), top1 = n1 + SIMD3(0,1,0)
            let bottom2 = n2 - SIMD3(0,1,0), top2 = n2 + SIMD3(0,1,0)
            triangle(bottom1,top1,bottom2,normals: [n1,n1,n2]); triangle(bottom2,top1,top2,normals: [n2,n1,n2])
            triangle(SIMD3(0,1,0),top2,top1); triangle(SIMD3(0,-1,0),bottom1,bottom2)
        }
        ranges = [0..<boxEnd,boxEnd..<vertices.count]
        guard let buffer = device.makeBuffer(bytes: vertices,length: vertices.count * MemoryLayout<Vertex>.stride) else { throw Failure.allocation }
        mesh = buffer
        let corners: [SIMD4<Float>] = [SIMD4(-1,-1,0,1),SIMD4(1,-1,0,1),SIMD4(-1,1,0,1),SIMD4(-1,1,0,1),SIMD4(1,-1,0,1),SIMD4(1,1,0,1)]
        let quads = corners.map { Vertex(position: $0, normal: SIMD4(0,0,1,0)) }
        guard let buffer = device.makeBuffer(bytes: quads, length: quads.count * MemoryLayout<Vertex>.stride) else { throw Failure.allocation }
        quad = buffer
        labels = try ["FLY / TURN\nFORWARD FOLLOWS YOUR VIEW\nPINCH STICK TO FLY", "FLY / TURN\nFORWARD FOLLOWS YOUR VIEW\nRELEASE TO STOP",
                      "MOVE PANEL\nPINCH THE HORIZONTAL HANDLE\nRELEASE TO PLACE", "PLACING PANEL\nFLIGHT IS PAUSED\nRELEASE TO FIX IN PLACE", "MENU", "EXIT", "PREVIOUS", "NEXT", "LOADING SCAN\nPLEASE WAIT\nMENU AND EXIT ARE AVAILABLE", "SCAN UNAVAILABLE\nPREVIOUS / NEXT OR EXIT\nMENU SHOWS THE ERROR"].map { try Self.label($0,device: device) }
    }
    private static func label(_ text: String, device: MTLDevice) throws -> MTLTexture {
        let width = 640, height = 180
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let made = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.clear(CGRect(x: 0,y: 0,width: width,height: height))
            let button = ["MENU","EXIT","PREVIOUS","NEXT"].contains(text)
            if button { context.setFillColor(CGColor(red: 0.9,green: 0.65,blue: 0.2,alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: width,height: height)) }
            for (index,lineText) in text.split(separator: "\n").enumerated() {
                let attributes: [CFString: Any] = [kCTFontAttributeName: CTFontCreateWithName("Helvetica-Bold" as CFString,button ? (text == "PREVIOUS" ? 68 : 100) : (index == 0 ? 35 : 24),nil),
                    kCTForegroundColorAttributeName: CGColor(gray: 0.025,alpha: 1)]
                let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil,String(lineText) as CFString,attributes as CFDictionary))
                let bounds = CTLineGetBoundsWithOptions(line,[])
                context.textPosition = CGPoint(x: (Double(width)-bounds.width)/2-bounds.minX,y: button ? 53 : 127-Double(index)*47)
                CTLineDraw(line,context)
            }
            return true
        }
        guard made else { throw Failure.allocation }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.allocation }
        pixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        return texture
    }
    func draw(flight: FlightController, scanFailed: Bool = false, pressedButtons: Set<FlightPanelAction> = [], eyePositions: [SIMD4<Float>], clipFromTracking: [simd_float4x4], viewports: [MTLViewport],
              color: MTLTexture, depth: MTLTexture, rateMap: MTLRasterizationRateMap?, arrayLength: Int, command: MTLCommandBuffer) throws {
        var groups = [[Instance](),[Instance]()]
        let frame = flight.panelTransform
        let steel = SIMD4<Float>(0.62,0.68,0.74,0.32)
        let dark = SIMD4<Float>(0.16,0.19,0.23,0.42)
        let brass = SIMD4<Float>(0.8,0.56,0.26,0.25)
        func add(_ shape: Shape, at p: SIMD3<Float>, size: SIMD3<Float>, material: SIMD4<Float>, rotation: simd_float4x4 = matrix_identity_float4x4) {
            var scale = matrix_identity_float4x4; scale.columns.0.x = size.x; scale.columns.1.y = size.y; scale.columns.2.z = size.z
            groups[shape.rawValue].append(Instance(model: frame * translation(p) * rotation * scale,color: material))
        }
        add(.box,at: SIMD3(0,-0.019,0.018),size: SIMD3(0.17,0.019,0.12),material: steel)
        add(.box,at: SIMD3(0,0.001,0.018),size: SIMD3(0.159,0.003,0.109),material: steel)
        for x: Float in [-0.145,0.145] { for z: Float in [-0.075,0.105] {
            add(.cylinder,at: SIMD3(x,0.007,z),size: SIMD3(0.006,0.003,0.006),material: steel)
            add(.box,at: SIMD3(x,0.0105,z),size: SIMD3(0.004,0.0005,0.001),material: dark)
        } }
        let stick = flight.stick
        let indicator = stick.isHeld ? SIMD4<Float>(0.08,0.85,0.42,2) : SIMD4<Float>(0.08,0.5,1,2)
        let direction = FlightController.leverDirection(stick.deflection)
        let rotation = simd_float4x4(simd_quatf(from: SIMD3<Float>(0,1,0),to: direction))
        add(.cylinder,at: SIMD3(0,0.009,0),size: SIMD3(0.045,0.009,0.045),material: steel)
        add(.cylinder,at: SIMD3(0,0.019,0),size: SIMD3(0.04,0.002,0.04),material: indicator)
        add(.cylinder,at: direction*0.025,size: SIMD3(0.032,0.012,0.032),material: dark,rotation: rotation)
        add(.cylinder,at: direction*0.062,size: SIMD3(0.009,0.047,0.009),material: steel,rotation: rotation)
        add(.cylinder,at: direction*0.11,size: SIMD3(0.019,0.032,0.019),material: steel,rotation: rotation)
        for distance: Float in [0.085,0.098,0.111,0.124,0.137] {
            add(.cylinder,at: direction*distance,size: SIMD3(0.020,0.0015,0.020),material: dark,rotation: rotation)
        }
        // A separate horizontal carry rail is the only direct panel-placement target.
        let rail = FlightController.moveHandleCenter
        for x: Float in [-0.05,0.05] {
            add(.cylinder,at: SIMD3(x,rail.y/2,rail.z),size: SIMD3(0.008,rail.y/2,0.008),material: steel)
        }
        let railRotation = simd_float4x4(simd_quatf(angle: .pi/2,axis: SIMD3<Float>(0,0,1)))
        add(.cylinder,at: rail,size: SIMD3(0.013,0.06,0.013),material: brass,rotation: railRotation)
        let railLight = flight.isMovingPanel ? SIMD4<Float>(0.08,0.85,0.42,2) : SIMD4<Float>(1,0.53,0.1,2)
        for x: Float in [-0.055,0.055] {
            add(.cylinder,at: rail + SIMD3(x,0,0),size: SIMD3(0.014,0.002,0.014),material: railLight,rotation: railRotation)
        }
        for action in [FlightPanelAction.menu,.exit,.previous,.next] {
            let center = FlightController.buttonCenter(action)
            let active = action == .previous ? flight.previousEnabled : action == .next ? flight.nextEnabled : true
            let gold = pressedButtons.contains(action) ? SIMD4<Float>(1,0.88,0.4,2) : SIMD4<Float>(0.95,0.65,0.17,0.2)
            add(.box,at: center-SIMD3(0,0.005,0),size: SIMD3(0.035,0.005,0.022),material: active ? gold : dark)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color; pass.colorAttachments[0].loadAction = .load; pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .load; pass.depthAttachment.storeAction = .store
        pass.rasterizationRateMap = rateMap; pass.renderTargetArrayLength = arrayLength
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.allocation }
        encoder.label = "Splativerse adjustable flight panel"
        encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depthState); encoder.setCullMode(.none)
        encoder.setViewports(viewports)
        if viewports.count > 1 {
            var mappings = viewports.indices.map { MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0), renderTargetArrayIndexOffset: UInt32($0)) }
            encoder.setVertexAmplificationCount(viewports.count, viewMappings: &mappings)
        }
        var transforms = clipFromTracking
        if transforms.count == 1 { transforms.append(transforms[0]) }
        transforms.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
        // Physical eye position drives view-dependent metallic reflections.
        var eyes = eyePositions
        if eyes.count == 1 { eyes.append(eyes[0]) }
        eyes.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!,length: $0.count,index: 3) }
        var labelInstances: [Instance] = []
        for z: Float in [-0.069,0.078] {
            var scale = matrix_identity_float4x4; scale.columns.0.x = 0.071; scale.columns.1.y = 0.021
            let facingUp = simd_float4x4(simd_quatf(angle: -.pi/2,axis: SIMD3<Float>(1,0,0)))
            labelInstances.append(Instance(model: frame * translation(SIMD3(0,0.0042,z)) * facingUp * scale,color: SIMD4(1,1,1,-1)))
        }
        for action in [FlightPanelAction.menu,.exit,.previous,.next] {
            var scale = matrix_identity_float4x4; scale.columns.0.x = 0.031; scale.columns.1.y = 0.014
            let facingUp = simd_float4x4(simd_quatf(angle: -.pi/2,axis: SIMD3<Float>(1,0,0)))
            let active = action == .previous ? flight.previousEnabled : action == .next ? flight.nextEnabled : true
            labelInstances.append(Instance(model: frame * translation(FlightController.buttonCenter(action)+SIMD3(0,0.0002,0)) * facingUp * scale,color: active ? SIMD4(1,1,1,-1) : SIMD4(0.28,0.28,0.28,-1)))
        }
        func drawShapes(textured: Bool) {
            encoder.setVertexBuffer(mesh,offset: 0,index: 0)
            for shape in Shape.allCases {
                groups[shape.rawValue].withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!,length: $0.count,index: 2) }
                let range = ranges[shape.rawValue]
                encoder.drawPrimitives(type: .triangle,vertexStart: range.lowerBound,vertexCount: range.count,instanceCount: groups[shape.rawValue].count)
            }
            encoder.setVertexBuffer(quad,offset: 0,index: 0)
            for i in 0..<6 {
                var label = labelInstances[i]
                encoder.setVertexBytes(&label,length: MemoryLayout<Instance>.stride,index: 2)
                if textured {
                    let labelIndex = i >= 2 ? i+2 : (i == 0 ? (!flight.canFly ? (scanFailed ? 9 : 8) : (flight.isHeld ? 1 : 0)) : (flight.isMovingPanel ? 3 : 2))
                    encoder.setFragmentTexture(labels[labelIndex],index: 0)
                }
                encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 6)
            }
        }
        // Preserve true panel depth and scene depth outside the exact silhouette.
        encoder.setRenderPipelineState(maskPipeline); encoder.setDepthStencilState(maskDepthState)
        drawShapes(textured: false)
        encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depthState)
        encoder.setFragmentTexture(labels[0],index: 0)
        drawShapes(textured: true)
        encoder.endEncoding()
    }
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct FlightVertex { float4 position; float4 normal; };
    struct FlightInstance { float4x4 model; float4 color; };
    struct FlightOut { float4 position [[position]]; float3 normal; float4 color; float2 uv; float3 viewDirection; };
    vertex FlightOut flightVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]], ushort eye [[amplification_id]],
        constant FlightVertex *vertices [[buffer(0)]], constant float4x4 *clip [[buffer(1)]], constant FlightInstance *instances [[buffer(2)]], constant float4 *eyes [[buffer(3)]]) {
        FlightVertex v = vertices[vertexID]; FlightInstance item = instances[instanceID]; FlightOut out;
        float4 physical = item.model * v.position;
        out.position = clip[min(uint(eye),1u)] * physical;
        out.viewDirection = eyes[min(uint(eye),1u)].xyz - physical.xyz;
        float3x3 basis = float3x3(item.model[0].xyz, item.model[1].xyz, item.model[2].xyz);
        float3 corrected = v.normal.xyz / float3(dot(basis[0],basis[0]),dot(basis[1],basis[1]),dot(basis[2],basis[2]));
        out.normal = normalize(basis * corrected); out.color = item.color;
        // Core Graphics bitmap rows start at the top; the label quad is Y-up.
        out.uv = float2(v.position.x * 0.5 + 0.5, 0.5 - v.position.y * 0.5);
        return out;
    }
    struct FlightDepth { float depth [[depth(any)]]; };
    fragment FlightDepth flightMaskFragment() { FlightDepth out; out.depth = 0; return out; }
    fragment half4 flightFragment(FlightOut in [[stage_in]], texture2d<half> label [[texture(0)]]) {
        if (in.color.a < 0) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            // texture2d<half> and this fragment return half4: keep tint arithmetic
            // in half precision rather than implicitly narrowing a float4 result.
            half4 ink = label.sample(s,in.uv);
            if (ink.a <= half(0.001)) discard_fragment();
            return ink * half4(half3(in.color.rgb),half(1));
        }
        if (in.color.a > 1.0) return half4(half3(in.color.rgb),1);
        float3 n = normalize(in.normal), v = normalize(in.viewDirection);
        float3 r = reflect(-v,n);
        // A soft sky and studio light strips give opaque metal an inexpensive,
        // view-dependent environment reflection without another scene capture.
        float roughness = in.color.a;
        float3 environment = mix(float3(0.07,0.09,0.13),float3(0.68,0.82,0.95),smoothstep(-0.3,0.7,r.y));
        environment += float3(0.9,0.94,1.0) * pow(max(0.0,dot(r,normalize(float3(-0.4,0.8,0.5)))),mix(90.0,18.0,roughness));
        environment += float3(0.6,0.72,0.9) * pow(max(0.0,dot(r,normalize(float3(0.8,0.4,-0.2)))),30.0);
        float3 fresnel = in.color.rgb + (1.0-in.color.rgb) * pow(1.0-max(0.0,dot(n,v)),5.0);
        float3 metal = environment * fresnel * (0.85-roughness*0.25) + in.color.rgb * 0.12;
        return half4(half3(metal),1);
    }
    """
}
