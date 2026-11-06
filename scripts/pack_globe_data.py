#!/usr/bin/env python3
"""Pack the data behind the Tide Globe into two small binary files.

1. Ocean tide atlas: NASA GSFC GOT4.10c (R. Ray), 0.5° global grids of the
   eight major constituents. NASA-produced, public domain in the US. Upstream:
   https://earth.gsfc.nasa.gov/geo/data/ocean-tide-models (got4.10c.tar.gz)

2. Land: Natural Earth 1:50m land polygons (public domain), via the
   world-atlas TopoJSON build: https://cdn.jsdelivr.net/npm/world-atlas@2.0.2/land-50m.json

Usage (standard library only):

    python3 scripts/pack_globe_data.py <GOT4.10c dir> <land-50m.json> App/Resources/Globe

Atlas format (`got410c.tideatlas`), little endian:
    magic "TATL", u16 version=1, u16 nLat, u16 nLon, u16 nConstituents,
    f32 lat0, f32 dLat, f32 lon0, f32 dLon,
    nConstituents × 8-byte ASCII names (space padded),
    then for each constituent, row-major from lat0 upward: nLat × nLon pairs of
    float16 (H·cos G, H·sin G) in metres, G = Greenwich phase lag.
    Land cells are filled from neighbouring ocean (a few cells) so bilinear
    sampling holds up at the coast, then zero.

Land format (`land50m.rings`), little endian:
    magic "LRNG", u32 ringCount, then per ring: u32 pointCount followed by
    pointCount × (i16 lon, i16 lat) with degrees = value × 180 / 32767.
"""
import json
import math
import os
import struct
import sys

CONSTITUENTS = ["M2", "S2", "N2", "K2", "K1", "O1", "P1", "Q1"]
DILATE_STEPS = 4


def read_grids(path):
    """Yield (nlat, nlon, lat0, lat1, lon0, lon1, mask, values) for each grid in a GOT ascii file."""
    with open(path) as fh:
        lines = fh.read().split("\n")
    i = 0
    while i < len(lines):
        if not lines[i].strip():
            i += 1
            continue
        # header: title, description, dims, lat range, lon range, mask, format
        nlat, nlon = (int(x) for x in lines[i + 2].split())
        lat0, lat1 = (float(x) for x in lines[i + 3].split())
        lon0, lon1 = (float(x) for x in lines[i + 4].split())
        mask = float(lines[i + 5].split()[0])
        fmt = lines[i + 6].strip()  # e.g. (11F7.2) or (11F8.2)
        width = int(fmt[fmt.index("F") + 1:fmt.index(".")])
        i += 7
        need, vals = nlat * nlon, []
        while len(vals) < need:
            line = lines[i].rstrip("\n")
            for k in range(0, len(line), width):
                tok = line[k:k + width].strip()
                if tok:
                    vals.append(float(tok))
            i += 1
        yield nlat, nlon, lat0, lat1, lon0, lon1, mask, vals


def pack_atlas(got_dir, out_path):
    grids = []
    meta = None
    for name in CONSTITUENTS:
        amp, pha = list(read_grids(os.path.join(got_dir, "grids_oceantide", name.lower() + ".d")))[:2]
        nlat, nlon, lat0, lat1, lon0, lon1, mask, a = amp
        p = pha[7]
        assert pha[0] == nlat and pha[1] == nlon
        meta = (nlat, nlon, lat0, (lat1 - lat0) / (nlat - 1), lon0, (lon1 - lon0) / (nlon - 1))
        re = [None] * (nlat * nlon)
        im = [None] * (nlat * nlon)
        for k in range(nlat * nlon):
            if a[k] >= mask - 0.5 or p[k] >= mask - 0.5:
                continue
            h = a[k] / 100.0  # cm -> m
            g = math.radians(p[k])
            re[k], im[k] = h * math.cos(g), h * math.sin(g)
        # Spread ocean values a few cells onto land so the coast samples cleanly.
        for _ in range(DILATE_STEPS):
            nre, nim = re[:], im[:]
            for r in range(nlat):
                for c in range(nlon):
                    k = r * nlon + c
                    if re[k] is not None:
                        continue
                    sr = si = 0.0
                    n = 0
                    for dr, dc in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                        rr = r + dr
                        if rr < 0 or rr >= nlat:
                            continue
                        kk = rr * nlon + (c + dc) % nlon
                        if re[kk] is not None:
                            sr += re[kk]
                            si += im[kk]
                            n += 1
                    if n:
                        nre[k], nim[k] = sr / n, si / n
            re, im = nre, nim
        flat = []
        for k in range(nlat * nlon):
            flat.append(re[k] or 0.0)
            flat.append(im[k] or 0.0)
        grids.append(struct.pack("<%de" % len(flat), *flat))
        print(f"  {name}: max amplitude {max(x for x in a if x < mask - 0.5) / 100:.2f} m")
    nlat, nlon, lat0, dlat, lon0, dlon = meta
    with open(out_path, "wb") as fh:
        fh.write(b"TATL")
        fh.write(struct.pack("<HHHH", 1, nlat, nlon, len(CONSTITUENTS)))
        fh.write(struct.pack("<ffff", lat0, dlat, lon0, dlon))
        for name in CONSTITUENTS:
            fh.write(name.ljust(8).encode("ascii"))
        for g in grids:
            fh.write(g)
    print(f"wrote {out_path} ({os.path.getsize(out_path) / 1e6:.1f} MB)")


def pack_land(topo_path, out_path):
    topo = json.load(open(topo_path))
    sx, sy = topo["transform"]["scale"]
    tx, ty = topo["transform"]["translate"]
    arcs = []
    for arc in topo["arcs"]:
        x = y = 0
        pts = []
        for dx, dy in arc:
            x += dx
            y += dy
            pts.append((x * sx + tx, y * sy + ty))
        arcs.append(pts)

    def ring(indices):
        pts = []
        for i in indices:
            a = arcs[i] if i >= 0 else list(reversed(arcs[~i]))
            pts.extend(a if not pts else a[1:])
        return pts

    rings = []
    for geom in topo["objects"]["land"]["geometries"]:
        polys = geom["arcs"] if geom["type"] == "MultiPolygon" else [geom["arcs"]]
        for poly in polys:
            for r in poly:
                rings.append(ring(r))
    q = 32767 / 180.0
    with open(out_path, "wb") as fh:
        fh.write(b"LRNG")
        fh.write(struct.pack("<I", len(rings)))
        npts = 0
        for r in rings:
            fh.write(struct.pack("<I", len(r)))
            for lon, lat in r:
                fh.write(struct.pack("<hh", round(lon * q), round(lat * q)))
            npts += len(r)
    print(f"wrote {out_path} ({len(rings)} rings, {npts} points, {os.path.getsize(out_path) / 1e3:.0f} kB)")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    got_dir, land_json, out_dir = sys.argv[1:]
    os.makedirs(out_dir, exist_ok=True)
    pack_atlas(got_dir, os.path.join(out_dir, "got410c.tideatlas"))
    pack_land(land_json, os.path.join(out_dir, "land50m.rings"))
