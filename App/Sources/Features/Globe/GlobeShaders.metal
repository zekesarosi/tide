#include <metal_stdlib>
using namespace metal;

// Earth-fixed frame: +y is the north pole, longitude 0 is +x, 90°E is −z.
// Keep in step with `GlobeUniforms` in GlobeRenderer.swift.
struct GlobeUniforms {
    float4x4 viewProj;
    float4x4 invViewProj;
    float4 cameraPos;     // xyz
    float4 sunDir;        // xyz, unit
    float4 moonDir;       // xyz, unit
    float4 probe;         // xyz the tapped point, w 1 when shown
    float4 phasors[8];    // x f·cos(V+u), y f·sin(V+u), z speed (rad/h), w 1 = included
    float4 params;        // x relief (radius per metre), y colour scale (m), z selected constituent (−1 = all), w sidereal angle (rad)
    float4 params2;       // x point size (px), y viewport width, z viewport height, w night brightness
    float4 grid;          // x lon0, y dLon, z lat0, w dLat (degrees)
    float4 gridN;         // x nLon, y nLat, z nConstituents, w screen scale
};

struct BodyUniforms {
    float4x4 viewProj;
    float4x4 model;
    float4 sunDir;
    float4 color;
};

constant float PI = 3.14159265358979;

static float2 lonLatDegrees(float3 n) {
    float lon = atan2(-n.z, n.x) * 180.0 / PI;              // −180..180
    float lat = asin(clamp(n.y, -1.0, 1.0)) * 180.0 / PI;
    return float2(lon, lat);
}

static float2 atlasUV(float2 ll, constant GlobeUniforms &U) {
    float lon = ll.x < U.grid.x ? ll.x + 360.0 : ll.x;
    return float2(((lon - U.grid.x) / U.grid.y + 0.5) / U.gridN.x,
                  ((ll.y - U.grid.z) / U.grid.w + 0.5) / U.gridN.y);
}

static float2 landUV(float2 ll) {
    return float2((ll.x + 180.0) / 360.0, (ll.y + 90.0) / 180.0);
}

struct Tide { float h; float dh; float env; float speed; };

/// Σ f·H·cos(V+u−G), its rate (m/h), the sum of amplitudes, and the
/// amplitude-weighted speed, from the gridded (H cos G, H sin G).
/// Evaluated once per atlas cell per frame by `tide_field`. The sum is linear
/// in the gridded constants, so bilinear sampling of the result equals
/// evaluating the sum per pixel, at an eighth of the texture reads.
kernel void tide_field(texture2d_array<float, access::read> atlas [[texture(0)]],
                       texture2d<half, access::write> field [[texture(1)]],
                       constant GlobeUniforms &U [[buffer(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= field.get_width() || gid.y >= field.get_height()) return;
    Tide t = { 0, 0, 0, 0 };
    int n = int(U.gridN.z);
    float wsum = 0;
    for (int k = 0; k < n; k++) {
        float4 p = U.phasors[k];
        if (p.w == 0) continue;
        float2 c = atlas.read(gid, k).rg;
        t.h += c.x * p.x + c.y * p.y;
        t.dh += p.z * (c.y * p.x - c.x * p.y);
        float a = length(c) * length(p.xy);
        t.env += a;
        wsum += a * p.z;
    }
    t.speed = t.env > 1e-4 ? wsum / t.env : 0.5059;
    field.write(half4(half(t.h), half(t.dh), half(t.env), half(t.speed)), gid);
}

static Tide sampleTide(texture2d<float> field, sampler s, float2 uv, bool vertexStage) {
    float4 f = vertexStage ? field.sample(s, uv, level(0)) : field.sample(s, uv);
    Tide t = { f.x, f.y, f.z, f.w };
    return t;
}

// MARK: - Globe

struct GlobeOut {
    float4 position [[position]];
    float3 dir;
};

vertex GlobeOut globe_vertex(uint vid [[vertex_id]],
                             constant float4 *verts [[buffer(0)]],
                             constant GlobeUniforms &U [[buffer(1)]],
                             texture2d_array<float> atlas [[texture(0)]],
                             texture2d<float> land [[texture(1)]],
                             texture2d<float> field [[texture(2)]],
                             sampler s [[sampler(0)]]) {
    float3 d = verts[vid].xyz;
    float r = 1.0;
    if (U.params.x > 0) {
        float2 ll = lonLatDegrees(d);
        float ocean = 1.0 - land.sample(s, landUV(ll), level(0)).r;
        Tide t = sampleTide(field, s, atlasUV(ll, U), true);
        r += U.params.x * t.h * ocean;
    }
    GlobeOut o;
    o.position = U.viewProj * float4(d * r, 1.0);
    o.dir = d;
    return o;
}

static float3 tideColor(float h, float scale) {
    float t = clamp(h / scale, -1.0, 1.0);
    float m = pow(abs(t), 0.75);
    float3 still = float3(0.055, 0.150, 0.205);    // slack water
    float3 low   = float3(0.200, 0.470, 0.760);    // harbor blue
    float3 lowE  = float3(0.420, 0.700, 0.950);
    float3 high  = float3(0.920, 0.560, 0.300);    // swell
    float3 highE = float3(1.000, 0.880, 0.720);
    if (t < 0) return mix(mix(still, low, smoothstep(0.0, 0.75, m)), lowE, smoothstep(0.75, 1.0, m));
    return mix(mix(still, high, smoothstep(0.0, 0.75, m)), highE, smoothstep(0.75, 1.0, m));
}

static float hairline(float v, float width) {
    float w = max(fwidth(v), 1e-5);
    return 1.0 - smoothstep(0.0, width, abs(fract(v + 0.5) - 0.5) / w);
}

static float disc(float3 n, float3 c, float radius) {
    float a = acos(clamp(dot(n, c), -1.0, 1.0));
    float w = max(fwidth(a), 1e-5);
    return 1.0 - smoothstep(radius - w, radius + w, a);
}

static float ring(float3 n, float3 c, float radius, float width) {
    float a = acos(clamp(dot(n, c), -1.0, 1.0));
    float w = max(fwidth(a), 1e-5);
    return 1.0 - smoothstep(width * 0.5, width * 0.5 + w * 1.2, abs(a - radius));
}

fragment float4 globe_fragment(GlobeOut in [[stage_in]],
                               constant GlobeUniforms &U [[buffer(1)]],
                               texture2d_array<float> atlas [[texture(0)]],
                               texture2d<float> land [[texture(1)]],
                               texture2d<float> field [[texture(2)]],
                               sampler s [[sampler(0)]]) {
    float3 n = normalize(in.dir);
    float2 ll = lonLatDegrees(n);
    float landM = land.sample(s, landUV(ll)).r;
    float3 V = normalize(U.cameraPos.xyz - n);
    float3 L = U.sunDir.xyz;
    float ndl = dot(n, L);
    float day = smoothstep(-0.10, 0.18, ndl);

    // Ocean: the tide now.
    Tide t = sampleTide(field, s, atlasUV(ll, U), false);
    float3 ocean = tideColor(t.h, U.params.y);
    // Contours every 25 cm.
    ocean = mix(ocean, ocean * 1.35 + 0.03, 0.35 * hairline(t.h / 0.25, 1.0) * smoothstep(0.02, 0.1, t.env));
    // High water now: where the local tide is at its crest.
    float q = t.dh / max(t.speed, 0.05);
    float cosPhase = t.h / max(sqrt(t.h * t.h + q * q), 1e-4);
    float live = smoothstep(0.03, 0.15, t.env);
    float crest = smoothstep(0.990, 0.9993, cosPhase) * live;
    float trough = smoothstep(0.990, 0.9993, -cosPhase) * live;
    ocean = mix(ocean, float3(1.0, 0.95, 0.88), crest * 0.85);
    ocean = mix(ocean, float3(0.62, 0.84, 1.0), trough * 0.35);
    // One constituent: cotidal lines every 30° of phase (a lunar hour for M2).
    int sel = int(U.params.z);
    if (sel >= 0) {
        float2 c = atlas.sample(s, atlasUV(ll, U), sel).rg;
        float G = atan2(c.y, c.x) / (2.0 * PI) * 12.0;
        float amp = length(c);
        ocean = mix(ocean, float3(0.85, 0.92, 0.96), 0.45 * hairline(G, 1.0) * smoothstep(0.004, 0.03, amp));
    }
    // Sun glint.
    float3 Hv = normalize(L + V);
    float spec = pow(max(dot(n, Hv), 0.0), 90.0) * 0.45 * day;

    // Land: matte slate, a hairline coast.
    float3 landC = float3(0.205, 0.235, 0.245) + 0.06 * float3(0.6, 0.7, 0.6) * max(ndl, 0.0);
    float landA = smoothstep(0.35, 0.65, landM);
    float3 c = mix(ocean, landC, landA);
    float coast = 1.0 - smoothstep(0.0, 1.4, abs(landM - 0.5) / max(fwidth(landM), 1e-4));
    c = mix(c, float3(0.55, 0.68, 0.74), coast * 0.55);

    // Graticule every 30°.
    float grat = max(hairline(ll.x / 30.0, 0.8), hairline(ll.y / 30.0, 0.8));
    c = mix(c, float3(0.6, 0.75, 0.85), grat * 0.07);

    // Light: keep the night side readable, tint it blue.
    float night = U.params2.w;
    float3 lit = c * mix(night, 1.0, day) * (0.92 + 0.12 * max(ndl, 0.0));
    lit = mix(lit * float3(0.80, 0.90, 1.10), lit, day);
    lit += spec * (1.0 - landA) * float3(1.0, 0.95, 0.85);
    // Terminator glow.
    lit += float3(0.95, 0.55, 0.30) * 0.10 * (1.0 - smoothstep(0.0, 0.10, abs(ndl + 0.02)));

    // Where the Moon and Sun are overhead.
    float3 moonC = float3(0.94, 0.64, 0.40);
    lit = mix(lit, moonC, ring(n, U.moonDir.xyz, 0.050, 0.010));
    lit = mix(lit, moonC, disc(n, U.moonDir.xyz, 0.012));
    lit = mix(lit, float3(1.0, 0.96, 0.82), ring(n, L, 0.040, 0.007) * 0.9);
    lit = mix(lit, float3(1.0, 0.96, 0.82), disc(n, L, 0.010));

    // The tapped point.
    if (U.probe.w > 0) {
        lit = mix(lit, float3(1.0), ring(n, U.probe.xyz, 0.022, 0.006));
        lit = mix(lit, float3(1.0), disc(n, U.probe.xyz, 0.005));
    }

    // Atmosphere at the limb.
    float fres = pow(1.0 - max(dot(n, V), 0.0), 3.0);
    lit += float3(0.30, 0.55, 0.90) * fres * (0.25 + 0.55 * smoothstep(-0.3, 0.6, ndl));
    return float4(lit, 1.0);
}

// MARK: - Moon

struct BodyOut { float4 position [[position]]; float3 normal; };

vertex BodyOut body_vertex(uint vid [[vertex_id]], constant float4 *verts [[buffer(0)]], constant BodyUniforms &B [[buffer(1)]]) {
    float3 d = verts[vid].xyz;
    BodyOut o;
    o.position = B.viewProj * (B.model * float4(d, 1.0));
    o.normal = d;
    return o;
}

fragment float4 body_fragment(BodyOut in [[stage_in]], constant BodyUniforms &B [[buffer(1)]]) {
    float3 n = normalize(in.normal);
    float l = smoothstep(-0.05, 0.25, dot(n, B.sunDir.xyz));
    // A few soft maria so it reads as the Moon.
    float maria = 0.85 + 0.15 * sin(n.x * 7.0 + 1.3) * sin(n.y * 5.0 + 0.4) * sin(n.z * 6.0 + 2.0);
    return float4(B.color.rgb * maria * (0.04 + 0.96 * l), 1.0);
}

// MARK: - Stations

struct PointOut { float4 position [[position]]; float size [[point_size]]; float alpha; };

vertex PointOut point_vertex(uint vid [[vertex_id]], constant float4 *pts [[buffer(0)]], constant GlobeUniforms &U [[buffer(1)]]) {
    float3 d = pts[vid].xyz;
    PointOut o;
    float facing = dot(d, normalize(U.cameraPos.xyz));
    o.position = U.viewProj * float4(d * 1.003, 1.0);
    if (facing < 0.05) o.position = float4(2.0, 2.0, 2.0, 1.0); // behind the Earth: clip
    o.size = U.params2.x;
    o.alpha = smoothstep(0.05, 0.25, facing);
    return o;
}

fragment float4 point_fragment(PointOut in [[stage_in]], float2 pc [[point_coord]]) {
    float r = length(pc - 0.5) * 2.0;
    float a = (1.0 - smoothstep(0.55, 1.0, r)) * in.alpha;
    float core = 1.0 - smoothstep(0.0, 0.55, r);
    float3 c = mix(float3(0.43, 0.70, 0.89), float3(0.92, 0.96, 1.0), core);
    a *= 0.8;
    return float4(c * a, a);
}

// MARK: - Sky: stars fixed to the celestial sphere, and the atmosphere's halo

struct SkyOut { float4 position [[position]]; };

vertex SkyOut sky_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0;
    SkyOut o;
    o.position = float4(p, 1.0, 1.0);
    return o;
}

fragment float4 sky_fragment(SkyOut in [[stage_in]], constant GlobeUniforms &U [[buffer(1)]]) {
    float2 ndc = float2(in.position.x / U.params2.y * 2.0 - 1.0, 1.0 - in.position.y / U.params2.z * 2.0);
    float4 far = U.invViewProj * float4(ndc, 1.0, 1.0);
    float3 cam = U.cameraPos.xyz;
    float3 dir = normalize(far.xyz / far.w - cam);

    float3 c = float3(0.010, 0.022, 0.032);

    // Atmosphere halo around the limb, brighter on the day side.
    float tc = -dot(cam, dir);
    if (tc > 0) {
        float3 closest = cam + dir * tc;
        float d = length(closest);
        if (d > 1.0) {
            float glow = exp(-(d - 1.0) * 22.0);
            float sun = smoothstep(-0.4, 0.7, dot(normalize(closest), U.sunDir.xyz));
            c += float3(0.30, 0.56, 0.95) * glow * (0.18 + 0.6 * sun);
        }
    }
    return float4(c, 1.0);
}

// MARK: - Stars: points on the celestial sphere, turned by sidereal time

struct StarOut { float4 position [[position]]; float size [[point_size]]; float3 color; };

vertex StarOut star_vertex(uint vid [[vertex_id]], constant float4 *stars [[buffer(0)]], constant GlobeUniforms &U [[buffer(1)]]) {
    float4 st = stars[vid];                         // xyz direction (sky frame), w magnitude 0...1
    float th = -U.params.w;                          // sky → Earth-fixed
    float3 d = float3(st.x * cos(th) + st.z * sin(th), st.y, -st.x * sin(th) + st.z * cos(th));
    StarOut o;
    float4 p = U.viewProj * float4(U.cameraPos.xyz + d * 50.0, 1.0);
    o.position = float4(p.xy, p.w, p.w);             // pinned to the far plane, behind everything
    o.size = (1.1 + 2.0 * st.w) * U.gridN.w;
    float warm = fract(st.w * 7.31);
    o.color = mix(float3(0.75, 0.85, 1.0), float3(1.0, 0.88, 0.72), warm) * (0.35 + 0.65 * st.w);
    return o;
}

fragment float4 star_fragment(StarOut in [[stage_in]], float2 pc [[point_coord]]) {
    float r = length(pc - 0.5) * 2.0;
    float a = 1.0 - smoothstep(0.2, 1.0, r);
    return float4(in.color * a, a);
}
