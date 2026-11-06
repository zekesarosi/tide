import MetalKit
import QuartzCore
import simd
import TideKit

/// Mirrors `GlobeUniforms` in GlobeShaders.metal.
struct GlobeUniforms {
    var viewProj = matrix_identity_float4x4
    var invViewProj = matrix_identity_float4x4
    var cameraPos = SIMD4<Float>()
    var sunDir = SIMD4<Float>()
    var moonDir = SIMD4<Float>()
    var probe = SIMD4<Float>()
    var phasors: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                  SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) =
        (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    var params = SIMD4<Float>()
    var params2 = SIMD4<Float>()
    var grid = SIMD4<Float>()
    var gridN = SIMD4<Float>()
}

/// Mirrors `BodyUniforms`.
struct BodyUniforms {
    var viewProj = matrix_identity_float4x4
    var model = matrix_identity_float4x4
    var sunDir = SIMD4<Float>()
    var color = SIMD4<Float>()
}

/// Draws the tide globe: the ocean tide evaluated per pixel from the atlas,
/// lit by the real Sun, with the Moon, the stations and the sky.
@MainActor
final class GlobeRenderer: NSObject, MTKViewDelegate {
    static let maxConstituents = 8
    /// Ocean relief: Earth radii per metre of tide (1 m ≈ 76 km).
    static let reliefScale: Float = 0.012
    /// Colour ramp saturates at this height (m).
    static let colourScale: Float = 1.4
    /// Moon distance in Earth radii, compressed from 60.3 so it stays in view.
    static let moonDistance: Float = 7

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let globePipeline: MTLRenderPipelineState
    private let bodyPipeline: MTLRenderPipelineState
    private let pointPipeline: MTLRenderPipelineState
    private let skyPipeline: MTLRenderPipelineState
    private let starPipeline: MTLRenderPipelineState
    private let fieldPipeline: MTLComputePipelineState
    private let fieldTexture: MTLTexture
    private let starBuffer: MTLBuffer
    private let starCount: Int
    private var lastCamera = OrbitCamera()
    private let fixedFPS: Int
    private let depthWrite: MTLDepthStencilState
    private let depthSky: MTLDepthStencilState
    private let depthNone: MTLDepthStencilState
    private let sampler: MTLSamplerState
    private let globeMesh: SphereMesh
    private let moonMesh: SphereMesh
    private let atlasTexture: MTLTexture
    private let landTexture: MTLTexture
    private var stationBuffer: MTLBuffer?
    private var stationCount = 0

    let model: GlobeModel
    var camera = OrbitCamera()
    private var lastFrame: CFTimeInterval?
    private var benchmark: GlobeBenchmark?
    private var lastDrawn: (time: Date, camera: OrbitCamera, size: CGSize, key: String)?

    init?(view: MTKView, model: GlobeModel, atlas: TideAtlas, land: LandMask) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        self.device = device
        self.queue = queue
        self.model = model
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        // Depth only lives in tile memory on Apple GPUs; never stored.
        view.depthStencilStorageMode = .memoryless
        let defaults = UserDefaults.standard
        let msaa = defaults.integer(forKey: "GlobeMSAA")
        view.sampleCount = [1, 2, 4].contains(msaa) ? msaa : 4
        view.clearColor = MTLClearColor(red: 0.01, green: 0.022, blue: 0.032, alpha: 1)
        fixedFPS = defaults.integer(forKey: "GlobeFPS")
        view.preferredFramesPerSecond = fixedFPS > 0 ? fixedFPS : 60
        if GlobeBenchmark.isEnabled {
            benchmark = GlobeBenchmark(config: "MSAA \(view.sampleCount)× · \(view.preferredFramesPerSecond) fps cap · scale \(defaults.double(forKey: "GlobeScale") > 0 ? defaults.double(forKey: "GlobeScale") : Double(UIScreen.main.scale))× · \(UIDevice.current.model)")
        }

        func pipeline(_ v: String, _ f: String, blend: Bool = false, additive: Bool = false) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: v)
            d.fragmentFunction = library.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = view.colorPixelFormat
            d.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            d.rasterSampleCount = view.sampleCount
            if blend {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            if additive {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one
                c.destinationRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .zero
                c.destinationAlphaBlendFactor = .one
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let g = pipeline("globe_vertex", "globe_fragment"),
              let b = pipeline("body_vertex", "body_fragment"),
              let p = pipeline("point_vertex", "point_fragment", blend: true),
              let s = pipeline("sky_vertex", "sky_fragment"),
              let st = pipeline("star_vertex", "star_fragment", additive: true),
              let kernel = library.makeFunction(name: "tide_field"),
              let fp = try? device.makeComputePipelineState(function: kernel) else { return nil }
        globePipeline = g; bodyPipeline = b; pointPipeline = p; skyPipeline = s; starPipeline = st; fieldPipeline = fp

        func depth(_ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState? {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)
        }
        guard let dw = depth(.less, write: true), let ds = depth(.lessEqual, write: false), let dn = depth(.always, write: false) else { return nil }
        depthWrite = dw; depthSky = ds; depthNone = dn

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .repeat
        sd.tAddressMode = .clampToEdge
        guard let smp = device.makeSamplerState(descriptor: sd),
              let gm = SphereMesh(device: device, columns: 540, rows: 270),
              let mm = SphereMesh(device: device, columns: 48, rows: 24),
              let at = Self.makeAtlasTexture(device: device, atlas: atlas),
              let lt = Self.makeLandTexture(device: device, land: land),
              let ft = Self.makeFieldTexture(device: device, atlas: atlas),
              let sb = Self.makeStars(device: device) else { return nil }
        sampler = smp; globeMesh = gm; moonMesh = mm; atlasTexture = at; landTexture = lt
        fieldTexture = ft; starBuffer = sb.buffer; starCount = sb.count
        super.init()
        camera.latitude = model.initialFocus.latitude
        camera.longitude = model.initialFocus.longitude
    }

    static func makeAtlasTexture(device: MTLDevice, atlas: TideAtlas) -> MTLTexture? {
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.pixelFormat = .rg16Float
        d.width = atlas.longitudeCount
        d.height = atlas.latitudeCount
        d.arrayLength = min(atlas.constituents.count, maxConstituents)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        for i in 0..<d.arrayLength {
            let data = atlas.halfFloatGrid(i)
            data.withUnsafeBytes { raw in
                t.replace(region: MTLRegionMake2D(0, 0, d.width, d.height), mipmapLevel: 0, slice: i,
                          withBytes: raw.baseAddress!, bytesPerRow: d.width * 4, bytesPerImage: data.count)
            }
        }
        return t
    }

    /// The tide evaluated per atlas cell each frame: (η, dη/dt, Σ amplitude, mean speed).
    static func makeFieldTexture(device: MTLDevice, atlas: TideAtlas) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: atlas.longitudeCount, height: atlas.latitudeCount, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    /// A fixed, seeded star field: directions in the sky frame and a brightness.
    static func makeStars(device: MTLDevice, count: Int = 4_500) -> (buffer: MTLBuffer, count: Int)? {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func rand() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(seed >> 40) / Float(1 << 24)
        }
        var stars: [SIMD4<Float>] = []
        stars.reserveCapacity(count)
        for _ in 0..<count {
            let z = rand() * 2 - 1, th = rand() * 2 * .pi, r = (1 - z * z).squareRoot()
            let mag = pow(rand(), 4) // most stars faint, a few bright
            stars.append(SIMD4(r * cos(th), z, r * sin(th), mag))
        }
        guard let b = device.makeBuffer(bytes: stars, length: stars.count * MemoryLayout<SIMD4<Float>>.stride) else { return nil }
        return (b, count)
    }

    static func makeLandTexture(device: MTLDevice, land: LandMask) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: land.width, height: land.height, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        land.pixels.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake2D(0, 0, land.width, land.height), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: land.width)
        }
        return t
    }

    func setStations(_ coords: [(latitude: Double, longitude: Double)]) {
        let pts = coords.map { c -> SIMD4<Float> in
            let v = Self.unit(latitude: c.latitude, longitude: c.longitude)
            return SIMD4(v, 1)
        }
        stationCount = pts.count
        stationBuffer = pts.isEmpty ? nil : device.makeBuffer(bytes: pts, length: pts.count * MemoryLayout<SIMD4<Float>>.stride)
        lastDrawn = nil
    }

    /// Earth-fixed unit vector.
    nonisolated static func unit(latitude: Double, longitude: Double) -> SIMD3<Float> {
        let la = latitude * .pi / 180, lo = longitude * .pi / 180
        return SIMD3(Float(cos(la) * cos(lo)), Float(sin(la)), Float(-cos(la) * sin(lo)))
    }

    nonisolated static func latLon(_ v: SIMD3<Float>) -> (latitude: Double, longitude: Double) {
        let n = simd_normalize(v)
        return (Double(asin(max(-1, min(1, n.y)))) * 180 / .pi, Double(atan2(-n.z, n.x)) * 180 / .pi)
    }

    // MARK: Picking

    func viewProjection(size: CGSize) -> simd_float4x4 {
        let aspect = Float(max(size.width, 1) / max(size.height, 1))
        return camera.projection(aspect: aspect) * camera.view()
    }

    /// The point on the globe under a view location (points), if any.
    func pick(_ point: CGPoint, in size: CGSize) -> (latitude: Double, longitude: Double)? {
        let inv = viewProjection(size: size).inverse
        let ndc = SIMD2<Float>(Float(point.x / size.width) * 2 - 1, 1 - Float(point.y / size.height) * 2)
        let far = inv * SIMD4(ndc.x, ndc.y, 1, 1)
        let eye = camera.eye
        let dir = simd_normalize(SIMD3(far.x, far.y, far.z) / far.w - eye)
        let b = simd_dot(eye, dir), c = simd_dot(eye, eye) - 1
        let disc = b * b - c
        guard disc >= 0 else { return nil }
        let t = -b - disc.squareRoot()
        guard t > 0 else { return nil }
        return Self.latLon(eye + dir * t)
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { lastDrawn = nil }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let raw: Double = lastFrame.map { now - $0 } ?? 1.0 / 60
        let dt: Double = min(max(raw, 1.0 / 240), 1.0 / 15)
        lastFrame = now
        benchmark?.step(model: model, camera: &camera, now: now, dt: dt)
        model.advance(dt)
        if let fly = model.flyRequest {
            model.flyRequest = nil
            camera.fly(to: fly.latitude, fly.longitude)
        }
        camera.step(dt)

        let key = "\(model.selection ?? "*")|\(model.relief)|\(stationCount)|\(model.showsStations)|\(model.probe?.id.uuidString ?? "-")"
        // Draw fast while the camera moves, at 30 fps for playback alone.
        let moving = camera != lastCamera || camera.velocity != .zero || camera.target != nil
        lastCamera = camera
        if fixedFPS == 0 {
            let want = moving ? 60 : 30
            if view.preferredFramesPerSecond != want { view.preferredFramesPerSecond = want }
        }

        if let last = lastDrawn, last.time == model.liveTime, last.camera == camera, last.size == view.bounds.size, last.key == key {
            return // nothing moved: keep the last frame, spend no power
        }
        lastDrawn = (model.liveTime, camera, view.bounds.size, key)

        let beforeDrawable = CACurrentMediaTime()
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }

        let afterDrawable = CACurrentMediaTime()
        let date = model.liveTime
        let vp = viewProjection(size: view.bounds.size)
        var U = GlobeUniforms()
        U.viewProj = vp
        U.invViewProj = vp.inverse
        U.cameraPos = SIMD4(camera.eye, 1)
        let sun = Ephemeris.sun(date).subpoint(at: date)
        let moonPos = Ephemeris.moon(date)
        let moon = moonPos.subpoint(at: date)
        let sunDir = Self.unit(latitude: sun.latitude, longitude: sun.longitude)
        let moonDir = Self.unit(latitude: moon.latitude, longitude: moon.longitude)
        U.sunDir = SIMD4(sunDir, 0)
        U.moonDir = SIMD4(moonDir, 0)
        if let p = model.probe {
            U.probe = SIMD4(Self.unit(latitude: p.latitude, longitude: p.longitude), 1)
        }
        let ph = model.atlas?.phasors(at: date) ?? []
        let cons = model.atlas?.constituents ?? []
        var list = [SIMD4<Float>](repeating: .zero, count: Self.maxConstituents)
        var selectedIndex: Float = -1
        for i in 0..<min(ph.count, Self.maxConstituents) {
            let on = model.selection == nil || model.selection == cons[i].name
            if model.selection == cons[i].name { selectedIndex = Float(i) }
            list[i] = SIMD4(Float(ph[i].cos), Float(ph[i].sin), Float(cons[i].speed * .pi / 180), on ? 1 : 0)
        }
        U.phasors = (list[0], list[1], list[2], list[3], list[4], list[5], list[6], list[7])
        let gst = Ephemeris.greenwichSiderealTime(date) * .pi / 180
        U.params = SIMD4(model.relief ? Self.reliefScale : 0, Self.colourScale, selectedIndex, Float(gst))
        let scale = Float(view.contentScaleFactor)
        U.params2 = SIMD4(Float(min(max(2.5, 7 - camera.distance), 5)) * scale * 0.75, Float(view.drawableSize.width), Float(view.drawableSize.height), 0.62)
        if let a = model.atlas {
            U.grid = SIMD4(Float(a.longitudeStart), Float(a.longitudeStep), Float(a.latitudeStart), Float(a.latitudeStep))
            U.gridN = SIMD4(Float(a.longitudeCount), Float(a.latitudeCount), Float(min(a.constituents.count, Self.maxConstituents)), scale)
        }

        // The tide, once per atlas cell.
        if let ce = cmd.makeComputeCommandEncoder() {
            ce.setComputePipelineState(fieldPipeline)
            ce.setTexture(atlasTexture, index: 0)
            ce.setTexture(fieldTexture, index: 1)
            ce.setBytes(&U, length: MemoryLayout<GlobeUniforms>.stride, index: 1)
            ce.dispatchThreads(MTLSize(width: fieldTexture.width, height: fieldTexture.height, depth: 1),
                               threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            ce.endEncoding()
        }
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        // Globe
        enc.setRenderPipelineState(globePipeline)
        enc.setDepthStencilState(depthWrite)
        enc.setCullMode(.back)
        enc.setFrontFacing(.counterClockwise)
        enc.setVertexBuffer(globeMesh.vertices, offset: 0, index: 0)
        enc.setVertexBytes(&U, length: MemoryLayout<GlobeUniforms>.stride, index: 1)
        enc.setFragmentBytes(&U, length: MemoryLayout<GlobeUniforms>.stride, index: 1)
        enc.setVertexTexture(atlasTexture, index: 0)
        enc.setVertexTexture(landTexture, index: 1)
        enc.setVertexTexture(fieldTexture, index: 2)
        enc.setFragmentTexture(atlasTexture, index: 0)
        enc.setFragmentTexture(landTexture, index: 1)
        enc.setFragmentTexture(fieldTexture, index: 2)
        enc.setVertexSamplerState(sampler, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: globeMesh.indexCount, indexType: .uint32, indexBuffer: globeMesh.indices, indexBufferOffset: 0)

        // Moon, lit by the Sun, so its phase is right.
        let km = Float(moonPos.distance / Ephemeris.meanLunarDistance)
        var B = BodyUniforms()
        B.viewProj = vp
        B.model = float4x4(translation: moonDir * Self.moonDistance * km) * float4x4(scale: 0.273)
        B.sunDir = SIMD4(sunDir, 0)
        B.color = SIMD4(0.80, 0.78, 0.74, 1)
        enc.setRenderPipelineState(bodyPipeline)
        enc.setVertexBuffer(moonMesh.vertices, offset: 0, index: 0)
        enc.setVertexBytes(&B, length: MemoryLayout<BodyUniforms>.stride, index: 1)
        enc.setFragmentBytes(&B, length: MemoryLayout<BodyUniforms>.stride, index: 1)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: moonMesh.indexCount, indexType: .uint32, indexBuffer: moonMesh.indices, indexBufferOffset: 0)

        // Stations
        if model.showsStations, let buf = stationBuffer, stationCount > 0 {
            enc.setRenderPipelineState(pointPipeline)
            enc.setDepthStencilState(depthNone)
            enc.setCullMode(.none)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&U, length: MemoryLayout<GlobeUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: stationCount)
        }

        // Sky last, only where nothing else drew.
        enc.setRenderPipelineState(skyPipeline)
        enc.setDepthStencilState(depthSky)
        enc.setCullMode(.none)
        enc.setFragmentBytes(&U, length: MemoryLayout<GlobeUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // Stars, added over the sky only (the globe's depth hides the rest).
        enc.setRenderPipelineState(starPipeline)
        enc.setVertexBuffer(starBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&U, length: MemoryLayout<GlobeUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: starCount)

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
}

// MARK: - Camera

/// Orbits the Earth in the Earth-fixed frame. Latitude and longitude name
/// the point at the centre of the view.
struct OrbitCamera: Equatable {
    var latitude: Double = 30
    var longitude: Double = -45
    var distance: Double = 3.4
    /// Spin after a fling, degrees per second.
    var velocity = SIMD2<Double>(0, 0)
    /// Animated flight to a point.
    var target: (latitude: Double, longitude: Double, distance: Double)?

    static let minDistance = 1.3, maxDistance = 9.0
    static let fieldOfView: Float = 34 * .pi / 180

    static func == (a: OrbitCamera, b: OrbitCamera) -> Bool {
        a.latitude == b.latitude && a.longitude == b.longitude && a.distance == b.distance
    }

    var eye: SIMD3<Float> { GlobeRenderer.unit(latitude: latitude, longitude: longitude) * Float(distance) }

    /// Degrees of rotation per point dragged.
    var degreesPerPoint: Double { 0.12 * (distance - 1) }

    mutating func drag(by d: CGSize) {
        target = nil
        longitude -= d.width * degreesPerPoint / max(cos(latitude * .pi / 180), 0.25)
        latitude = min(max(latitude + d.height * degreesPerPoint, -85), 85)
        wrap()
    }

    mutating func fling(_ v: CGPoint) {
        velocity = SIMD2(-v.x * degreesPerPoint / max(cos(latitude * .pi / 180), 0.25), v.y * degreesPerPoint)
    }

    mutating func zoom(to d: Double) { target = nil; distance = min(max(d, Self.minDistance), Self.maxDistance) }

    mutating func fly(to latitude: Double, _ longitude: Double, distance: Double? = nil) {
        velocity = .zero
        target = (min(max(latitude, -85), 85), longitude, distance ?? self.distance)
    }

    mutating func step(_ dt: Double) {
        if let t = target {
            let k = 1 - exp(-dt * 5)
            var dLon = (t.longitude - longitude).truncatingRemainder(dividingBy: 360)
            if dLon > 180 { dLon -= 360 } else if dLon < -180 { dLon += 360 }
            latitude += (t.latitude - latitude) * k
            longitude += dLon * k
            distance += (t.distance - distance) * k
            if abs(t.latitude - latitude) < 0.01 && abs(dLon) < 0.01 && abs(t.distance - distance) < 0.001 {
                latitude = t.latitude; longitude = t.longitude; distance = t.distance; target = nil
            }
            wrap()
            return
        }
        guard velocity != .zero else { return }
        longitude += velocity.x * dt
        latitude = min(max(latitude + velocity.y * dt, -85), 85)
        velocity *= exp(-dt * 3.5)
        if abs(velocity.x) < 0.05 && abs(velocity.y) < 0.05 { velocity = .zero }
        wrap()
    }

    private mutating func wrap() {
        if longitude > 180 { longitude -= 360 } else if longitude < -180 { longitude += 360 }
    }

    func view() -> simd_float4x4 { .lookAt(eye: eye, center: .zero, up: SIMD3(0, 1, 0)) }

    func projection(aspect: Float) -> simd_float4x4 {
        // Widen the view on narrow screens so the whole Earth fits.
        let fovy = aspect < 1 ? 2 * atan(tan(Self.fieldOfView / 2) / aspect) : Self.fieldOfView
        return .perspective(fovy: fovy, aspect: aspect, near: 0.02, far: 100)
    }
}

// MARK: - Mesh and maths

struct SphereMesh {
    let vertices: MTLBuffer
    let indices: MTLBuffer
    let indexCount: Int

    init?(device: MTLDevice, columns: Int, rows: Int) {
        var v: [SIMD4<Float>] = []
        v.reserveCapacity((columns + 1) * (rows + 1))
        for r in 0...rows {
            let lat = -90 + 180 * Double(r) / Double(rows)
            for c in 0...columns {
                let lon = -180 + 360 * Double(c) / Double(columns)
                v.append(SIMD4(GlobeRenderer.unit(latitude: lat, longitude: lon), 1))
            }
        }
        var idx: [UInt32] = []
        idx.reserveCapacity(columns * rows * 6)
        let w = UInt32(columns + 1)
        for r in 0..<UInt32(rows) {
            for c in 0..<UInt32(columns) {
                let a = r * w + c, b = a + 1, d = a + w, e = d + 1
                // Counter-clockwise seen from outside.
                idx += [a, b, d, b, e, d]
            }
        }
        guard let vb = device.makeBuffer(bytes: v, length: v.count * MemoryLayout<SIMD4<Float>>.stride),
              let ib = device.makeBuffer(bytes: idx, length: idx.count * MemoryLayout<UInt32>.stride) else { return nil }
        vertices = vb; indices = ib; indexCount = idx.count
    }
}

extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(t, 1)
    }

    init(scale s: Float) {
        self = simd_float4x4(diagonal: SIMD4(s, s, s, 1))
    }

    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(center - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (
            SIMD4(s.x, u.x, -f.x, 0),
            SIMD4(s.y, u.y, -f.y, 0),
            SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }

    /// Right-handed perspective with Metal's 0...1 depth.
    static func perspective(fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovy / 2), x = y / aspect, z = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, z, -1),
            SIMD4(0, 0, z * near, 0)))
    }
}
