"""Harmonic fit of hourly SFBOFS fields on the bay region's nodes, in TideKit's convention,
validated against NOAA's published water-level and current constants.

usage: python analyze.py DATADIR BASIS.csv MESH.nc TRUTHDIR OUTDIR [--fit M2,S2,...] [--infer S2:K2:0.272,...]

DATADIR holds hourly `YYYYMMDDHH.npz` files from fetch.py (per region node:
zeta, ua, va, us, vs; t = unix seconds). BASIS.csv comes from
`tide-cli basis` and must cover every hour. By default every constituent in
the basis is fitted; --fit picks a subset, and --infer adds constituents tied
to a fitted one by NOAA's amplitude ratio at equal phase (needed for short
records only). Writes OUTDIR/constants.npz (what pack.py packs) and prints
the comparison with NOAA.
"""
import argparse
import glob
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sfbaymesh as sm  # noqa: E402

FIELDS = ("zeta", "ua", "va", "us", "vs")
GAUGES = {  # NOAA water-level stations in or at the edge of the region
    "9414290": ("San Francisco", 37.806305, -122.46589),
    "9414806": ("Sausalito", 37.8467, -122.477),
    "9414863": ("Richmond", 37.9283, -122.4),
    "9414358": ("Hunters Point", 37.73, -122.357),
    "9414750": ("Alameda", 37.771667, -122.3),
}
COMPARE = ["M2", "S2", "N2", "K1", "O1", "M4"]  # printed per station
WL_MIN, CUR_MIN = 0.01, 5.0  # compare constituents NOAA puts above 1 cm / 5 cm/s


# ---------------------------------------------------------------- fit

def load(datadir):
    files = sorted(glob.glob(os.path.join(datadir, "[0-9]" * 10 + ".npz")))
    t = np.empty(len(files))
    data = None
    for i, f in enumerate(files):
        z = np.load(f)
        if data is None:
            data = {k: np.empty((len(files), len(z[k])), np.float32) for k in FIELDS}
        t[i] = float(z["t"])
        for k in FIELDS:
            data[k][i] = z[k]
    return t, data


def design(basis_csv, t, fit_names=None, infer=()):
    raw = np.genfromtxt(basis_csv, delimiter=",", names=True, deletechars="")
    names = [n[:-2] for n in raw.dtype.names[1::2]]
    fit_names = fit_names or names
    rows = {int(round(u)): i for i, u in enumerate(raw["unix"])}
    missing = [x for x in t if int(round(x)) not in rows]
    if missing:
        raise SystemExit(f"basis does not cover {len(missing)} hours, e.g. {missing[0]}")
    idx = [rows[int(round(x))] for x in t]
    col = lambda n, k: raw[f"{n}_{k}"][idx]
    cols = [np.ones(len(t))]
    for n in fit_names:
        c, s = col(n, "c"), col(n, "s")
        for main, inf, r in infer:
            if main == n:
                c, s = c + r * col(inf, "c"), s + r * col(inf, "s")
        cols += [c, s]
    return np.stack(cols, 1)


def fit(datadir, basis_csv, fit_names=None, infer=()):
    """Least squares per node and field. Returns dict with names, z0[field] (N,),
    const[field] (K, N, 2) = (H cos G, H sin G), rms[field] (N,), hours, span."""
    t, data = load(datadir)
    if fit_names is None:
        raw = open(basis_csv).readline().strip().split(",")[1::2]
        fit_names = [n[:-2] for n in raw]
    X = design(basis_csv, t, fit_names, infer)
    print(f"{len(t)} hours ({np.diff(t).max() / 3600:.0f} h largest gap), {X.shape[1]} columns, "
          f"condition {np.linalg.cond(X):.1f}")
    pinv = np.linalg.pinv(X)
    names = list(fit_names) + [inf for _, inf, _ in infer]
    out = {"names": names, "z0": {}, "const": {}, "rms": {}, "hours": len(t), "span": (t.min(), t.max())}
    for k in FIELDS:
        Y = data[k].astype(np.float64)
        coef = pinv @ Y
        rms = np.sqrt(((Y - X @ coef) ** 2).mean(0))
        K = len(fit_names)
        c = coef[1:].reshape(K, 2, -1).transpose(0, 2, 1)  # (K, N, 2)
        extra = [r * c[fit_names.index(main)] for main, _, r in infer]
        out["z0"][k] = coef[0]
        out["const"][k] = np.concatenate([c, np.array(extra).reshape(-1, *c.shape[1:])]) if extra else c
        out["rms"][k] = rms
        del Y
        print(f"  {k:4s} residual rms median {np.median(rms):.3f}, 95th pct {np.percentile(rms, 95):.3f}")
    return out


def save(res, path):
    np.savez_compressed(path, names=np.array(res["names"]), hours=res["hours"], span=np.array(res["span"]),
                        **{f"z0_{k}": res["z0"][k] for k in FIELDS},
                        **{f"c_{k}": res["const"][k].astype(np.float32) for k in FIELDS},
                        **{f"rms_{k}": res["rms"][k].astype(np.float32) for k in FIELDS})


def load_constants(path):
    z = np.load(path)
    return {"names": [str(n) for n in z["names"]], "hours": int(z["hours"]), "span": tuple(z["span"]),
            "z0": {k: z[f"z0_{k}"] for k in FIELDS}, "const": {k: z[f"c_{k}"] for k in FIELDS},
            "rms": {k: z[f"rms_{k}"] for k in FIELDS}}


# ---------------------------------------------------------------- validation

def interpolator(region):
    """Barycentric interpolation inside the region's triangles (nearest node outside)."""
    x, y = region.lon.astype(np.float64), region.lat.astype(np.float64)
    tri = region.triangles.astype(np.int64)

    def at(lon, lat):
        a, b, c = tri.T
        det = (y[b] - y[c]) * (x[a] - x[c]) + (x[c] - x[b]) * (y[a] - y[c])
        l1 = ((y[b] - y[c]) * (lon - x[c]) + (x[c] - x[b]) * (lat - y[c])) / det
        l2 = ((y[c] - y[a]) * (lon - x[c]) + (x[a] - x[c]) * (lat - y[c])) / det
        l3 = 1 - l1 - l2
        inside = np.flatnonzero((l1 >= -1e-9) & (l2 >= -1e-9) & (l3 >= -1e-9))
        if len(inside):
            i = inside[0]
            return tri[i], np.array([l1[i], l2[i], l3[i]]), 0.0
        d = (x - lon) ** 2 * np.cos(np.radians(lat)) ** 2 + (y - lat) ** 2
        j = int(np.argmin(d))
        return np.array([j]), np.array([1.0]), float(np.sqrt(d[j]) * 111_000)

    return at


def amp_phase(z):
    return np.abs(z), np.degrees(np.angle(z)) % 360


def dphase(a, b):
    return (a - b + 180) % 360 - 180


def validate(res, region, truth, quiet=False):
    say = (lambda *a: None) if quiet else print
    at = interpolator(region)
    names = res["names"]

    def cval(field, name, nodes, w):
        c = res["const"][field][names.index(name)][nodes]
        return complex(*(w @ c))

    wl_rows = []
    say("\nWATER LEVEL  model/NOAA amplitude (cm), phase difference (deg)")
    for sid, (label, lat, lon) in GAUGES.items():
        f = os.path.join(truth, f"wl_{sid}.json")
        if not os.path.exists(f):
            continue
        hc = {c["name"]: c for c in json.load(open(f))["HarmonicConstituents"]}
        nodes, w, dist = at(lon, lat)
        line = f"{label:14s}{'' if dist == 0 else f' ({dist:.0f} m off)':>13s}"
        for n in names:
            if n not in hc or hc[n]["amplitude"] < WL_MIN:
                continue
            a, g = amp_phase(cval("zeta", n, nodes, w))
            A, G = hc[n]["amplitude"], hc[n]["phase_GMT"]
            if n in COMPARE:
                line += f" | {n} {a * 100:5.1f}/{A * 100:5.1f} {dphase(g, G):+5.1f}"
            wl_rows.append((label, n, a, A, dphase(g, G)))
        say(line)

    cur_rows = []
    say("\nCURRENTS along NOAA's flood axis, model/NOAA cm/s and phase (deg): surface vs shallowest bin, "
        "depth-mean vs middle bin")
    stations = {s["id"]: s for s in json.load(open(os.path.join(truth, "cp.json")))["stations"]}
    for f in sorted(glob.glob(os.path.join(truth, "hc_*.json"))):
        sid = f.split("hc_")[-1][:-5]
        if sid not in stations:
            continue
        hcs = json.load(open(f)).get("HarmonicConstituents", [])
        bins = sorted({(r["binNbr"], r["binDepth"] or 0) for r in hcs}, key=lambda b: b[1])
        if not bins:
            continue
        s = stations[sid]
        nodes, w, dist = at(s["lng"], s["lat"])
        picks = [("surf", bins[0][0], "us", "vs"), ("mean", bins[len(bins) // 2][0], "ua", "va")]
        line = f"{sid:8s} {s['name'][:28]:28s}"
        for tag, b, ku, kv in picks:
            rows = {r["constituentName"]: r for r in hcs if r["binNbr"] == b}
            if "M2" not in rows:
                continue
            az = np.radians(rows["M2"]["azi"])
            for n in names:
                if n not in rows or rows[n]["majorAmplitude"] < CUR_MIN:
                    continue
                z = cval(ku, n, nodes, w) * np.sin(az) + cval(kv, n, nodes, w) * np.cos(az)
                a, g = amp_phase(z)
                A, G = rows[n]["majorAmplitude"], rows[n]["majorPhaseGMT"]
                cur_rows.append((sid, tag, n, a * 100, A, dphase(g, G)))
                if n == "M2":
                    line += f" | {tag} {rows[n]['binDepth'] or 0:4.1f} m: {a * 100:5.1f}/{A:5.1f} {dphase(g, G):+6.1f}"
            mean = (w @ res["z0"][ku][nodes]) * np.sin(az) + (w @ res["z0"][kv][nodes]) * np.cos(az)
            cur_rows.append((sid, tag, "mean", mean * 100, rows["M2"]["majorMeanSpeed"], 0.0))
        say(line)

    def summary(ratio, dp):
        return (f"amplitude ratio median {np.median(ratio):.2f} (IQR {np.percentile(ratio, 25):.2f}-"
                f"{np.percentile(ratio, 75):.2f}), |phase| median {np.median(np.abs(dp)):.1f}, "
                f"90th pct {np.percentile(np.abs(dp), 90):.1f}, max {np.abs(dp).max():.1f}  (n={len(dp)})")

    out = {}
    say("\nSUMMARY")
    for n in names:
        r = [x for x in wl_rows if x[1] == n]
        if r:
            out[f"wl {n}"] = summary(np.array([x[2] / x[3] for x in r]), np.array([x[4] for x in r]))
    r = wl_rows
    out["wl all"] = summary(np.array([x[2] / x[3] for x in r]), np.array([x[4] for x in r]))
    cur_named = [x for x in cur_rows if x[2] != "mean"]
    out["cur all"] = summary(np.array([x[3] / x[4] for x in cur_named]), np.array([x[5] for x in cur_named]))
    for n in names:
        r = [x for x in cur_rows if x[2] == n]
        if r:
            out[f"cur {n}"] = summary(np.array([x[3] / x[4] for x in r]), np.array([x[5] for x in r]))
    m = [x for x in cur_rows if x[2] == "mean"]
    if m:
        d = np.array([x[3] - x[4] for x in m])
        out["cur mean"] = (f"model minus NOAA mean flood-axis speed: median {np.median(d):+.1f} cm/s, "
                           f"median |diff| {np.median(np.abs(d)):.1f} cm/s (n={len(d)})")
    for k, v in out.items():
        say(f"  {k:9s} {v}")
    return out, wl_rows, cur_rows


def parse_infer(s):
    out = []
    for item in filter(None, (s or "").split(",")):
        main, inf, r = item.split(":")
        out.append((main, inf, float(r)))
    return out


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("datadir"), p.add_argument("basis"), p.add_argument("mesh")
    p.add_argument("truth"), p.add_argument("out")
    p.add_argument("--fit", help="comma-separated constituents to fit (default: all in the basis)")
    p.add_argument("--infer", help="MAIN:INFERRED:RATIO,... (short records)")
    a = p.parse_args()
    os.makedirs(a.out, exist_ok=True)
    region = sm.select_region(sm.load_mesh(a.mesh))
    res = fit(a.datadir, a.basis, a.fit.split(",") if a.fit else None, parse_infer(a.infer))
    save(res, os.path.join(a.out, "constants.npz"))
    validate(res, region, a.truth)
    print("saved", os.path.join(a.out, "constants.npz"))
