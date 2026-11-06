# San Francisco Bay tide and current model: contracts

Shared spec for the Bay model work: the offline pipeline, TideKit, the Metal
scene and the live residual job all build against what's written here. Change
it only deliberately, and update every side when you do.

## Region

Core bay, the first focus: **lon −122.80 … −122.30, lat 37.70 … 37.95**. That's
the bar and near Pacific, the Golden Gate, the Central Bay, Richardson Bay,
Angel Island and Raccoon Strait, the Bay Bridge, Oakland and Alameda's edge,
and Richmond and San Rafael Bay's mouth. Mesh nodes inside the box are kept,
along with every triangle whose three nodes are all kept. The South Bay,
San Pablo Bay, Suisun and the Delta come later, in the same format.

## Source and method

* NOAA SFBOFS (FVCOM, 54,120 nodes and 102,264 elements). Hourly nowcast `fields`
  files come from NCEI (`https://www.ncei.noaa.gov/thredds/dodsC/model-sfbofs-files/YYYY/MM/sfbofs.tCCz.YYYYMMDD.fields.nNNN.nc`,
  cycle CC's step n is valid at CC − 6 h + n). The live job reads the recent cycles from CO-OPS
  (`https://opendap.co-ops.nos.noaa.gov/thredds/dodsC/NOAA/SFBOFS/MODELS/YYYY/MM/DD/...`).
* Currents: the **depth mean** is the mean of sigma layers 2, 7, 12 and 17 (within ~1 cm/s
  of the 20-layer mean). The **surface** is sigma layer 0.
* Currents live on FVCOM elements. They are moved to **nodes** as the area-weighted
  mean of the elements touching each node, with areas in a local metric projection.
  The packer and the live job must share this code: `scripts/sfbay/sfbaymesh.py`.
* Constants are fitted by least squares against TideKit's own basis
  (`tide-cli basis`, i.e. `HarmonicBasis.phasors`), so each constituent is stored
  as (H cos G, H sin G), and the prediction is `Z0 + Σ re·c + im·s` with
  (c, s) = f·(cos(V+u), sin(V+u)) at that instant, node factors at mid-year.

## `sfbay.tidemesh` (App/Resources/Bay/), version 1, little endian

| Field | Type |
|---|---|
| magic | `"TMSH"` (4 bytes) |
| version | u16 = 1 |
| constituentCount K | u16 (≤ 24) |
| nodeCount N | u32 |
| triangleCount T | u32 |
| meshID | u32: CRC-32 (IEEE) of the node block followed by the triangle block, as stored |
| reserved | 12 bytes, zero |
| names | K × 8 bytes ASCII, space padded (TideKit `ConstituentCatalog` names) |
| node block | N × { f32 longitude, f32 latitude, f32 depth (m, positive down, model `h`), u32 SFBOFS node index (0-based) } |
| triangle block | T × { u32 a, u32 b, u32 c (node indices, counter-clockwise in lon/lat), u32 SFBOFS element index } |
| mean block | N × { f16 zeta Z0 (m), f16 depth-mean u0, f16 depth-mean v0, f16 surface u0, f16 surface v0, f16 0, f16 0, f16 0 } (16 bytes per node) |
| zeta constants | K × N × { f16 re, f16 im } (metres), constituent-major |
| depth-mean current constants | K × N × { f16 u re, f16 u im, f16 v re, f16 v im } (m/s; u east, v north) |
| surface current constants | K × N × { f16 u re, f16 u im, f16 v re, f16 v im } |

Water level from the file is relative to the model's own mean (`zeta` is
"above geoid"; Z0 is stored but the app shows η − Z0 as "relative to mean
sea level" until datums are reconciled).

## `sfbay.residual` (live, version 1, little endian), raw-deflate compressed on the wire

After decompression:

| Field | Type |
|---|---|
| magic | `"TRES"` |
| version | u16 = 1 |
| frameCount F | u16 |
| nodeCount N | u32 (must equal the tidemesh's) |
| meshID | u32 (must equal the tidemesh's) |
| start | f64 unix seconds, valid time of frame 0 |
| step | f64 seconds between frames (3600) |
| cycle | f64 unix seconds of the SFBOFS cycle it came from |
| reserved | 8 bytes, zero |
| frames | F × N × { f16 zeta, f16 depth-mean u, f16 depth-mean v, f16 surface u, f16 surface v, f16 0, f16 0, f16 0 } |

Each value is the model **minus** the tidemesh harmonic prediction
(including Z0 and the mean currents) at that node and hour. Frames run from
the cycle's nowcast start (cycle − 6 h) to its last forecast hour (cycle + 48 h),
so F = 55. Total water and flow = harmonic prediction + residual, linearly
interpolated in time. Outside the frames, use the harmonic prediction alone.
Published by `.github/workflows/sfbay-live.yml` as the asset `sfbay.residual.deflate`
on the GitHub release tagged `sfbay-live`. The app reads its URL from Info.plist
key `TideBayLiveURL` and works fully offline without it.

## TideKit API (TideKit/Sources/TideKit/Bay/)

```swift
public struct TideMesh: Sendable {
    public init(data: Data) throws
    public let constituents: [ConstituentDefinition]   // K, file order
    public let constituentNames: [String]
    public let nodeCount: Int, triangleCount: Int
    public let meshID: UInt32
    public let longitudes: [Float], latitudes: [Float], depths: [Float]   // per node
    public let triangles: [UInt32]                                       // 3 per triangle
    public let boundaryEdges: [(UInt32, UInt32)]   // mesh edges used by one triangle only (coast + open boundary)
    public enum Block { case mean, zeta, depthMeanCurrent, surfaceCurrent }
    public func rawBlock(_ block: Block) -> Data   // exactly as stored, for GPU upload
    public func locate(latitude: Double, longitude: Double) -> (triangle: Int, weights: SIMD3<Double>)?
    public func waterLevel(latitude: Double, longitude: Double, at: Date) -> Double?        // m, η − Z0
    public func current(latitude: Double, longitude: Double, at: Date, surface: Bool) -> (east: Double, north: Double)?   // m/s, incl. mean
    public func waterLevelPredictor(latitude: Double, longitude: Double) -> HarmonicPredictor?
}

public struct BayResidual: Sendable {
    public init(data: Data, mesh: TideMesh) throws        // decompressed bytes
    public let start: Date, step: TimeInterval, frameCount: Int, cycle: Date
    public var end: Date { get }
    public func rawFrames() -> Data                         // F × N × 16 bytes, for GPU upload
    public func frameIndex(at: Date) -> (lower: Int, upper: Int, t: Double)?
}
```

`HarmonicBasis.phasors(_:at:)` (TideKit/Globe/TideAtlas.swift) gives the
per-frame (c, s) for the GPU, exactly as for the Tide Globe.
