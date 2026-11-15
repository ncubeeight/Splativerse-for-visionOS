// Compositor frame lifecycle adapted from MetalSplatter's MIT-licensed SampleApp.
// See THIRD_PARTY_NOTICES.md and Vendor/MetalSplatter/LICENSE.
import ARKit
import CompositorServices
import Metal
import MetalSplatter
import SplatIO
import SplativerseCore
import SwiftUI
import os
import simd

struct ScanLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        configuration.colorFormat = .bgra8Unorm_srgb
        configuration.depthFormat = .depth32Float
        configuration.isFoveationEnabled = capabilities.supportsFoveation
        let options: LayerRenderer.Capabilities.SupportedLayoutsOptions = capabilities.supportsFoveation ? [.foveationEnabled] : []
        configuration.layout = capabilities.supportedLayouts(options: options).contains(.layered) ? .layered : .dedicated
    }
}

private struct BubbleRenderSet: @unchecked Sendable {
    let renderer: SplatRenderer
    let distantRenderer: SplatRenderer
    let panorama: SplatPanorama
    // Immutable image, published only after every capture command completes.
    let texture: MTLTexture
    let configuration: BubbleConfiguration
    func stop() { renderer.stopSorting(); distantRenderer.stopSorting() }
}

private struct BubbleRenderFactory: @unchecked Sendable {
    let device: MTLDevice
    let colorFormat: MTLPixelFormat
    let depthFormat: MTLPixelFormat
    let viewCount: Int
    let units: Float
    let blue: MTLClearColor
    func renderers(for configuration: BubbleConfiguration) throws -> (near: SplatRenderer, distant: SplatRenderer) {
        let near = try SplatRenderer(device: device, colorFormat: colorFormat, depthFormat: depthFormat,
            sampleCount: 1, maxViewCount: viewCount, maxSimultaneousRenders: 6,
            highQualityDepth: true, clearColor: blue,
            distanceRange: .init(maximum: configuration.radius / units), fadeStart: configuration.fadeStart / units,
            cameraMovementThreshold: 0.05 / units, deferSortingUntilPrepared: true)
        let distant = try SplatRenderer(device: device, colorFormat: colorFormat, depthFormat: .invalid,
            sampleCount: 1, maxViewCount: 1, maxSimultaneousRenders: 1, highQualityDepth: false, clearColor: blue,
            distanceRange: .init(minimum: configuration.fadeStart / units), cameraMovementThreshold: 0.05 / units,
            deferSortingUntilPrepared: true, sortPriority: .utility)
        return (near, distant)
    }
    func makeSet(configuration: BubbleConfiguration, chunks: [SplatChunk], worldFromSource: simd_float4x4,
                 position: SIMD3<Float>, existing: (near: SplatRenderer, distant: SplatRenderer)? = nil) async throws -> BubbleRenderSet {
        try Task.checkCancellation()
        if existing == nil {
            let indexHeadroom = UInt64(chunks.reduce(0) { $0 + $1.splatCount }) * 24
            guard UInt64(device.currentAllocatedSize) + indexHeadroom < UInt64(Double(device.recommendedMaxWorkingSetSize) * 0.85) else {
                throw SceneError.radiusMemoryBudget
            }
        }
        let pair = try existing ?? renderers(for: configuration)
        var completed = false
        defer { if !completed { pair.near.stopSorting(); pair.distant.stopSorting() } }
        do {
        if existing == nil {
            for chunk in chunks {
                try Task.checkCancellation()
                // Buffers were already locality-sorted during loading. Never mutate them here.
                await pair.near.addChunk(chunk, sortByLocality: false)
                await pair.distant.addChunk(chunk, sortByLocality: false)
            }
        }
        let panorama = try SplatPanorama(device: device, renderer: pair.distant, colorFormat: colorFormat, depthFormat: depthFormat, clearColor: blue)
        let texture = try await panorama.capture(at: position, worldFromSource: worldFromSource)
        let source = worldFromSource.inverse * SIMD4(position, 1)
        try await pair.near.prepareSort(at: SIMD3(source.x, source.y, source.z))
        try Task.checkCancellation()
        completed = true
        return BubbleRenderSet(renderer: pair.near, distantRenderer: pair.distant, panorama: panorama, texture: texture, configuration: configuration)
        } catch {
            pair.near.stopSorting(); pair.distant.stopSorting()
            await pair.near.stopSortingAndWait(); await pair.distant.stopSortingAndWait()
            throw error
        }
    }
}

private final class LoadedScan: @unchecked Sendable {
    let worldFromSource: simd_float4x4
    let spawnYaw: Float
    private let chunks: [SplatChunk]
    private let factory: BubbleRenderFactory
    private struct Cache: Sendable {
        var current: BubbleRenderSet
        var requestedRadius: Float
        var position = SIMD3<Float>(0, 1.65, 0)
        var task: Task<Void, Never>?
        var forcePending = false
        var stopped = false
        var error: String?
    }
    private let cache: OSAllocatedUnfairLock<Cache>
    init(current: BubbleRenderSet, chunks: [SplatChunk], factory: BubbleRenderFactory, worldFromSource: simd_float4x4, spawnYaw: Float) {
        self.chunks = chunks; self.factory = factory; self.worldFromSource = worldFromSource; self.spawnYaw = spawnYaw
        cache = OSAllocatedUnfairLock(initialState: Cache(current: current, requestedRadius: current.configuration.radius))
    }
    func snapshot() -> (current: BubbleRenderSet, refreshing: Bool, requestedRadius: Float, error: String?) {
        cache.withLock { ($0.current, $0.task != nil, $0.requestedRadius, $0.error) }
    }
    func updatePanorama(at position: SIMD3<Float>, radius: Float? = nil, force: Bool = false) {
        cache.withLock { state in
            if let radius {
                let value = BubbleConfiguration(radius: radius).radius
                if value != state.requestedRadius { state.task?.cancel() }
                state.requestedRadius = value
                state.error = nil
            }
            if force { state.forcePending = true; state.error = nil }
            let previous = state.current
            let configuration = BubbleConfiguration(radius: state.requestedRadius)
            let radiusChanged = configuration != previous.configuration
            guard !state.stopped, state.task == nil, state.error == nil,
                  radiusChanged || state.forcePending || simd_distance_squared(position, state.position) >= configuration.refreshDistance * configuration.refreshDistance else { return }
            state.position = position
            state.forcePending = false
            state.task = Task.detached(priority: .utility) { [self] in
                do {
                    let replacement: BubbleRenderSet
                    if radiusChanged {
                        replacement = try await factory.makeSet(configuration: configuration, chunks: chunks, worldFromSource: worldFromSource, position: position)
                    } else {
                        let texture = try await previous.panorama.capture(at: position, worldFromSource: worldFromSource)
                        replacement = BubbleRenderSet(renderer: previous.renderer, distantRenderer: previous.distantRenderer,
                            panorama: previous.panorama, texture: texture, configuration: configuration)
                    }
                    let accepted = cache.withLock { state in
                        guard !state.stopped, state.requestedRadius == configuration.radius, !Task.isCancelled else { return false }
                        state.current = replacement
                        return true
                    }
                    if radiusChanged {
                        let retired = accepted ? previous : replacement
                        retired.stop()
                        await retired.renderer.stopSortingAndWait()
                        await retired.distantRenderer.stopSortingAndWait()
                    }
                    cache.withLock { $0.task = nil }
                } catch {
                    cache.withLock {
                        $0.task = nil
                        if !(error is CancellationError) { $0.error = error.localizedDescription }
                    }
                }
            }
        }
    }
    func shutdown() async {
        let snapshot = cache.withLock { state in
            state.stopped = true; state.task?.cancel()
            return (state.current,state.task)
        }
        snapshot.0.stop()
        await snapshot.1?.value
        await snapshot.0.renderer.stopSortingAndWait()
        await snapshot.0.distantRenderer.stopSortingAndWait()
    }
    func stop() {
        let current = cache.withLock { state in
            state.stopped = true; state.task?.cancel()
            return state.current
        }
        current.stop()
    }
}

private enum SceneError: LocalizedError {
    case unavailable, empty, invalidPoint, memoryBudget, radiusMemoryBudget, tooManyChunks
    var errorDescription: String? {
        switch self {
        case .unavailable: "World tracking or Metal is not available. Run this immersive view on Apple Vision Pro."
        case .empty: "The scan contains no Gaussian splats."
        case .invalidPoint: "The scan contains invalid positions, rotations, scales, or color values. Export a valid Gaussian-splat PLY or SPZ."
        case .memoryBudget: "This scan exceeds the available GPU memory budget. Export a smaller or spatially cropped scan and import it again."
        case .radiusMemoryBudget: "There is not enough memory to change the radius while viewing. Leave the space, choose the radius, and enter again."
        case .tooManyChunks: "This scan exceeds the renderer’s supported chunk count."
        }
    }
}

/// Layer access and navigation pose are confined to one render thread. The fully built
/// asset is published atomically; the loader never mutates it after publication.
final class VisionScanRenderer: @unchecked Sendable {
    private static let sessionGate = RenderSessionGate()
    private static let log = Logger(subsystem: "com.splativerse.vision",category: "ScanLifecycle")
    private let loadTask = OSAllocatedUnfairLock<Task<Void,Never>?>(initialState: nil)
    private let loadingPair = OSAllocatedUnfairLock<(SplatRenderer,SplatRenderer)?>(initialState: nil)
    private let layer: LayerRenderer
    private let request: RenderRequest
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let session = ARKitSession()
    private let tracking = WorldTrackingProvider()
    private let asset = OSAllocatedUnfairLock<LoadedScan?>(initialState: nil)
    private let semaphore = DispatchSemaphore(value: 3)
    private let control = RenderControl.shared
    private var pose = NavigationPose()
    private let handTracker = FlightHandTracker()
    private var joystick: FlightJoystickRenderer?
    private var flight = FlightController()
    private var panelInput = FlightPanelInput()
    private let panelEvents = OSAllocatedUnfairLock(initialState: [FlightPanelEvent]())
    private var flightEnabled = true
    private var flightAvailable = false
    private var lastFlightTime: Double?
    private var hasOrigin = false
    private var sawReadyAsset = false
    // Linear-light equivalent of #CCE6FA; opaque in full immersion.
    private static let blue = MTLClearColor(red: 0.603827, green: 0.791298, blue: 0.955973, alpha: 1)

    private init(_ layer: LayerRenderer, request: RenderRequest) throws {
        self.layer = layer; self.request = request; device = layer.device
        guard let queue = device.makeCommandQueue(), WorldTrackingProvider.isSupported else { throw SceneError.unavailable }
        self.queue = queue
    }

    static func start(_ layer: LayerRenderer, request: RenderRequest) {
        do {
            let renderer = try VisionScanRenderer(layer, request: request)
            Task.detached(priority: .userInitiated) {
                var acquired = false
                do {
                    renderer.control.report(request.id) { $0.message = "Waiting for previous scan resources to finish releasing…" }
                    try await sessionGate.acquire(request.id,shouldStop: { renderer.control.shouldStop(request.id) })
                    acquired = true
                    try await renderer.startTracking()
                    await renderer.installPanelInput()
                    let tracker = renderer.handTracker
                    let handUpdates = Task { await tracker.run() }
                    renderer.beginLoading(request)
                    let thread = Thread {
                        renderer.loop()
                        renderer.loadTask.withLock { $0?.cancel() }; handUpdates.cancel(); renderer.session.stop()
                        renderer.asset.withLock { $0?.stop() }
                        renderer.control.report(request.id) { $0.closed = true }
                        Task.detached {
                            await renderer.finish(handUpdates: handUpdates)
                            await sessionGate.release(request.id)
                        }
                    }
                    thread.name = "Splativerse stereo compositor"
                    thread.qualityOfService = .userInteractive
                    thread.start()
                } catch {
                    renderer.session.stop()
                    if !(error is CancellationError) { renderer.fail(error) }
                    if acquired { await sessionGate.release(request.id) }
                }
            }
        } catch {
            RenderControl.shared.report(request.id) { $0.failure = error.localizedDescription }
        }
    }

    private func beginLoading(_ next: RenderRequest) {
        let retiring = OSAllocatedUnfairLock(initialState: asset.withLock { value in let scan = value; value = nil; return scan })
        retiring.withLock { $0?.stop() }
        control.report(request.id) {
            $0.ready = false; $0.failure = nil; $0.loadFailure = nil; $0.scanSwitchPending = false
            $0.splatCount = 0; $0.visibleSplatCount = 0
            $0.message = "Releasing previous scan, then loading " + next.title + "…"
        }
        loadTask.withLock { state in
            let previous = state; previous?.cancel()
            state = Task.detached(priority: .userInitiated) { [self] in
                await previous?.value
                await releaseRetiredScan(retiring)
                await releaseLoadingPair()
                await drainGPU()
                do {
                    try Task.checkCancellation()
                    if control.shouldStop(request.id) { throw CancellationError() }
                    try await load(next)
                } catch is CancellationError { }
                catch {
                    await releaseLoadingPair()
                    await drainGPU()
                    guard !Task.isCancelled, !control.shouldStop(request.id) else { return }
                    let detail = "Could not load “" + next.fileURL.lastPathComponent + "”: " + error.localizedDescription
                    Self.log.error("Recoverable scan load failure: \(detail,privacy: .public)")
                    control.report(request.id) {
                        $0.ready = false; $0.loadFailure = detail; $0.scanSwitchPending = false
                        $0.splatCount = 0; $0.visibleSplatCount = 0
                        $0.message = "Scan unavailable. Use Previous or Next to continue, or Menu for details."
                    }
                }
            }
        }
    }
    // The task retains only an emptied holder when the next load starts.
    // Capturing the outgoing scan directly would keep its GPU buffers alive.
    private func releaseRetiredScan(_ holder: OSAllocatedUnfairLock<LoadedScan?>) async {
        if let scan = holder.withLock({ value in let scan = value; value = nil; return scan }) {
            await scan.shutdown()
        }
    }
    private func releaseLoadingPair() async {
        if let pair = loadingPair.withLock({ value in let p = value; value = nil; return p }) {
            pair.0.stopSorting(); pair.1.stopSorting()
            await pair.0.stopSortingAndWait(); await pair.1.stopSortingAndWait()
        }
    }
    private func drainGPU() async {
        if let command = queue.makeCommandBuffer() {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in
                command.addCompletedHandler { _ in continuation.resume() }; command.commit()
            }
        }
    }

    private func finish(handUpdates: Task<Void,Never>) async {
        let loader = loadTask.withLock { value in let task = value; value = nil; task?.cancel(); return task }
        await loader?.value
        // This task owns only the tracker, never scan buffers or the renderer.
        handUpdates.cancel()
        await releaseLoadingPair()
        if let loaded = asset.withLock({ value in let p = value; value = nil; return p }) { await loaded.shutdown() }
        await drainGPU()
        joystick = nil
        await MainActor.run { self.layer.onSpatialEvent = { _ in } }
        Self.log.info("Session drained; Metal allocated bytes=\(self.device.currentAllocatedSize,privacy: .public)")
    }

    @MainActor private func installPanelInput() {
        var ids: [SpatialEventCollection.Event.ID: UUID] = [:]
        layer.onSpatialEvent = { [weak self] events in
            guard let self else { return }
            var converted: [FlightPanelEvent] = []
            for event in events {
                let id = ids[event.id] ?? UUID()
                ids[event.id] = id
                let phase: FlightPanelEvent.Phase
                switch event.phase {
                case .active: phase = .active
                case .ended: phase = .ended
                case .cancelled: phase = .cancelled
                @unknown default: phase = .cancelled
                }
                let ray = event.selectionRay
                let origin = ray.map { SIMD3<Float>(Float($0.origin.x),Float($0.origin.y),Float($0.origin.z)) }
                let direction = ray.map { SIMD3<Float>(Float($0.direction.x),Float($0.direction.y),Float($0.direction.z)) }
                let p = event.location3D
                let point = SIMD3<Float>(Float(p.x),Float(p.y),Float(p.z))
                // Direct touches/pinches use their physical point; indirect
                // look-and-pinch uses the system's privacy-preserving selection ray.
                let direct = event.kind == .directPinch || event.kind == .touch
                converted.append(FlightPanelEvent(id: id,phase: phase,origin: direct ? nil : origin,
                    direction: direct ? nil : direction,point: phase == .ended ? nil : point))
                if event.phase != .active { ids.removeValue(forKey: event.id) }
            }
            let batch = converted
            panelEvents.withLock { queue in
                queue.append(contentsOf: batch)
                if queue.count > 128 { queue.removeFirst(queue.count-128) }
            }
        }
    }

    private func startTracking() async throws {
        if HandTrackingProvider.isSupported {
            let authorization = await session.requestAuthorization(for: [.handTracking])
            if authorization[.handTracking] == .allowed {
                var stage = "prepare flight-panel graphics"
                do {
                    joystick = try FlightJoystickRenderer(device: device, colorFormat: layer.configuration.colorFormat, depthFormat: layer.configuration.depthFormat)
                    stage = "start hand tracking"
                    try await session.run([tracking, handTracker.provider])
                    flightAvailable = true
                    control.report(request.id) { $0.flightAvailable = true; $0.flightMessage = "Pinch the stick to fly. Use the horizontal handle to place the panel." }
                    return
                } catch {
                    session.stop(); joystick = nil; flightAvailable = false
                    let detail = "Could not " + stage + ": " + error.localizedDescription
                    Self.log.error("Flight panel startup failed: \(detail,privacy: .public)")
                    control.report(request.id) {
                        $0.flightAvailable = false
                        $0.flightMessage = detail + "\nLeave and re-enter to retry. Navigation buttons remain available."
                    }
                }
            } else {
                control.report(request.id) { $0.flightMessage = "Allow Hand Tracking for Splativerse in Settings, then leave and re-enter to use flight." }
            }
        } else {
            control.report(request.id) { $0.flightMessage = "Hand tracking requires a supported Vision Pro. Navigation buttons remain available." }
        }
        try await session.run([tracking])
    }

    private func fail(_ error: Error) {
        Self.log.error("Scan failure: \(error.localizedDescription,privacy: .public); Metal allocated bytes=\(self.device.currentAllocatedSize,privacy: .public)")
        control.report(request.id) { $0.failure = error.localizedDescription; $0.ready = false }
    }

    private func load(_ request: RenderRequest) async throws {
        try Task.checkCancellation()
        Self.log.info("Beginning scan load; Metal allocated bytes=\(self.device.currentAllocatedSize,privacy: .public)")
        let units = request.settings.metresPerUnit
        let configuration = BubbleConfiguration(radius: request.settings.bubbleRadius)
        let factory = BubbleRenderFactory(device: device, colorFormat: layer.configuration.colorFormat,
            depthFormat: layer.configuration.depthFormat, viewCount: layer.properties.viewCount, units: units, blue: Self.blue)
        let pair = try factory.renderers(for: configuration)
        let renderer = pair.near, distant = pair.distant
        loadingPair.withLock { $0 = (renderer,distant) }
        var sharedChunks: [SplatChunk] = []
        var spawnEstimator = DensitySpawnEstimator()
        var published = false
        defer { if !published { renderer.stopSorting(); distant.stopSorting() } }
        let reader = try AutodetectSceneReader(request.fileURL)
        let orientation = sourceOrientation(request.settings.upAxis)
        var minPoint = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxPoint = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var pending: [SplatPoint] = []
        pending.reserveCapacity(250_000)
        var count = 0, chunks = 0
        // Leave room for decoded input, sort buffers, compositor textures, and the OS.
        let budget = UInt64(Double(device.recommendedMaxWorkingSetSize) * 0.60)
        func cancelled() throws {
            try Task.checkCancellation()
            if control.shouldStop(request.id) { throw CancellationError() }
        }
        func appendChunk(_ points: [SplatPoint]) async throws {
            try cancelled()
            guard chunks < 65_535 else { throw SceneError.tooManyChunks }
            let estimate = UInt64(points.count) * 256
            guard UInt64(device.currentAllocatedSize) + estimate < budget else { throw SceneError.memoryBudget }
            let chunk = try SplatChunk(device: device, from: points)
            // The two renderers share immutable GPU splat buffers. Reorder only once.
            await renderer.addChunk(chunk)
            await distant.addChunk(chunk, sortByLocality: false)
            sharedChunks.append(chunk)
            chunks += 1
        }
        for try await batch in try await reader.read() {
            try cancelled()
            for point in batch {
                let p = point.position, scale = point.scale.asLinearFloat
                let q = point.rotation.vector
                guard p.x.isFinite, p.y.isFinite, p.z.isFinite,
                      scale.x.isFinite, scale.y.isFinite, scale.z.isFinite,
                      scale.x > 0, scale.y > 0, scale.z > 0,
                      q.x.isFinite, q.y.isFinite, q.z.isFinite, q.w.isFinite,
                      simd_length_squared(q) > 0.000001,
                      point.opacity.asLinearFloat.isFinite,
                      point.color.asSphericalHarmonicFloat.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
                else { throw SceneError.invalidPoint }
                let oriented = orientation * SIMD4(p, 1)
                let xyz = SIMD3(oriented.x, oriented.y, oriented.z)
                minPoint = simd_min(minPoint, xyz); maxPoint = simd_max(maxPoint, xyz)
                spawnEstimator.add(xyz * units, opacity: point.opacity.asLinearFloat)
                pending.append(point); count += 1
                if pending.count == 250_000 {
                    try await appendChunk(pending)
                    pending.removeAll(keepingCapacity: true)
                }
            }
            let loadedCount = count
            control.report(request.id) { $0.splatCount = loadedCount; $0.message = "Loading \(loadedCount.formatted()) Gaussian splats…" }
        }
        if !pending.isEmpty { try await appendChunk(pending) }
        guard count > 0 else { throw SceneError.empty }
        try cancelled()
        var scale = matrix_identity_float4x4
        scale.columns.0.x = units; scale.columns.1.y = units; scale.columns.2.z = units
        control.report(request.id) { $0.message = "Estimating a starting view in the densest scan region…" }
        let estimatedSpawn = spawnEstimator.estimate()
        let center = (minPoint + maxPoint) * 0.5
        let fallbackEye = SIMD3(center.x * units, minPoint.y * units + 1.65, center.z * units)
        let eye = estimatedSpawn?.eye ?? fallbackEye
        let aligned = translation(SIMD3(-eye.x, 1.65 - eye.y + request.settings.floorOffset, -eye.z)) * scale * orientation
        control.report(request.id) { $0.message = "Capturing distant scenery for the \(Int(configuration.radius)) m bubble…" }
        let initial = try await factory.makeSet(configuration: configuration, chunks: sharedChunks, worldFromSource: aligned,
            position: SIMD3(0, 1.65, 0), existing: pair)
        let loaded = LoadedScan(current: initial, chunks: sharedChunks, factory: factory, worldFromSource: aligned, spawnYaw: estimatedSpawn?.yaw ?? 0)
        try cancelled()
        published = asset.withLock {
            guard !Task.isCancelled, !control.shouldStop(request.id) else { return false }
            $0 = loaded
            return true
        }
        guard published else { throw CancellationError() }
        loadingPair.withLock { $0 = nil }
        let loadedCount = count
        control.report(request.id) { $0.splatCount = loadedCount; $0.message = "Preparing the first stereo frame…" }
    }

    private func loop() {
        while layer.state != .invalidated && !control.shouldStop(request.id) {
            autoreleasepool {
                if layer.state == .paused { flight.reset(); panelInput.reset(); panelEvents.withLock { $0.removeAll() }; lastFlightTime = nil; layer.waitUntilRunning() }
                else { renderFrame() }
            }
        }
    }

    private func renderFrame() {
        guard let frame = layer.queryNextFrame() else { return }
        frame.startUpdate(); frame.endUpdate()
        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty else { return }
        semaphore.wait()
        frame.startSubmission()
        defer { frame.endSubmission() }
        let duration = LayerRenderer.Clock.Instant.epoch.duration(to: drawables[0].frameTiming.presentationTime)
        let time = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let anchor = tracking.queryDeviceAnchor(atTimestamp: time)
        var loaded = asset.withLock { $0 }
        if anchor == nil {
            flight.reset(); panelInput.reset(); panelEvents.withLock { $0.removeAll() }; lastFlightTime = nil
            control.report(request.id) { $0.ready = false; $0.message = "Waiting for headset tracking…" }
        }
        if let anchor {
            if !hasOrigin || (loaded != nil && !sawReadyAsset) {
                pose.begin(at: anchor.originFromAnchorTransform, facing: loaded?.spawnYaw); hasOrigin = true
                flight.reset(); lastFlightTime = nil
            }
            for command in control.commands(for: request.id) {
                switch command {
                case .loadScan(let next):
                    flight.reset(); hasOrigin = false; sawReadyAsset = false; loaded = nil
                    beginLoading(next)
                case .setFlightEnabled(let enabled):
                    flightEnabled = enabled; flight.reset()
                    control.report(request.id) { $0.flightEnabled = enabled; $0.flightHeld = false }
                case .adjustFlightPanel(let height, let distance):
                    flight.adjustPanel(height: height,distance: distance,head: anchor.originFromAnchorTransform)
                case .bringFlightPanelHere:
                    flight.bringPanelHere(head: anchor.originFromAnchorTransform)
                    flightEnabled = true
                    control.report(request.id) { $0.flightEnabled = true }
                case .step(let forward, let right, let up):
                    flight.reset()
                    pose.step(forward: forward, right: right, up: up, head: anchor.originFromAnchorTransform)
                case .turn(let radians): flight.reset(); pose.snapTurn(radians: radians, head: anchor.originFromAnchorTransform)
                case .recenter: flight.reset(); pose.begin(at: anchor.originFromAnchorTransform, facing: loaded?.spawnYaw)
                case .setBubbleRadius(let radius):
                    let head = (pose.worldFromTracking * anchor.originFromAnchorTransform).columns.3
                    loaded?.updatePanorama(at: SIMD3(head.x, head.y, head.z), radius: radius)
                case .refreshBackground:
                    let head = (pose.worldFromTracking * anchor.originFromAnchorTransform).columns.3
                    loaded?.updatePanorama(at: SIMD3(head.x, head.y, head.z), force: true)
                }
            }
            let dt = Float(lastFlightTime.map { time - $0 } ?? 0)
            lastFlightTime = time
            let flightActive = flightAvailable && flightEnabled && control.interactionActive()
            let navigation = control.snapshot()
            var motion = flight.update(head: anchor.originFromAnchorTransform, hands: handTracker.latest(), deltaTime: dt, enabled: flightActive, flightAllowed: loaded != nil && !navigation.scanSwitchPending, canGoPrevious: navigation.canGoPrevious, canGoNext: navigation.canGoNext, panelButtonsEnabled: false, browsingAllowed: navigation.canBrowse)
            let events = panelEvents.withLock { queue in let events = queue; queue.removeAll(keepingCapacity: true); return events }
            let buttonsActive = flightActive && flight.hasPlacement && !flight.isMovingPanel
            if !buttonsActive { panelInput.reset() }
            for event in events {
                if let action = panelInput.update(event,panel: flight.panelTransform,enabled: buttonsActive,
                    canGoPrevious: flight.previousEnabled && navigation.canBrowse,canGoNext: flight.nextEnabled && navigation.canBrowse) {
                    flight.reset(); motion = FlightMotion()
                    control.panelAction(action,for: request.id)
                    Self.log.info("Panel spatial selection: \(String(describing: action),privacy: .public)")
                }
            }
            if !panelInput.pressed.isEmpty { flight.reset(); motion = FlightMotion() }
            if flightActive { pose.fly(motion, deltaTime: dt, head: anchor.originFromAnchorTransform) }
            if flightAvailable {
                let held = flight.isHeld, enabled = flightEnabled, moving = flight.isMovingPanel
                control.report(request.id) {
                    $0.flightHeld = held
                    $0.flightMovingPanel = moving
                    $0.flightMessage = !enabled ? "Flight panel hidden." : navigation.loadFailure != nil ? "This scan could not load. Use Previous or Next to continue, or Menu for details." : moving ? "Placing panel · release the handle to fix its position." : held ? "Flying toward your view · release to stop." : "Pinch the stick to fly. Use the horizontal handle to place the panel."
                }
            }
            if let loaded {
                sawReadyAsset = true
                let head = (pose.worldFromTracking * anchor.originFromAnchorTransform).columns.3
                loaded.updatePanorama(at: SIMD3(head.x, head.y, head.z))
            }
        }
        // Both eyes use the same completed image/radius for the entire frame.
        let sceneSnapshot = loaded?.snapshot()
        for (drawableIndex, drawable) in drawables.enumerated() {
            guard let command = queue.makeCommandBuffer() else {
                // Release our frame permit even if command allocation fails.
                if drawableIndex == drawables.count - 1 { semaphore.signal() }
                fail(SceneError.unavailable); continue
            }
            drawable.deviceAnchor = anchor
            if drawableIndex == drawables.count - 1 {
                let semaphore = semaphore
                command.addCompletedHandler { _ in semaphore.signal() }
            }
            let id = request.id, control = control
            command.addCompletedHandler { buffer in
                if buffer.status == .error {
                    let message = "The GPU could not render this scan. \(buffer.error?.localizedDescription ?? "Try a smaller export.")"
                    control.report(id) { $0.failure = message }
                }
            }
            let layered = layer.configuration.layout == .layered
            let groups = layered ? [Array(drawable.views.indices)] : drawable.views.indices.map { [$0] }
            for indices in groups {
                let textureIndex = layered ? 0 : indices[0]
                let color = drawable.colorTextures[textureIndex], depth = drawable.depthTextures[textureIndex]
                let rateMap = drawable.rasterizationRateMaps.isEmpty ? nil : drawable.rasterizationRateMaps[min(textureIndex, drawable.rasterizationRateMaps.count - 1)]
                let arrayLength = layered ? drawable.views.count : 1
                var rendered = false
                if let loaded, let anchor, let background = sceneSnapshot {
                    let views = indices.map { index in
                        let view = drawable.views[index]
                        let eye = pose.worldFromTracking * anchor.originFromAnchorTransform * view.transform
                        return SplatRenderer.ViewportDescriptor(viewport: view.textureMap.viewport,
                            projectionMatrix: drawable.computeProjection(viewIndex: index),
                            viewMatrix: eye.inverse * loaded.worldFromSource,
                            screenSize: SIMD2(Int(view.textureMap.viewport.width), Int(view.textureMap.viewport.height)))
                    }
                    do {
                        let current = background.current
                        do {
                            let rays = indices.map { index in
                                var eye = pose.worldFromTracking * anchor.originFromAnchorTransform * drawable.views[index].transform
                                eye.columns.3 = SIMD4(0, 0, 0, 1)
                                return eye * drawable.computeProjection(viewIndex: index).inverse
                            }
                            try current.panorama.draw(cube: current.texture, worldFromClip: rays, viewports: views.map(\.viewport),
                                color: color, depth: depth, rateMap: rateMap, arrayLength: arrayLength, to: command)
                            rendered = true
                        }
                        let sourceHead = loaded.worldFromSource.inverse * pose.worldFromTracking * anchor.originFromAnchorTransform
                        let sortCenter = SIMD3(sourceHead.columns.3.x, sourceHead.columns.3.y, sourceHead.columns.3.z)
                        let drewSplats = try current.renderer.render(viewports: views, colorTexture: color, colorStoreAction: .store,
                            colorLoadAction: .load,
                            depthTexture: depth, rasterizationRateMap: rateMap, renderTargetArrayLength: arrayLength,
                            accessTimeout: 0, sortTimeout: 0, sortingPosition: sortCenter, to: command)
                        rendered = rendered || drewSplats
                        if rendered {
                            let localCount = current.renderer.renderedSplatCount
                            let activeRadius = current.configuration.radius
                            let suffix: String
                            if let error = background.error { suffix = " · " + error }
                            else if background.refreshing && background.requestedRadius != activeRadius { suffix = " · applying \(Int(background.requestedRadius)) m…" }
                            else { suffix = background.refreshing ? " · refreshing distant scenery…" : " · cached distant scenery" }
                            control.report(request.id) { status in
                                status.ready = true
                                status.bubbleRadius = activeRadius
                                status.visibleSplatCount = localCount
                                status.message = "\(Int(activeRadius)) m bubble · \(localCount.formatted()) of \(status.splatCount.formatted()) splats live" + suffix
                            }
                        }
                    } catch { fail(error) }
                }
                // No incomplete or uninitialized frame is ever presented while loading/sorting/tracking.
                if !rendered { clear(color: color, depth: depth, rateMap: rateMap, arrayLength: arrayLength, command: command) }
                if let anchor, flightAvailable, flightEnabled, control.interactionActive(), let joystick {
                    let clips = indices.map { index in
                        drawable.computeProjection(viewIndex: index) * (anchor.originFromAnchorTransform * drawable.views[index].transform).inverse
                    }
                    do {
                        try joystick.draw(flight: flight, scanFailed: control.snapshot().loadFailure != nil, pressedButtons: panelInput.pressed, eyePositions: indices.map { (anchor.originFromAnchorTransform * drawable.views[$0].transform).columns.3 }, clipFromTracking: clips,
                            viewports: indices.map { drawable.views[$0].textureMap.viewport }, color: color, depth: depth,
                            rateMap: rateMap, arrayLength: arrayLength, command: command)
                    } catch {
                        flight.reset(); flightAvailable = false
                        let detail = "Could not draw the flight panel: " + error.localizedDescription
                        Self.log.error("\(detail,privacy: .public)")
                        control.report(request.id) {
                            $0.flightAvailable = false; $0.flightHeld = false
                            $0.flightMessage = detail + "\nLeave and re-enter to retry. Navigation buttons remain available."
                        }
                    }
                }
            }
            drawable.encodePresent(commandBuffer: command)
            command.commit()
        }
    }

    private func clear(color: MTLTexture, depth: MTLTexture, rateMap: MTLRasterizationRateMap?, arrayLength: Int, command: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = Self.blue
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 0
        pass.renderTargetArrayLength = arrayLength
        pass.rasterizationRateMap = rateMap
        command.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }
}
