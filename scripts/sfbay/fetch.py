"""Fetch hourly SFBOFS nowcast fields for the core San Francisco Bay from NCEI OPeNDAP.

Per valid hour, reads only the region's contiguous node and element spans
(sfbaymesh.Region.node_span / elem_span) and saves, on the region's nodes:
zeta, depth-mean u/v (mean of sigma layers 2, 7, 12, 17) and surface u/v
(layer 0), the currents moved to nodes by sfbaymesh's area-weighted mean.
One `YYYYMMDDHH.npz` per hour; reruns skip hours already on disk, and hours
missing from the archive are reported and skipped (the fit tolerates gaps).

usage: python fetch.py START(YYYY-MM-DD) DAYS OUTDIR [MESH(path or URL)] [THREADS]
"""
import datetime as dt
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import netCDF4 as nc
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sfbaymesh as sm  # noqa: E402

URL = "https://www.ncei.noaa.gov/thredds/dodsC/model-sfbofs-files/{t:%Y}/{t:%m}/sfbofs.t{c:02d}z.{t:%Y%m%d}.fields.n{n:03d}.nc"


def jobs(start, days):
    """(valid hour, url): cycle C's nowcast step n is valid at C - 6 h + n."""
    out = []
    for d in range(days + 1):
        day = start + dt.timedelta(days=d)
        for c in (3, 9, 15, 21):
            for n in range(1, 7):
                valid = day + dt.timedelta(hours=c - 6 + n)
                if start <= valid < start + dt.timedelta(days=days):
                    out.append((valid, URL.format(t=day, c=c, n=n)))
    return out


def fetch(job, outdir, region):
    valid, url = job
    path = os.path.join(outdir, valid.strftime("%Y%m%d%H") + ".npz")
    if os.path.exists(path):
        return "skip"
    err = None
    for attempt in range(3):
        try:
            ds = nc.Dataset(url)
            try:
                f = sm.extract(ds, region)
            finally:
                ds.close()
            if abs(f["time"] - valid.replace(tzinfo=dt.timezone.utc).timestamp()) > 60:
                return f"FAIL {url} valid time {f['time']} != {valid}"
            np.savez(path + ".tmp.npz", t=f["time"], **{k: f[k] for k in ("zeta", "ua", "va", "us", "vs")})
            os.replace(path + ".tmp.npz", path)
            return "ok"
        except Exception as e:  # missing file or network hiccup: back off and retry
            err = e
            if "404" in str(e) or "not found" in str(e).lower():
                break
            time.sleep(2 + 3 * attempt)
    return f"FAIL {url} {err}"


if __name__ == "__main__":
    start = dt.datetime.strptime(sys.argv[1], "%Y-%m-%d")
    days, outdir = int(sys.argv[2]), sys.argv[3]
    js = jobs(start, days)
    mesh_src = sys.argv[4] if len(sys.argv) > 4 else js[0][1]
    threads = int(sys.argv[5]) if len(sys.argv) > 5 else 8
    os.makedirs(outdir, exist_ok=True)
    region = sm.select_region(sm.load_mesh(mesh_src))
    print(f"region N={region.node_count} T={region.triangle_count} meshID=0x{region.mesh_id:08x} "
          f"nodes {region.node_span} elements {region.elem_span}", flush=True)
    # The archive's mesh must match the one the region was cut from.
    for _, url in js[len(js) // 2:] + js[:len(js) // 2]:
        try:
            probe = sm.select_region(sm.load_mesh(url))
            break
        except OSError:
            continue
    else:
        sys.exit("no archive file found in the range")
    if probe.mesh_id != region.mesh_id:
        sys.exit(f"archive mesh differs from {mesh_src} (meshID 0x{probe.mesh_id:08x})")
    print(f"{len(js)} hours to fetch", flush=True)
    t0, done, failed = time.time(), 0, 0
    with ThreadPoolExecutor(threads) as pool:
        for r in pool.map(lambda j: fetch(j, outdir, region), js):
            done += 1
            if r.startswith("FAIL"):
                failed += 1
                print(r, flush=True)
            if done % 96 == 0:
                print(f"{done}/{len(js)} in {time.time() - t0:.0f}s ({failed} failed)", flush=True)
    print(f"done: {done - failed} hours, {failed} failed", flush=True)
