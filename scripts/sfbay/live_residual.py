"""Build the live San Francisco Bay residual (`sfbay.residual`, docs/SFBAY.md) from NOAA SFBOFS.

Finds the latest complete SFBOFS cycle on CO-OPS OPeNDAP (cycles 03/09/15/21z;
a cycle is complete once its f048 file is listed, ~1 h 20 m after cycle time;
otherwise the previous cycle is used), reads the core-bay index spans of its
55 hourly fields files, moves currents to nodes with sfbaymesh (the same
averaging as the packer), subtracts the tidemesh harmonic prediction and
writes `sfbay.residual` plus its raw-deflate wire form `sfbay.residual.deflate`.

Frames (F = 55, hourly, cycle − 6 h … cycle + 48 h):
    n000 … n006   nowcast, valid at cycle − 6 h + n (n006 is the cycle hour)
    f001 … f048   forecast, valid at cycle + n
f000 duplicates n006's valid time and is not read. Each file's own `time` is
checked against that grid (±1 s; the stored seconds carry float noise).

usage:
    python scripts/sfbay/live_residual.py [--tidemesh App/Resources/Bay/sfbay.tidemesh]
        [--out DIR] [--cycle YYYYMMDDHH] [--tide-cli PATH] [--workers 6]

`--tide-cli` is a built tide-cli binary; by default the script builds and runs
it with `swift run --package-path TideKit --scratch-path build/spm-live`.
Needs numpy and netCDF4.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import os
import re
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
import zlib
from concurrent.futures import ProcessPoolExecutor

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sfbaymesh as sm  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BASE = "https://opendap.co-ops.nos.noaa.gov/thredds"
DODS = BASE + "/dodsC/NOAA/SFBOFS/MODELS/{c:%Y/%m/%d}/sfbofs.t{c:%H}z.{c:%Y%m%d}.fields.{f}.nc"
CATALOG = BASE + "/catalog/NOAA/SFBOFS/MODELS/{c:%Y/%m/%d}/catalog.xml"
CYCLES = (3, 9, 15, 21)
STEP = 3600.0
NOWCAST = 6
FORECAST = 48
FRAMES = NOWCAST + 1 + FORECAST  # 55
SF_GAUGE = (37.8063, -122.4659)  # NOAA 9414290 San Francisco (Presidio)

HEADER = struct.Struct("<4sHHIIddd8x")  # 48 bytes


def frame_files():
    """(file tag, hours after cycle) for the 55 frames, in time order."""
    return [(f"n{n:03d}", n - NOWCAST) for n in range(NOWCAST + 1)] + \
           [(f"f{n:03d}", n) for n in range(1, FORECAST + 1)]


# ---------------------------------------------------------------- tidemesh

def read_tidemesh(path):
    """The parts of sfbay.tidemesh the residual needs (docs/SFBAY.md, version 1)."""
    b = open(path, "rb").read()
    magic, version, k, n, t, mesh_id = struct.unpack_from("<4sHHIII", b, 0)
    if magic != b"TMSH" or version != 1:
        raise SystemExit(f"{path}: not a version-1 tidemesh")
    o = 32
    names = [b[o + 8 * i:o + 8 * i + 8].decode("ascii").strip() for i in range(k)]
    o += 8 * k
    nodes = np.frombuffer(b, sm.NODE_DTYPE, n, o)
    o += 16 * n + 16 * t
    mean = np.frombuffer(b, "<f2", 8 * n, o).reshape(n, 8).astype(np.float64)
    o += 16 * n
    zeta = np.frombuffer(b, "<f2", 2 * k * n, o).reshape(k, n, 2).astype(np.float64)
    o += 4 * k * n
    dm = np.frombuffer(b, "<f2", 4 * k * n, o).reshape(k, n, 4).astype(np.float64)
    o += 8 * k * n
    sf = np.frombuffer(b, "<f2", 4 * k * n, o).reshape(k, n, 4).astype(np.float64)
    o += 8 * k * n
    if o != len(b):
        raise SystemExit(f"{path}: size {len(b)} != expected {o}")
    return dict(names=names, n=n, mesh_id=mesh_id, lon=nodes["lon"].astype(np.float64),
                lat=nodes["lat"].astype(np.float64), index=nodes["index"].astype(np.int64),
                mean=mean, zeta=zeta, dm=dm, sf=sf)


def basis(tide_cli, start, names, out_dir):
    """TideKit's (c, s) per constituent at each frame time: (F, K) arrays, plus the unix times."""
    path = os.path.join(out_dir, "basis.csv")
    iso = dt.datetime.fromtimestamp(start, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    args = ["basis", iso, str(FRAMES), str(int(STEP)), ",".join(names), path]
    if tide_cli:
        cmd = [tide_cli] + args
    else:
        cmd = ["swift", "run", "--package-path", os.path.join(ROOT, "TideKit"),
               "--scratch-path", os.path.join(ROOT, "build", "spm-live"), "tide-cli"] + args
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL if tide_cli else None)
    with open(path) as f:
        rows = list(csv.reader(f))[1:]
    a = np.array(rows, np.float64)
    if a.shape != (FRAMES, 1 + 2 * len(names)):
        raise SystemExit(f"tide-cli basis: unexpected shape {a.shape}")
    return a[:, 0], a[:, 1::2], a[:, 2::2]


def predict(tm, c, s):
    """Harmonic prediction per frame and node: (F, N, 5) = zeta, depth-mean u/v, surface u/v."""
    # einsum over constituents: sum_k re[k,n] c[f,k] + im[k,n] s[f,k]
    def h(re, im):
        return np.einsum("kn,fk->fn", re, c) + np.einsum("kn,fk->fn", im, s)
    m = tm["mean"]
    z, dm, sf = tm["zeta"], tm["dm"], tm["sf"]
    out = np.empty((len(c), tm["n"], 5))
    out[..., 0] = m[:, 0] + h(z[..., 0], z[..., 1])
    out[..., 1] = m[:, 1] + h(dm[..., 0], dm[..., 1])
    out[..., 2] = m[:, 2] + h(dm[..., 2], dm[..., 3])
    out[..., 3] = m[:, 3] + h(sf[..., 0], sf[..., 1])
    out[..., 4] = m[:, 4] + h(sf[..., 2], sf[..., 3])
    return out


# ---------------------------------------------------------------- SFBOFS

def http_get(url, tries=4, timeout=60):
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=timeout) as r:
                return r.read().decode("utf-8", "replace")
        except Exception as e:  # noqa: BLE001 - network hiccups: back off and retry
            err = e
            time.sleep(2 + 4 * attempt)
    raise RuntimeError(f"GET {url}: {err}")


def cycle_complete(cycle):
    """Whether every file of `cycle` is listed in its day's THREDDS catalog."""
    try:
        listed = set(re.findall(r'name="(sfbofs\.[^"]+\.nc)"', http_get(CATALOG.format(c=cycle))))
    except RuntimeError as e:
        print(f"  catalog unavailable ({e})", flush=True)
        return False
    want = {DODS.format(c=cycle, f=f).rsplit("/", 1)[1] for f, _ in frame_files()}
    return want <= listed


def latest_cycle(now, back=4):
    """The newest complete cycle at or before `now`, trying up to `back` cycles."""
    t = now.replace(minute=0, second=0, microsecond=0)
    candidates = []
    while len(candidates) < back:
        if t.hour in CYCLES:
            candidates.append(t)
        t -= dt.timedelta(hours=1)
    for c in candidates:
        ok = cycle_complete(c)
        print(f"cycle {c:%Y-%m-%d %H}z: {'complete' if ok else 'incomplete'}", flush=True)
        if ok:
            return c
    raise SystemExit("no complete SFBOFS cycle found")


_REGION = None


def _init_worker(region):
    global _REGION
    _REGION = region


def fetch_frame(job):
    """Read one fields file's region span, with retries. Runs in a worker process
    (the netCDF C library is not thread safe)."""
    url, expected = job
    import netCDF4

    err = None
    for attempt in range(5):
        try:
            ds = netCDF4.Dataset(url)
            try:
                out = sm.extract(ds, _REGION)
            finally:
                ds.close()
            if abs(out["time"] - expected) > 1:
                raise SystemExit(f"{url}: valid time {out['time']:.0f} != expected {expected:.0f}")
            return out
        except SystemExit:
            raise
        except Exception as e:  # noqa: BLE001
            err = e
            time.sleep(3 + 5 * attempt)
    raise RuntimeError(f"{url}: {err}")


# ---------------------------------------------------------------- main

#: Residuals are rounded to multiples of 2^-8 (~4 mm, ~4 mm/s) before f16:
#: invisible in the app, and the file deflates to ~2/3 the size (6.1 → 4.0 MB).
QUANTUM = 2.0 ** -8


def to_f16(a):
    a = np.where(np.isfinite(a), a, 0.0)
    return (np.round(np.clip(a, -60000, 60000) / QUANTUM) * QUANTUM).astype("<f2")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--tidemesh", default=os.path.join(ROOT, "App", "Resources", "Bay", "sfbay.tidemesh"))
    p.add_argument("--out", default=".")
    p.add_argument("--cycle", help="YYYYMMDDHH (default: latest complete)")
    p.add_argument("--tide-cli", help="path to a built tide-cli (default: swift run)")
    p.add_argument("--workers", type=int, default=6)
    a = p.parse_args()

    t0 = time.time()
    tm = read_tidemesh(a.tidemesh)
    print(f"tidemesh: N={tm['n']} K={len(tm['names'])} meshID=0x{tm['mesh_id']:08x}", flush=True)

    if a.cycle:
        cycle = dt.datetime.strptime(a.cycle, "%Y%m%d%H").replace(tzinfo=dt.timezone.utc)
    else:
        cycle = latest_cycle(dt.datetime.now(dt.timezone.utc))
    cyc = cycle.timestamp()
    start = cyc - NOWCAST * STEP
    jobs = [(DODS.format(c=cycle, f=f), cyc + h * STEP) for f, h in frame_files()]

    region = sm.select_region(sm.load_mesh(jobs[0][0]))
    if region.node_count != tm["n"] or region.mesh_id != tm["mesh_id"]:
        raise SystemExit(f"region N={region.node_count} meshID=0x{region.mesh_id:08x} does not match the tidemesh")
    if not np.array_equal(region.nodes, tm["index"]):
        raise SystemExit("region node order does not match the tidemesh")

    with tempfile.TemporaryDirectory() as tmp:
        times, c, s = basis(a.tide_cli, start, tm["names"], tmp)
    if not np.allclose(times, start + STEP * np.arange(FRAMES), atol=0.5):
        raise SystemExit("basis times do not line up with the frames")

    model = np.empty((FRAMES, tm["n"], 5))
    with ProcessPoolExecutor(a.workers, initializer=_init_worker, initargs=(region,)) as pool:
        for i, out in enumerate(pool.map(fetch_frame, jobs)):
            for j, key in enumerate(("zeta", "ua", "va", "us", "vs")):
                model[i, :, j] = out[key]
    print(f"fetched {FRAMES} frames in {time.time() - t0:.0f}s", flush=True)

    resid = model - predict(tm, c, s)
    bad = ~np.isfinite(resid)
    if bad.any():
        print(f"warning: {bad.sum()} non-finite values set to 0", flush=True)
    frames = np.zeros((FRAMES, tm["n"], 8), "<f2")
    frames[..., :5] = to_f16(resid)

    os.makedirs(a.out, exist_ok=True)
    raw = HEADER.pack(b"TRES", 1, FRAMES, tm["n"], tm["mesh_id"], start, STEP, cyc) + frames.tobytes()
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    wire = comp.compress(raw) + comp.flush()
    with open(os.path.join(a.out, "sfbay.residual"), "wb") as f:
        f.write(raw)
    with open(os.path.join(a.out, "sfbay.residual.deflate"), "wb") as f:
        f.write(wire)

    # Summary
    lat, lon = SF_GAUGE
    k = np.cos(np.radians(lat))
    sf = int(np.argmin((tm["lat"] - lat) ** 2 + ((tm["lon"] - lon) * k) ** 2))
    zr = resid[:, sf, 0]
    dm = np.hypot(resid[..., 1], resid[..., 2])
    su = np.hypot(resid[..., 3], resid[..., 4])
    za = np.abs(resid[..., 0])
    print(f"cycle {cycle:%Y-%m-%d %H}z, frames {FRAMES} from "
          f"{dt.datetime.fromtimestamp(start, dt.timezone.utc):%Y-%m-%d %H:%M}Z, step {STEP:.0f}s")
    print(f"zeta residual at SF node {sf} ({tm['lat'][sf]:.4f}, {tm['lon'][sf]:.4f}): "
          f"{zr.min():+.3f} … {zr.max():+.3f} m (mean {zr.mean():+.3f})")
    print(f"|zeta residual| all nodes: median {np.median(za):.3f}, p99 {np.percentile(za, 99):.3f}, max {za.max():.3f} m")
    print(f"|current residual| depth-mean: median {np.median(dm):.3f}, p99 {np.percentile(dm, 99):.3f}, "
          f"max {dm.max():.3f} m/s; surface: median {np.median(su):.3f}, p99 {np.percentile(su, 99):.3f}, max {su.max():.3f} m/s")
    print(f"wrote {len(raw):,} bytes, {len(wire):,} deflated → {os.path.join(a.out, 'sfbay.residual.deflate')} "
          f"({time.time() - t0:.0f}s)")


if __name__ == "__main__":
    main()
