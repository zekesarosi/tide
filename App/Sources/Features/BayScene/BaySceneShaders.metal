#include <metal_stdlib>
using namespace metal;

// The San Francisco Bay scene. World space is local metres around the bay
// centre: +x east, +y north, +z up. Keep in step with `BayUniforms` in
// BaySceneRenderer.swift.
struct BayUniforms {
    float4x4 viewProj;
    float4x4 invViewProj;
    float4 cameraPos;   // xyz eye (m)
    float4 sunDir;      // xyz unit, towards the Sun; w daylight 0...1
    float4 scale;       // x depth exaggeration, y water-level exaggeration, z land top (world m), w ground lift for overlays (m)
    float4 colour;      // x mode (0 level, 1 speed, 2 depth), y level scale (m), z speed scale (m/s), w seconds (shimmer)
    float4 bounds;      // x minX, y minY, z width, w height (m), of the flow and land textures
    float4 viewport;    // x width px, y height px, z trail width px, w fog distance (m)
    float4 flow;        // x drift seconds this step, y random seed, z real seconds this step, w 1 = reset all particles
    float4 eval;        // x node count, y constituents, z residual t, w residual on
    float4 eval2;       // x residual lower frame, y upper frame, z history head, w history length
    float4 probe;       // xy probe (m), z probe on, w camera distance (m)
    float4 base;        // x minX, y minY, z width, w height (m), of the base map
    float4 motion;      // x chance (0...1) that each particle respawns into the view this frame, as the camera moves
};

constant float3 kBackground = float3(0.016, 0.031, 0.043);
/// Water beyond the model: calm and dim.
constant float3 kOcean = float3(0.075, 0.150, 0.200);
constant float3 kLand = float3(0.204, 0.235, 0.251);

/// Distance (m) inside the model's box; negative outside.
static float boxDistance(float2 p, constant BayUniforms &U) {
    float2 lo = p - U.bounds.xy, hi = U.bounds.xy + U.bounds.zw - p;
    return min(min(lo.x, hi.x), min(lo.y, hi.y));
}

/// 1 well inside the model, 0 over its last ~2 km and beyond (wider when
/// zoomed far out), where the base map takes over, so the cut edge of the
/// mesh never shows.
static float modelWeight(float2 p, constant BayUniforms &U) {
    float band = clamp(U.probe.w * 0.06, 2000.0, 6000.0);
    return smoothstep(400.0, 400.0 + band, boxDistance(p, U));
}

/// The base map's ocean as lit (before fog); the model's water fades to exactly this.
static float3 oceanShade(float3 world, constant BayUniforms &U) {
    float3 v = normalize(U.cameraPos.xyz - world);
    float fres = pow(1 - max(v.z, 0.0), 4.0);
    return kOcean * (0.85 + 0.2 * U.sunDir.w) + fres * float3(0.06, 0.09, 0.11);
}

static float2 baseUV(float2 p, constant BayUniforms &U) {
    return float2((p.x - U.base.x) / U.base.z, 1.0 - (p.y - U.base.y) / U.base.w);
}

static float3 fogged(float3 c, float3 world, constant BayUniforms &U) {
    float d = distance(world, U.cameraPos.xyz);
    float f = smoothstep(U.viewport.w * 0.35, U.viewport.w, d);
    return mix(c, kBackground, f * 0.85);
}

static float2 flowUV(float2 p, constant BayUniforms &U) {
    return float2((p.x - U.bounds.x) / U.bounds.z, 1.0 - (p.y - U.bounds.y) / U.bounds.w);
}

// MARK: - Tide evaluation, once per node per frame

/// η − Z0, u and v at every node from the harmonic constants, the mean and,
/// when a live forecast is loaded, its residual blended between two hours.
/// Output: (η − Z0, u east, v north, speed).
kernel void bay_eval(device const half4 *mean   [[buffer(0)]],   // 2 per node: (Z0, dm u0, dm v0, sf u0), (sf v0, 0, 0, 0)
                     device const half2 *zeta   [[buffer(1)]],   // K × N
                     device const half4 *cur    [[buffer(2)]],   // K × N: (u re, u im, v re, v im), the chosen layer
                     device const half4 *res    [[buffer(3)]],   // F × N × 2, like `mean`
                     constant float2 *ph        [[buffer(4)]],   // K phasors (c, s)
                     constant BayUniforms &U    [[buffer(5)]],
                     device float4 *state       [[buffer(6)]],
                     constant uint &surface     [[buffer(7)]],
                     uint n [[thread_position_in_grid]]) {
    uint N = uint(U.eval.x);
    if (n >= N) return;
    int K = int(U.eval.y);
    float h = 0, u = 0, v = 0;
    for (int k = 0; k < K; k++) {
        float2 p = ph[k];
        float2 z = float2(zeta[uint(k) * N + n]);
        float4 c = float4(cur[uint(k) * N + n]);
        h += z.x * p.x + z.y * p.y;
        u += c.x * p.x + c.y * p.y;
        v += c.z * p.x + c.w * p.y;
    }
    float4 m0 = float4(mean[2 * n]), m1 = float4(mean[2 * n + 1]);
    float2 mf = surface != 0 ? float2(m0.w, m1.x) : m0.yz;
    u += mf.x; v += mf.y;
    if (U.eval.w > 0.5) {
        uint lo = uint(U.eval2.x), hi = uint(U.eval2.y);
        float t = U.eval.z;
        float4 a0 = float4(res[2 * (lo * N + n)]), a1 = float4(res[2 * (lo * N + n) + 1]);
        float4 b0 = float4(res[2 * (hi * N + n)]), b1 = float4(res[2 * (hi * N + n) + 1]);
        float4 r0 = mix(a0, b0, t), r1 = mix(a1, b1, t);
        h += r0.x;
        float2 rf = surface != 0 ? float2(r0.w, r1.x) : r0.yz;
        u += rf.x; v += rf.y;
    }
    state[n] = float4(h, u, v, length(float2(u, v)));
}

// MARK: - Flow and land textures (top-down, over the bounds)

struct FlatOut {
    float4 position [[position]];
    float4 value;
};

/// Node positions: (x, y, depth, 0).
vertex FlatOut flow_vertex(uint vid [[vertex_id]],
                           device const float4 *nodes [[buffer(0)]],
                           device const float4 *state [[buffer(1)]],
                           constant BayUniforms &U [[buffer(2)]]) {
    float4 p = nodes[vid];
    float4 s = state[vid];
    FlatOut o;
    float2 uv = (p.xy - U.bounds.xy) / U.bounds.zw;
    o.position = float4(uv * 2 - 1, 0, 1);
    o.value = float4(s.y, s.z, s.x, 1);
    return o;
}

fragment float4 flow_fragment(FlatOut in [[stage_in]]) { return in.value; }

fragment half mask_fragment(FlatOut in [[stage_in]]) { return 1; }

// MARK: - Seafloor

struct FloorOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float depth;
};

vertex FloorOut floor_vertex(uint vid [[vertex_id]],
                             device const float4 *nodes [[buffer(0)]],
                             device const float2 *grad [[buffer(1)]],
                             constant BayUniforms &U [[buffer(2)]]) {
    float4 p = nodes[vid];
    float2 g = grad[vid];
    FloorOut o;
    o.world = float3(p.xy, -p.z * U.scale.x);
    o.position = U.viewProj * float4(o.world, 1);
    o.normal = normalize(float3(g * U.scale.x, 1));
    o.depth = p.z;
    return o;
}

static float3 bathyColour(float d) {
    // Sand on the flats, teal shoals, blue channels, deep indigo in the Gate.
    const float3 c0 = float3(0.58, 0.55, 0.42), c1 = float3(0.30, 0.50, 0.47), c2 = float3(0.13, 0.36, 0.50);
    const float3 c3 = float3(0.06, 0.17, 0.36), c4 = float3(0.05, 0.06, 0.20);
    if (d < 2.0) return c0;
    if (d < 8.0) return mix(c0, c1, (d - 2.0) / 6.0);
    if (d < 20.0) return mix(c1, c2, (d - 8.0) / 12.0);
    if (d < 50.0) return mix(c2, c3, (d - 20.0) / 30.0);
    return mix(c3, c4, saturate((d - 50.0) / 60.0));
}

fragment float4 floor_fragment(FloorOut in [[stage_in]], constant BayUniforms &U [[buffer(2)]]) {
    float3 n = normalize(in.normal);
    float3 l = U.sunDir.xyz;
    float diffuse = max(dot(n, l), 0.0);
    float3 c = bathyColour(in.depth);
    float light = 0.55 + 0.65 * diffuse * mix(0.6, 1.0, U.sunDir.w);
    c *= light;
    // Depth contours every 5 m (every 20 m drawn stronger).
    float d = in.depth;
    float w = max(fwidth(d), 1e-4);
    float c5 = 1 - smoothstep(0.0, 1.2, abs(fract(d / 5.0 + 0.5) - 0.5) * 5.0 / w);
    float c20 = 1 - smoothstep(0.0, 1.4, abs(fract(d / 20.0 + 0.5) - 0.5) * 20.0 / w);
    c += float3(0.05, 0.09, 0.10) * (0.5 * c5 + c20) * step(0.5, d);
    return float4(fogged(c, in.world, U), 1);
}

// MARK: - Water surface

struct WaterOut {
    float4 position [[position]];
    float3 world;
    float eta;
    float speed;
    float column;
    float2 vel;
};

vertex WaterOut water_vertex(uint vid [[vertex_id]],
                             device const float4 *nodes [[buffer(0)]],
                             device const float4 *state [[buffer(1)]],
                             constant BayUniforms &U [[buffer(2)]]) {
    float4 p = nodes[vid];
    float4 s = state[vid];
    WaterOut o;
    o.world = float3(p.xy, s.x * U.scale.y);
    o.position = U.viewProj * float4(o.world, 1);
    o.eta = s.x;
    o.speed = s.w;
    o.column = p.z + s.x;
    o.vel = s.yz;
    return o;
}

/// Blue below mean sea level through to amber above, as on the Tide Globe.
static float3 levelColour(float x) {
    float3 lo2 = float3(0.42, 0.70, 0.95), lo1 = float3(0.16, 0.42, 0.72), mid = float3(0.05, 0.16, 0.24);
    float3 hi1 = float3(0.92, 0.56, 0.30), hi2 = float3(1.0, 0.86, 0.66);
    x = clamp(x, -1.0, 1.0);
    if (x < 0) return x < -0.5 ? mix(lo1, lo2, (-x - 0.5) * 2) : mix(mid, lo1, -x * 2);
    return x > 0.5 ? mix(hi1, hi2, (x - 0.5) * 2) : mix(mid, hi1, x * 2);
}

/// Current speed: still water dark teal, through harbor blue, to pale gold.
static float3 speedColour(float x) {
    x = clamp(x, 0.0, 1.0);
    float3 a = float3(0.04, 0.12, 0.17), b = float3(0.12, 0.42, 0.62), c = float3(0.44, 0.75, 0.86), d = float3(1.0, 0.86, 0.55);
    if (x < 0.35) return mix(a, b, x / 0.35);
    if (x < 0.7) return mix(b, c, (x - 0.35) / 0.35);
    return mix(c, d, (x - 0.7) / 0.3);
}

fragment float4 water_fragment(WaterOut in [[stage_in]], constant BayUniforms &U [[buffer(2)]]) {
    int mode = int(U.colour.x + 0.5);
    float3 c = mode == 0 ? levelColour(in.eta / U.colour.y) : mode == 1 ? speedColour(in.speed / U.colour.z) : float3(0.03, 0.08, 0.11);
    float3 v = normalize(U.cameraPos.xyz - in.world);
    // A faint moving ripple for the Sun's glint; the water is otherwise flat.
    float2 q = in.world.xy / 37.0;
    float t = U.colour.w;
    float3 n = normalize(float3(0.04 * sin(q.x * 1.7 + t * 0.9) + 0.03 * sin(q.y * 2.3 - t * 0.7),
                                0.04 * cos(q.y * 1.9 + t * 0.8) + 0.03 * cos(q.x * 2.1 - t * 1.1), 1));
    float3 l = U.sunDir.xyz;
    float spec = pow(max(dot(reflect(-l, n), v), 0.0), 60.0) * 0.35 * U.sunDir.w;
    float fres = pow(1 - max(v.z, 0.0), 4.0);
    c = c * (0.85 + 0.2 * U.sunDir.w) + spec + fres * float3(0.10, 0.16, 0.20);
    // Translucent, so the seafloor reads through it: more so in Depth mode.
    float k = 1 - exp(-max(in.column, 0.0) / 25.0);
    float a = mode == 2 ? 0.12 + 0.18 * k : mode == 0 ? 0.42 + 0.3 * k : 0.55 + 0.3 * k;
    a = in.column < 0.05 ? 0.0 : a;
    // Over the last ~2 km before the box edge, become the base map's ocean.
    float w = modelWeight(in.world.xy, U);
    c = mix(oceanShade(in.world, U), c, w);
    a = mix(1.0, a, w);
    c = fogged(c, in.world, U);
    return float4(c * a, a);
}

// MARK: - Land and coast

struct LandOut {
    float4 position [[position]];
    float3 world;
};

/// A plane 300 km round the bay, at height `z`.
vertex LandOut plane_vertex(uint vid [[vertex_id]], constant BayUniforms &U [[buffer(2)]], constant float &z [[buffer(3)]]) {
    float2 corner = float2((vid == 1 || vid == 2 || vid == 4) ? 1 : -1, (vid == 2 || vid == 4 || vid == 5) ? 1 : -1);
    float2 centre = U.bounds.xy + U.bounds.zw * 0.5;
    LandOut o;
    o.world = float3(centre + corner * 300000.0, z);
    o.position = U.viewProj * float4(o.world, 1);
    return o;
}

/// Land coverage 0...1: the mesh inside the box (anything that isn't model
/// water is land), Natural Earth outside it, blended across the box edge.
static float landCover(float2 p, constant BayUniforms &U, texture2d<float> mask, texture2d<float> base, sampler s) {
    float b = base.sample(s, baseUV(p, U)).r;
    float w = modelWeight(p, U);
    if (w <= 0.0) return b;
    float m = 1.0 - mask.sample(s, flowUV(p, U)).r;
    return mix(b, m, w);
}

fragment float4 land_fragment(LandOut in [[stage_in]], constant BayUniforms &U [[buffer(2)]],
                              texture2d<float> mask [[texture(0)]], texture2d<float> base [[texture(1)]], sampler s [[sampler(0)]]) {
    float L = landCover(in.world.xy, U, mask, base, s);
    if (L < 0.5) discard_fragment();
    // A hairline along the coast, about a pixel wide whatever the zoom.
    float edge = 1 - smoothstep(0.0, 1.5, (L - 0.5) / max(fwidth(L), 1e-4));
    float3 c = kLand * (0.82 + 0.22 * U.sunDir.w);
    c = mix(c, float3(0.50, 0.60, 0.64), edge * 0.8);
    return float4(fogged(c, in.world, U), 1);
}

fragment float4 ocean_fragment(LandOut in [[stage_in]], constant BayUniforms &U [[buffer(2)]],
                               texture2d<float> mask [[texture(0)]], sampler s [[sampler(0)]]) {
    float2 uv = flowUV(in.world.xy, U);
    if (all(uv >= 0.0) && all(uv <= 1.0) && mask.sample(s, uv).r > 0.5) discard_fragment(); // the model's water
    return float4(fogged(oceanShade(in.world, U), in.world, U), 1);
}

struct WallVertex {
    float4 a; // x, y, node index, level (0 seafloor, 1 land top, 2 water surface, 3 floor of the block)
    float4 n; // xy normal, z kind (0 earth, 1 water), w unused
};

struct WallOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float kind;
    float eta;
};

vertex WallOut wall_vertex(uint vid [[vertex_id]],
                           device const WallVertex *walls [[buffer(0)]],
                           device const float4 *nodes [[buffer(1)]],
                           device const float4 *state [[buffer(3)]],
                           constant BayUniforms &U [[buffer(2)]]) {
    WallVertex w = walls[vid];
    uint node = uint(w.a.z);
    float level = w.a.w;
    float4 p = nodes[node];
    float4 s = state[node];
    float z;
    if (level < 0.5) z = -p.z * U.scale.x;
    else if (level < 1.5) z = U.scale.z;
    else if (level < 2.5) z = s.x * U.scale.y;
    else z = -p.z * U.scale.x - 40.0 * U.scale.x;
    WallOut o;
    o.world = float3(w.a.xy, z);
    o.position = U.viewProj * float4(o.world, 1);
    o.normal = float3(w.n.xy, 0);
    o.kind = w.n.z;
    o.eta = s.x;
    return o;
}

fragment float4 wall_fragment(WallOut in [[stage_in]], constant BayUniforms &U [[buffer(2)]]) {
    float3 n = normalize(in.normal);
    float diffuse = abs(dot(n, U.sunDir.xyz));
    if (in.kind > 0.5) {
        float3 c = U.colour.x < 0.5 ? levelColour(in.eta / U.colour.y) : float3(0.08, 0.26, 0.38);
        c = c * (0.6 + 0.3 * diffuse);
        return float4(fogged(c, in.world, U) * 0.7, 0.7);
    }
    // Earth in cross-section: banded, darker with depth.
    float z = in.world.z / max(U.scale.x, 1.0);
    float3 c = mix(float3(0.06, 0.065, 0.07), float3(0.15, 0.15, 0.14), smoothstep(-80.0, 0.0, z));
    c *= 0.65 + 0.45 * diffuse;
    return float4(fogged(c, in.world, U), 1);
}

// MARK: - Particles

struct Particle { float2 pos; float age; float life; };

static float hash(uint x) {
    x ^= x >> 16; x *= 0x7feb352dU; x ^= x >> 15; x *= 0x846ca68bU; x ^= x >> 16;
    return float(x) / 4294967295.0;
}

/// Where a ray through an NDC point meets the water plane, if it does.
static bool groundAt(float2 ndc, constant BayUniforms &U, thread float2 &out) {
    float4 a = U.invViewProj * float4(ndc, 0, 1);
    float4 b = U.invViewProj * float4(ndc, 1, 1);
    float3 p0 = a.xyz / a.w, p1 = b.xyz / b.w;
    float3 d = p1 - p0;
    if (abs(d.z) < 1e-6) return false;
    float t = -p0.z / d.z;
    if (t <= 0 || t > 1) return false;
    out = (p0 + d * t).xy;
    return true;
}

static bool onScreen(float2 p, constant BayUniforms &U) {
    float4 c = U.viewProj * float4(p, 0, 1);
    if (c.w <= 0) return false;
    float2 ndc = c.xy / c.w;
    return all(abs(ndc) < 1.08);
}

/// Advects the particles one step through the flow texture (midpoint rule)
/// and records each one's position (x, y, z, speed) in its trail ring.
/// Speed −1 marks a break in the trail.
kernel void bay_particles(device Particle *particles [[buffer(0)]],
                          device float4 *history [[buffer(1)]],
                          constant BayUniforms &U [[buffer(2)]],
                          texture2d<float> flow [[texture(0)]],
                          sampler s [[sampler(0)]],
                          uint i [[thread_position_in_grid]],
                          uint count [[threads_per_grid]]) {
    Particle p = particles[i];
    uint H = uint(U.eval2.w);
    uint head = uint(U.eval2.z);
    float dt = U.flow.x;
    bool respawn = U.flow.w > 0.5 || p.age >= p.life
        || (U.motion.x > 0 && hash(i * 7349u + uint(U.flow.y) * 13u + 3u) < U.motion.x);
    float4 f = float4(0);
    if (!respawn) {
        f = flow.sample(s, flowUV(p.pos, U), level(0));
        if (f.a < 0.5) respawn = true;
    }
    if (!respawn && dt > 0) {
        float2 mid = p.pos + f.xy * dt * 0.5;
        float4 fm = flow.sample(s, flowUV(mid, U), level(0));
        if (fm.a >= 0.5) f = fm;
        float2 next = p.pos + f.xy * dt;
        float4 fn = flow.sample(s, flowUV(next, U), level(0));
        if (fn.a < 0.5 || !onScreen(next, U)) respawn = true;
        else { p.pos = next; f = fn; }
    }
    uint base = i * H;
    if (respawn) {
        uint seed = i * 9781u + uint(U.flow.y);
        bool ok = false;
        for (uint tries = 0; tries < 3 && !ok; tries++) {
            float2 ndc = float2(hash(seed + tries * 7919u), hash(seed * 31u + tries * 104729u + 1u)) * 2.0 - 1.0;
            float2 g;
            if (groundAt(ndc, U, g)) {
                float4 fg = flow.sample(s, flowUV(g, U), level(0));
                // Fewer trails where the water is slow, and towards the horizon.
                float keep = mix(0.07, 1.0, smoothstep(0.08, 0.9, length(fg.xy)));
                float far = distance(float3(g, 0), U.cameraPos.xyz) / max(U.probe.w, 1.0);
                keep *= 1.0 / max(1.0, (far / 1.6) * (far / 1.6));
                keep *= step(0.01, modelWeight(g, U));
                if (fg.a >= 0.5 && hash(seed * 7u + tries * 13u + 5u) < keep) { p.pos = g; f = fg; ok = true; }
            }
        }
        // Respawns while the view moves skip most of the fade-in, so new
        // ground fills promptly instead of slowly "loading".
        p.age = U.flow.w > 0.5 ? hash(seed ^ 0xA5A5u) * 4.0 : (U.motion.x > 0 ? 0.45 : 0.0);
        p.life = 2.5 + hash(seed ^ 0x5A5Au) * 3.5;
        float4 mark = float4(p.pos, f.z * U.scale.y, ok ? -1.0 : -2.0);
        for (uint k = 0; k < H; k++) history[base + k] = mark;
        if (!ok) p.age = p.life; // try again next frame
    } else {
        p.age += U.flow.z;
        history[base + head] = float4(p.pos, f.z * U.scale.y, length(f.xy));
    }
    particles[i] = p;
}

struct TrailOut {
    float4 position [[position]];
    float4 colour;
};

static float3 trailColour(float x) {
    x = clamp(x, 0.0, 1.0);
    float3 a = float3(0.55, 0.78, 0.92), b = float3(0.92, 0.97, 1.0), c = float3(1.0, 0.84, 0.50);
    return x < 0.5 ? mix(a, b, x * 2) : mix(b, c, (x - 0.5) * 2);
}

/// One instance per particle; six vertices per trail segment.
vertex TrailOut trail_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                             device const Particle *particles [[buffer(0)]],
                             device const float4 *history [[buffer(1)]],
                             constant BayUniforms &U [[buffer(2)]]) {
    uint H = uint(U.eval2.w);
    uint head = uint(U.eval2.z);
    uint seg = vid / 6, corner = vid % 6;
    uint s0 = (head + H - seg) % H, s1 = (head + H - seg - 1) % H;
    float4 a = history[iid * H + s0], b = history[iid * H + s1];
    TrailOut o;
    o.colour = float4(0);
    if (a.w < 0 || b.w < 0) { o.position = float4(2, 2, 2, 1); return o; }
    float lift = U.scale.w;
    float4 ca = U.viewProj * float4(a.xy, a.z + lift, 1);
    float4 cb = U.viewProj * float4(b.xy, b.z + lift, 1);
    if (ca.w <= 0 || cb.w <= 0) { o.position = float4(2, 2, 2, 1); return o; }
    float2 vp = U.viewport.xy;
    float2 sa = ca.xy / ca.w * vp * 0.5, sb = cb.xy / cb.w * vp * 0.5;
    float2 d = sa - sb;
    float len = length(d);
    float2 dir = len > 1e-3 ? d / len : float2(1, 0);
    float2 nrm = float2(-dir.y, dir.x);
    float t0 = float(seg) / float(H - 1), t1 = float(seg + 1) / float(H - 1);
    // Taper: wide and bright at the head, thin and faint at the tail.
    float w0 = U.viewport.z * (1.0 - 0.6 * t0), w1 = U.viewport.z * (1.0 - 0.6 * t1);
    bool atB = corner == 1 || corner == 2 || corner == 4;
    bool side = corner == 0 || corner == 1 || corner == 3;
    float2 sp = atB ? sb : sa;
    float w = atB ? w1 : w0;
    sp += nrm * (side ? 0.5 : -0.5) * w;
    // Extend the head a touch so slow particles still show as a dot.
    if (seg == 0 && !atB) sp += dir * 0.5 * U.viewport.z;
    float4 cp = atB ? cb : ca;
    o.position = float4(sp / (vp * 0.5) * cp.w, cp.z, cp.w);
    Particle p = particles[iid];
    float fade = smoothstep(0.0, 0.6, p.age) * (1 - smoothstep(p.life - 0.8, p.life, p.age));
    float speed = atB ? b.w : a.w;
    float x = speed / U.colour.z;
    float alpha = 0.62 * (1 - (atB ? t1 : t0)) * fade * mix(0.25, 1.0, smoothstep(0.0, 0.3, x));
    // Out over the box edge, and far towards the horizon, the trails fade away.
    float far = distance(a.xyz, U.cameraPos.xyz) / max(U.probe.w, 1.0);
    alpha *= modelWeight(a.xy, U) * (1 - smoothstep(1.4, 3.2, far));
    o.colour = float4(trailColour(x) * alpha, alpha);
    return o;
}

fragment float4 trail_fragment(TrailOut in [[stage_in]]) { return in.colour; }

// MARK: - Probe marker

struct RingOut {
    float4 position [[position]];
    float2 local;
};

vertex RingOut ring_vertex(uint vid [[vertex_id]], constant BayUniforms &U [[buffer(2)]],
                           constant float &radius [[buffer(3)]], constant float &z [[buffer(4)]]) {
    float2 corner = float2((vid == 1 || vid == 2 || vid == 4) ? 1 : -1, (vid == 2 || vid == 4 || vid == 5) ? 1 : -1);
    RingOut o;
    o.local = corner;
    o.position = U.viewProj * float4(U.probe.xy + corner * radius, z, 1);
    return o;
}

fragment float4 ring_fragment(RingOut in [[stage_in]]) {
    float r = length(in.local);
    float w = fwidth(r) * 1.5;
    float ring = smoothstep(0.78 - w, 0.78, r) * (1 - smoothstep(0.92, 0.92 + w, r));
    float dot = 1 - smoothstep(0.16, 0.16 + w, r);
    float a = max(ring, dot) * 0.95;
    return float4(float3(1.0, 0.72, 0.45) * a, a);
}
