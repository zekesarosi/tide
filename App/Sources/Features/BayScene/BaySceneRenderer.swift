import MetalKit
import QuartzCore
import simd
import TideKit

/// Mirrors `BayUniforms` in BaySceneShaders.metal.
struct BayUniforms {
    var viewProj = matrix_identity_float4x4
    var invViewProj = matrix_identity_float4x4
    var cameraPos = SIMD4<Float>()
    var sunDir = SIMD4<Float>()
    var scale = SIMD4<Float>()
    var colour = SIMD4<Float>()
    var bounds = SIMD4<Float>()
    var viewport = SIMD4<Float>()
    var flow = SIMD4<Float>()
    var eval = SIMD4<Float>()
    var eval2 = SIMD4<Float>()
    var probe = SIMD4<Float>()
    var base = SIMD4<Float>()
    var motion = SIMD4<Float>()
}

/// Draws San Francisco Bay in 3D: the seafloor, the water at its level now,
/// the land around it, and the currents as drifting particles. The tide and
/// the currents are evaluated on the GPU at every mesh node each frame the
/// clock moves, from the harmonic constants (plus the live forecast residual,
/// when there is one).
@MainActor
final class BaySceneRenderer: NSObject, MTKViewDelegate {
    static let maxConstituents = 24
    static let particleCount = 11_000
    static let trailLength = 24
    static let levelScale: Float = 1.2      // m, colour saturates
    static let speedScale: Float = 2.5      // m/s (≈ 4.9 kn), colour saturates
    static let flowWidth = 2048
    static let maskWidth = 4096

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let model: BaySceneModel
    private let geometry: BaySceneGeometry
    private let mesh: TideMesh

    private let evalPipeline: MTLComputePipelineState
    private let particlePipeline: MTLComputePipelineState
    private let flowPipeline: MTLRenderPipelineState
    private let floorPipeline: MTLRenderPipelineState
    private let landPipeline: MTLRenderPipelineState
    private let oceanPipeline: MTLRenderPipelineState
    private let baseTexture: MTLTexture
    private let baseBounds: SIMD4<Float>
    private let wallPipeline: MTLRenderPipelineState
    private let waterPipeline: MTLRenderPipelineState
    private let waterWallPipeline: MTLRenderPipelineState
    private let trailPipeline: MTLRenderPipelineState
    private let ringPipeline: MTLRenderPipelineState
    private let depthWrite: MTLDepthStencilState
    private let depthRead: MTLDepthStencilState
    private let sampler: MTLSamplerState

    private let nodeBuffer: MTLBuffer
    private let gradientBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let solidWallBuffer: MTLBuffer?
    private let waterWallBuffer: MTLBuffer?
    private let meanBuffer: MTLBuffer
    private let zetaBuffer: MTLBuffer
    private let depthMeanBuffer: MTLBuffer
    private let surfaceBuffer: MTLBuffer
    private let stateBuffer: MTLBuffer
    private let particleBuffer: MTLBuffer
    private let historyBuffer: MTLBuffer
    private let dummyBuffer: MTLBuffer
    private var residualBuffer: MTLBuffer?
    private var residualKey: Date?
    private let maskTexture: MTLTexture
    private let flowTexture: MTLTexture
    private let flowPass = MTLRenderPassDescriptor()

    var camera = BayCamera()
    private var lastCamera = BayCamera()
    private var lastFrame: CFTimeInterval?
    private var lastEval: (time: Date, surface: Bool, residual: Date?)?
    private var lastDrawn: (time: Date, camera: BayCamera, size: CGSize, key: String)?
    private var lastOverlay: CFTimeInterval = 0
    private var overlayKey = ""
    private var historyHead = 0
    private var resetParticles = true
    /// The camera the particles were last stepped under, to measure how far the view moved.
    private var particleCamera: BayCamera?
    private var frameSeed: UInt32 = 1
    private var flowWasShown = false
    private let fixedFPS: Int
    private var benchmark: BaySceneBenchmark?
    private var shimmerClock: Double = 0

    init?(view: MTKView, model: BaySceneModel, mesh: TideMesh, geometry: BaySceneGeometry) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        self.device = device
        self.queue = queue
        self.model = model
        self.mesh = mesh
        self.geometry = geometry
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.depthStencilStorageMode = .memoryless
        let defaults = UserDefaults.standard
        let msaa = defaults.integer(forKey: "BayMSAA")
        view.sampleCount = [1, 2, 4].contains(msaa) ? msaa : 4
        view.clearColor = MTLClearColor(red: 0.016, green: 0.031, blue: 0.043, alpha: 1)
        fixedFPS = defaults.integer(forKey: "BayFPS")
        view.preferredFramesPerSecond = fixedFPS > 0 ? fixedFPS : 60
        if BaySceneBenchmark.isEnabled {
            benchmark = BaySceneBenchmark(config: "MSAA \(view.sampleCount)× · \(mesh.nodeCount) nodes · \(mesh.triangleCount) triangles · \(Self.particleCount) particles · \(UIDevice.current.model)")
        }

        func pipeline(_ v: String, _ f: String, blend: Bool = false, format: MTLPixelFormat? = nil, depth: Bool = true, samples: Int? = nil) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: v)
            d.fragmentFunction = library.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = format ?? view.colorPixelFormat
            d.depthAttachmentPixelFormat = depth ? view.depthStencilPixelFormat : .invalid
            d.rasterSampleCount = samples ?? view.sampleCount
            if blend {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let ef = library.makeFunction(name: "bay_eval"), let ep = try? device.makeComputePipelineState(function: ef),
              let pf = library.makeFunction(name: "bay_particles"), let pp = try? device.makeComputePipelineState(function: pf),
              let flow = pipeline("flow_vertex", "flow_fragment", format: .rgba16Float, depth: false, samples: 1),
              let mask = pipeline("flow_vertex", "mask_fragment", format: .r8Unorm, depth: false, samples: 4),
              let floor = pipeline("floor_vertex", "floor_fragment"),
              let land = pipeline("plane_vertex", "land_fragment"),
              let ocean = pipeline("plane_vertex", "ocean_fragment"),
              let wall = pipeline("wall_vertex", "wall_fragment"),
              let water = pipeline("water_vertex", "water_fragment", blend: true),
              let waterWall = pipeline("wall_vertex", "wall_fragment", blend: true),
              let trail = pipeline("trail_vertex", "trail_fragment", blend: true),
              let ring = pipeline("ring_vertex", "ring_fragment", blend: true) else { return nil }
        evalPipeline = ep; particlePipeline = pp; flowPipeline = flow; floorPipeline = floor; landPipeline = land; oceanPipeline = ocean
        wallPipeline = wall; waterPipeline = water; waterWallPipeline = waterWall; trailPipeline = trail; ringPipeline = ring

        func depthState(_ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState? {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)
        }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let dw = depthState(.less, write: true), let dr = depthState(.lessEqual, write: false),
              let smp = device.makeSamplerState(descriptor: sd) else { return nil }
        depthWrite = dw; depthRead = dr; sampler = smp

        func buffer<T>(_ a: [T]) -> MTLBuffer? {
            a.withUnsafeBytes { raw in raw.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: raw.count) } }
        }
        func buffer(_ d: Data) -> MTLBuffer? {
            d.withUnsafeBytes { raw in raw.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: d.count) } }
        }
        let n = mesh.nodeCount
        guard let nb = buffer(geometry.nodes), let gb = buffer(geometry.gradients), let ib = buffer(geometry.triangles),
              let mb = buffer(mesh.rawBlock(.mean)), let zb = buffer(mesh.rawBlock(.zeta)),
              let db = buffer(mesh.rawBlock(.depthMeanCurrent)), let sb = buffer(mesh.rawBlock(.surfaceCurrent)),
              let st = device.makeBuffer(length: n * 16, options: .storageModePrivate),
              let pb = device.makeBuffer(length: Self.particleCount * 16, options: .storageModePrivate),
              let hb = device.makeBuffer(length: Self.particleCount * Self.trailLength * 16, options: .storageModePrivate),
              let dummy = device.makeBuffer(length: 64) else { return nil }
        nodeBuffer = nb; gradientBuffer = gb; indexBuffer = ib; meanBuffer = mb; zetaBuffer = zb
        depthMeanBuffer = db; surfaceBuffer = sb; stateBuffer = st; particleBuffer = pb; historyBuffer = hb; dummyBuffer = dummy
        solidWallBuffer = buffer(geometry.solidWalls)
        waterWallBuffer = buffer(geometry.waterWalls)

        let aspect = Double(geometry.bounds.height / max(geometry.bounds.width, 1))
        let fd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: Self.flowWidth,
                                                          height: max(Int(Double(Self.flowWidth) * aspect), 64), mipmapped: false)
        fd.usage = [.renderTarget, .shaderRead]
        fd.storageMode = .private
        guard let ft = device.makeTexture(descriptor: fd) else { return nil }
        flowTexture = ft
        flowPass.colorAttachments[0].texture = ft
        flowPass.colorAttachments[0].loadAction = .clear
        flowPass.colorAttachments[0].storeAction = .store
        flowPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let mt = Self.makeMask(device: device, queue: queue, pipeline: mask, nodes: nb, indices: ib,
                                     indexCount: geometry.triangles.count, bounds: geometry.bounds, aspect: aspect) else { return nil }
        maskTexture = mt
        guard let bt = Self.makeBaseTexture(device: device, map: model.baseMap) else { return nil }
        baseTexture = bt
        let p = geometry.projection
        let sw = p.point(latitude: BaySceneBaseMap.latitudes.lowerBound, longitude: BaySceneBaseMap.longitudes.lowerBound)
        let ne = p.point(latitude: BaySceneBaseMap.latitudes.upperBound, longitude: BaySceneBaseMap.longitudes.upperBound)
        baseBounds = SIMD4(Float(sw.x), Float(sw.y), Float(ne.x - sw.x), Float(ne.y - sw.y))
        super.init()
        // Start over the Golden Gate and the Central Bay, tilted.
        let gg = geometry.projection.point(latitude: 37.835, longitude: -122.452)
        camera.target = gg
        camera.distance = 30_000
        camera.pitch = 0.7
        camera.heading = 0
        // Testing aids: -BaySceneCamera "lat,lon,distance,pitch,heading°".
        if let s = UserDefaults.standard.string(forKey: "BaySceneCamera") {
            let v = s.split(separator: ",").compactMap { Double($0) }
            if v.count >= 3 {
                camera.target = geometry.projection.point(latitude: v[0], longitude: v[1])
                camera.distance = v[2]
                if v.count >= 4 { camera.pitch = v[3] }
                if v.count >= 5 { camera.heading = v[4] * .pi / 180 }
            }
        }
    }

    /// Natural Earth land around the bay (all water if the file is missing).
    private static func makeBaseTexture(device: MTLDevice, map: BaySceneBaseMap?) -> MTLTexture? {
        let w = map?.width ?? 1, h = map?.height ?? 1
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        let pixels = map?.pixels ?? [0]
        pixels.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: w)
        }
        return t
    }

    /// Water coverage, rasterised once at 4× MSAA so the land's edge is smooth.
    private static func makeMask(device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState,
                                 nodes: MTLBuffer, indices: MTLBuffer, indexCount: Int, bounds: CGRect, aspect: Double) -> MTLTexture? {
        let w = maskWidth, h = max(Int(Double(maskWidth) * aspect), 64)
        let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        md.usage = [.renderTarget, .shaderRead]
        md.storageMode = .private
        let ms = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        ms.textureType = .type2DMultisample
        ms.sampleCount = 4
        ms.usage = .renderTarget
        ms.storageMode = .memoryless
        guard let resolved = device.makeTexture(descriptor: md), let msaa = device.makeTexture(descriptor: ms),
              let cmd = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaa
        pass.colorAttachments[0].resolveTexture = resolved
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var U = BayUniforms()
        U.bounds = SIMD4(Float(bounds.minX), Float(bounds.minY), Float(bounds.width), Float(bounds.height))
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(nodes, offset: 0, index: 0)
        enc.setVertexBuffer(nodes, offset: 0, index: 1) // state is unused by the mask
        enc.setVertexBytes(&U, length: MemoryLayout<BayUniforms>.stride, index: 2)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0)
        enc.endEncoding()
        cmd.commit()
        return resolved
    }

    // MARK: Scale

    /// Vertical exaggeration of depth and of the water level at the current zoom.
    var exaggeration: (depth: Float, water: Float) {
        let t = min(max((camera.distance - 1_500) / (40_000 - 1_500), 0), 1)
        let base = Float(2 + 6 * t * t * (3 - 2 * t))
        switch model.relief {
        case .natural: return (1, 1)
        case .auto: return (base, base * 3)
        case .strong: return (base * 2, base * 6)
        }
    }

    var landHeight: Float { 2.6 * exaggeration.water }

    /// Fewer particles zoomed out, so the whole bay reads as lines with gaps.
    var activeParticles: Int {
        let t = min(max((log(camera.distance) - log(3_000)) / (log(70_000) - log(3_000)), 0), 1)
        return Int(Double(Self.particleCount) * (1 - 0.5 * t))
    }

    /// Seconds of drift per second on screen: a 1 m/s current crosses a
    /// 14th of the view each second, whatever the zoom.
    func driftFactor(size: CGSize) -> Double {
        let w = camera.viewWidth(aspect: Double(size.width / max(size.height, 1)))
        return w / 14 * (model.calmFlow ? 0.4 : 1)
    }

    // MARK: Picking

    /// The ground point under a view location (on the water plane).
    func pick(_ p: CGPoint, in size: CGSize) -> SIMD2<Double>? {
        camera.ground(at: p, in: size)
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { lastDrawn = nil; resetParticles = true }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let raw: Double = lastFrame.map { now - $0 } ?? 1.0 / 60
        let dt: Double = min(max(raw, 1.0 / 240), 1.0 / 15)
        lastFrame = now
        benchmark?.step(model: model, camera: &camera, now: now, dt: dt, geometry: geometry)
        model.advance(dt)
        if let fly = model.flyRequest {
            model.flyRequest = nil
            camera.fly(to: fly.point, distance: fly.distance)
        }
        camera.step(dt)
        camera.clamp(to: geometry.bounds)

        let size = view.bounds.size
        let moving = camera != lastCamera || camera.isMoving
        lastCamera = camera
        let flowOn = model.showsFlow
        if flowOn && !flowWasShown { resetParticles = true }
        flowWasShown = flowOn
        if fixedFPS == 0 {
            // 60 while anything moves; the particles alone drift at 30.
            let want = moving || model.playing ? 60 : (flowOn ? 30 : 30)
            if view.preferredFramesPerSecond != want { view.preferredFramesPerSecond = want }
        }
        updateOverlay(size: size, now: now)

        let key = "\(model.colourMode)|\(model.relief)|\(model.surfaceCurrents)|\(flowOn)|\(model.probe?.id.uuidString ?? "-")|\(residualKey?.timeIntervalSince1970 ?? 0)"
        if !flowOn, let last = lastDrawn, last.time == model.liveTime, last.camera == camera, last.size == size, last.key == key {
            return // nothing moved: keep the last frame
        }
        lastDrawn = (model.liveTime, camera, size, key)

        let beforeDrawable = CACurrentMediaTime()
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }
        let afterDrawable = CACurrentMediaTime()

        let date = model.liveTime
        syncResidual()
        let ex = exaggeration
        let vp = camera.viewProjection(size: size)
        var U = BayUniforms()
        U.viewProj = vp
        U.invViewProj = vp.inverse
        U.cameraPos = SIMD4(SIMD3<Float>(camera.eye), 1)
        U.sunDir = sunDirection(date)
        U.scale = SIMD4(ex.depth, ex.water, landHeight, Float(camera.distance * 0.0012) + 0.3)
        shimmerClock += dt
        let mode: Float = switch model.colourMode { case .level: 0; case .speed: 1; case .depth: 2 }
        U.colour = SIMD4(mode, Self.levelScale, Self.speedScale, Float(shimmerClock.truncatingRemainder(dividingBy: 10_000)))
        let b = geometry.bounds
        U.bounds = SIMD4(Float(b.minX), Float(b.minY), Float(b.width), Float(b.height))
        let scale = Float(view.contentScaleFactor)
        U.viewport = SIMD4(Float(view.drawableSize.width), Float(view.drawableSize.height), 1.15 * scale, Float(camera.distance * 4 + 30_000))
        let drift = driftFactor(size: size)
        frameSeed = frameSeed &* 1_664_525 &+ 1_013_904_223
        U.flow = SIMD4(Float(drift * dt), Float(frameSeed >> 8), Float(dt), resetParticles ? 1 : 0)
        resetParticles = false
        // When the view moves, particles would stay bunched where the old view
        // put them and new ground would only fill in as they expire. Respawn
        // each one into the current view with a chance proportional to how far
        // the view moved this frame: zooming out 2× redistributes nearly all.
        var reseed: Float = 0
        if let old = particleCamera {
            let width = max(camera.viewWidth(aspect: Double(size.width / max(size.height, 1))), 1)
            let change = abs(log(camera.distance / old.distance))
                + simd_length(camera.target - old.target) / width
                + abs(camera.heading - old.heading) * 0.5
                + abs(camera.pitch - old.pitch)
            reseed = Float(min(change * 2.5, 0.2)) // capped so a fast fling never restarts every trail at once
        }
        particleCamera = camera
        U.motion = SIMD4(reseed, 0, 0, 0)
        U.eval = SIMD4(Float(mesh.nodeCount), Float(min(mesh.constituents.count, Self.maxConstituents)), 0, 0)
        if let r = model.residual, residualBuffer != nil, let f = r.frameIndex(at: date) {
            U.eval = SIMD4(U.eval.x, U.eval.y, Float(f.t), 1)
            U.eval2.x = Float(f.lower); U.eval2.y = Float(f.upper)
        }
        historyHead = (historyHead + 1) % Self.trailLength
        U.eval2.z = Float(historyHead)
        U.eval2.w = Float(Self.trailLength)
        if let p = model.probe { U.probe = SIMD4(Float(p.point.x), Float(p.point.y), 1, 0) }
        U.probe.w = Float(camera.distance)
        U.base = baseBounds
        let particles = activeParticles

        // 1. The tide and currents at every node, when the clock (or the inputs) moved.
        let evalKey = (date, model.surfaceCurrents, residualKey)
        let needsEval = lastEval.map { $0.time != evalKey.0 || $0.surface != evalKey.1 || $0.residual != evalKey.2 } ?? true
        if needsEval {
            lastEval = evalKey
            encodeEval(cmd: cmd, date: date, uniforms: &U)
        }
        // 2. Particles drift through the flow texture.
        if flowOn, let ce = cmd.makeComputeCommandEncoder() {
            ce.setComputePipelineState(particlePipeline)
            ce.setBuffer(particleBuffer, offset: 0, index: 0)
            ce.setBuffer(historyBuffer, offset: 0, index: 1)
            ce.setBytes(&U, length: MemoryLayout<BayUniforms>.stride, index: 2)
            ce.setTexture(flowTexture, index: 0)
            ce.setSamplerState(sampler, index: 0)
            ce.dispatchThreads(MTLSize(width: particles, height: 1, depth: 1),
                               threadsPerThreadgroup: MTLSize(width: min(particlePipeline.maxTotalThreadsPerThreadgroup, 256), height: 1, depth: 1))
            ce.endEncoding()
        }

        // 3. The scene.
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let triCount = geometry.triangles.count
        enc.setFrontFacing(.counterClockwise)

        // Seafloor
        enc.setRenderPipelineState(floorPipeline)
        enc.setDepthStencilState(depthWrite)
        enc.setCullMode(.back)
        enc.setVertexBuffer(nodeBuffer, offset: 0, index: 0)
        enc.setVertexBuffer(gradientBuffer, offset: 0, index: 1)
        enc.setVertexBytes(&U, length: MemoryLayout<BayUniforms>.stride, index: 2)
        enc.setFragmentBytes(&U, length: MemoryLayout<BayUniforms>.stride, index: 2)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: triCount, indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: 0)

        // Banks
        enc.setCullMode(.none)
        if let walls = solidWallBuffer {
            enc.setRenderPipelineState(wallPipeline)
            enc.setVertexBuffer(walls, offset: 0, index: 0)
            enc.setVertexBuffer(nodeBuffer, offset: 0, index: 1)
            enc.setVertexBuffer(stateBuffer, offset: 0, index: 3)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: geometry.solidWalls.count)
        }

        // Land, then the ocean beyond the model, as one base map.
        var landZ = U.scale.z, seaZ: Float = 0
        enc.setRenderPipelineState(landPipeline)
        enc.setVertexBytes(&landZ, length: 4, index: 3)
        enc.setFragmentTexture(maskTexture, index: 0)
        enc.setFragmentTexture(baseTexture, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.setRenderPipelineState(oceanPipeline)
        enc.setVertexBytes(&seaZ, length: 4, index: 3)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        // Water
        enc.setRenderPipelineState(waterPipeline)
        enc.setDepthStencilState(depthRead)
        enc.setCullMode(.back)
        enc.setVertexBuffer(nodeBuffer, offset: 0, index: 0)
        enc.setVertexBuffer(stateBuffer, offset: 0, index: 1)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: triCount, indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: 0)
        if let walls = waterWallBuffer {
            enc.setCullMode(.none)
            enc.setRenderPipelineState(waterWallPipeline)
            enc.setVertexBuffer(walls, offset: 0, index: 0)
            enc.setVertexBuffer(nodeBuffer, offset: 0, index: 1)
            enc.setVertexBuffer(stateBuffer, offset: 0, index: 3)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: geometry.waterWalls.count)
        }

        // Currents
        if flowOn {
            enc.setCullMode(.none)
            enc.setRenderPipelineState(trailPipeline)
            enc.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            enc.setVertexBuffer(historyBuffer, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: (Self.trailLength - 1) * 6, instanceCount: particles)
        }

        // Probe ring
        if let probe = model.probe {
            var radius = Float(camera.distance * 0.012)
            var z = Float(model.waterLevel(probe, at: date) ?? 0) * ex.water + U.scale.w
            enc.setRenderPipelineState(ringPipeline)
            enc.setDepthStencilState(depthRead)
            enc.setVertexBytes(&radius, length: 4, index: 3)
            enc.setVertexBytes(&z, length: 4, index: 4)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        enc.endEncoding()
        cmd.present(drawable)
        if let bench = benchmark {
            cmd.addCompletedHandler { cb in
                let g = cb.gpuEndTime - cb.gpuStartTime
                DispatchQueue.main.async { bench.recordGPU(seconds: g) }
            }
        }
        cmd.commit()
        benchmark?.recordFrame(encodeSeconds: (beforeDrawable - now) + (CACurrentMediaTime() - afterDrawable),
                               waitSeconds: afterDrawable - beforeDrawable)
    }

    private func encodeEval(cmd: MTLCommandBuffer, date: Date, uniforms U: inout BayUniforms) {
        let k = min(mesh.constituents.count, Self.maxConstituents)
        var ph = HarmonicBasis.phasors(Array(mesh.constituents.prefix(k)), at: date).map { SIMD2<Float>(Float($0.cos), Float($0.sin)) }
        if ph.isEmpty { ph = [.zero] }
        var surface: UInt32 = model.surfaceCurrents ? 1 : 0
        if let ce = cmd.makeComputeCommandEncoder() {
            ce.setComputePipelineState(evalPipeline)
            ce.setBuffer(meanBuffer, offset: 0, index: 0)
            ce.setBuffer(zetaBuffer, offset: 0, index: 1)
            ce.setBuffer(model.surfaceCurrents ? surfaceBuffer : depthMeanBuffer, offset: 0, index: 2)
            ce.setBuffer(residualBuffer ?? dummyBuffer, offset: 0, index: 3)
            ce.setBytes(ph, length: ph.count * MemoryLayout<SIMD2<Float>>.stride, index: 4)
            ce.setBytes(&U, length: MemoryLayout<BayUniforms>.stride, index: 5)
            ce.setBuffer(stateBuffer, offset: 0, index: 6)
            ce.setBytes(&surface, length: 4, index: 7)
            ce.dispatchThreads(MTLSize(width: mesh.nodeCount, height: 1, depth: 1),
                               threadsPerThreadgroup: MTLSize(width: min(evalPipeline.maxTotalThreadsPerThreadgroup, 256), height: 1, depth: 1))
            ce.endEncoding()
        }
        // Velocity (and level) rasterised over the bay for the particles.
        if let re = cmd.makeRenderCommandEncoder(descriptor: flowPass) {
            re.setRenderPipelineState(flowPipeline)
            re.setCullMode(.none)
            re.setVertexBuffer(nodeBuffer, offset: 0, index: 0)
            re.setVertexBuffer(stateBuffer, offset: 0, index: 1)
            re.setVertexBytes(&U, length: MemoryLayout<BayUniforms>.stride, index: 2)
            re.drawIndexedPrimitives(type: .triangle, indexCount: geometry.triangles.count, indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: 0)
            re.endEncoding()
        }
    }

    /// Uploads a new live forecast when the model has one.
    private func syncResidual() {
        guard let r = model.residual else {
            if residualBuffer != nil { residualBuffer = nil; residualKey = nil }
            return
        }
        guard r.cycle != residualKey, r.nodeCount == mesh.nodeCount, r.meshID == mesh.meshID else { return }
        let data = r.rawFrames()
        residualBuffer = data.withUnsafeBytes { raw in raw.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: data.count) } }
        residualKey = residualBuffer == nil ? nil : r.cycle
    }

    /// Towards the Sun in the local frame, with a floor on its height so the
    /// scene stays readable at night; w is daylight 0...1.
    private func sunDirection(_ date: Date) -> SIMD4<Float> {
        let s = Ephemeris.sun(date).subpoint(at: date)
        func ecef(_ lat: Double, _ lon: Double) -> SIMD3<Double> {
            let la = lat * .pi / 180, lo = lon * .pi / 180
            return SIMD3(cos(la) * cos(lo), cos(la) * sin(lo), sin(la))
        }
        let p = geometry.projection
        let la = p.latitude0 * .pi / 180, lo = p.longitude0 * .pi / 180
        let east = SIMD3(-sin(lo), cos(lo), 0.0)
        let north = SIMD3(-sin(la) * cos(lo), -sin(la) * sin(lo), cos(la))
        let up = ecef(p.latitude0, p.longitude0)
        let v = ecef(s.latitude, s.longitude)
        var local = SIMD3(simd_dot(v, east), simd_dot(v, north), simd_dot(v, up))
        let elevation = asin(max(-1, min(1, local.z)))
        let daylight = Float(min(max((elevation + 0.1) / 0.35, 0), 1))
        let minElevation = 0.42
        if elevation < minElevation {
            let h = simd_normalize(SIMD2(local.x, local.y) + SIMD2(1e-6, 1e-6))
            local = SIMD3(h.x * cos(minElevation), h.y * cos(minElevation), sin(minElevation))
        }
        return SIMD4(SIMD3<Float>(simd_normalize(local)), daylight)
    }

    // MARK: Labels

    /// Projects the place names and the probe into view points, ~10 times a second while things move.
    private func updateOverlay(size: CGSize, now: CFTimeInterval) {
        let key = "\(camera.target)|\(camera.distance)|\(camera.heading)|\(camera.pitch)|\(size)|\(model.probe?.id.uuidString ?? "-")|\(model.relief)|\(String(describing: model.overlay.labelBand))"
        guard key != overlayKey, now - lastOverlay > 0.1 else { return }
        overlayKey = key
        lastOverlay = now
        let vp = camera.viewProjection(size: size)
        func project(_ p: SIMD2<Double>, z: Float) -> CGPoint? {
            let c = vp * SIMD4(Float(p.x), Float(p.y), z, 1)
            guard c.w > 0 else { return nil }
            let ndc = SIMD2(c.x, c.y) / c.w
            guard abs(ndc.x) < 1.05, abs(ndc.y) < 1.05 else { return nil }
            return CGPoint(x: CGFloat(ndc.x + 1) / 2 * size.width, y: CGFloat(1 - ndc.y) / 2 * size.height)
        }
        let land = landHeight
        var labels: [BayPlacedLabel] = []
        for place in BayPlace.all where camera.distance <= place.maxDistance {
            let p = geometry.projection.point(latitude: place.latitude, longitude: place.longitude)
            if let s = project(p, z: place.kind == .land ? land : 0), model.overlay.labelBand?.contains(s.y) ?? true {
                labels.append(BayPlacedLabel(id: place.id, point: s, isWater: place.kind == .water))
            }
        }
        let o = model.overlay
        if o.labels != labels { o.labels = labels }
        let probe = model.probe.flatMap { project($0.point, z: 0) }
        if o.probePoint != probe { o.probePoint = probe }
        let drift = driftFactor(size: size)
        if abs(o.driftFactor - drift) > o.driftFactor * 0.08 { o.driftFactor = drift }
    }
}
