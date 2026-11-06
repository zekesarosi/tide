"""Pack fitted constants into App/Resources/Bay/sfbay.tidemesh (format: docs/SFBAY.md).

usage: python pack.py CONSTANTS.npz MESH.nc OUT.tidemesh [BASIS.csv]

CONSTANTS.npz comes from analyze.py; its constituent order becomes the file's.
After writing, reads the file back, checks it (tidemesh.py) and compares f16
predictions with the float constants (at every BASIS.csv row if given).
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import analyze  # noqa: E402
import sfbaymesh as sm  # noqa: E402
import tidemesh  # noqa: E402

if __name__ == "__main__":
    cpath, mesh, out = sys.argv[1:4]
    basis = sys.argv[4] if len(sys.argv) > 4 else None
    res = analyze.load_constants(cpath)
    region = sm.select_region(sm.load_mesh(mesh))
    n = len(res["z0"]["zeta"])
    if n != region.node_count:
        sys.exit(f"constants have {n} nodes, region has {region.node_count}")
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    mesh_id = tidemesh.write(out, res["names"], region, res["z0"], res["const"])

    data = open(out, "rb").read()
    tm = tidemesh.TideMesh(data)
    tm.check()
    assert tm.names == res["names"] and tm.mesh_id == mesh_id == region.mesh_id
    # f16 quantisation of the constants themselves
    worst = {k: float(np.abs(np.asarray(v, np.float32) - tm_v.astype(np.float32)).max())
             for k, v, tm_v in [("zeta", res["const"]["zeta"], tm.zeta),
                                ("ua", res["const"]["ua"], tm.dm[..., 0:2]),
                                ("vs", res["const"]["vs"], tm.sf[..., 2:4])]}
    print("max f16 quantisation:", ", ".join(f"{k} {v * 1000:.2f} mm(/s)" for k, v in worst.items()))
    if basis:
        raw = np.genfromtxt(basis, delimiter=",", names=True, deletechars="")
        P = np.stack([np.stack([raw[f"{c}_c"], raw[f"{c}_s"]], 1) for c in res["names"]], 1)  # (H, K, 2)
        rows = np.linspace(0, len(P) - 1, min(len(P), 200)).astype(int)
        rng = np.random.default_rng(1)
        nodes = rng.choice(n, 200, replace=False)
        err = []
        for node in nodes:
            exact_z = res["z0"]["zeta"][node] + np.einsum("hkc,kc->h", P[rows], res["const"]["zeta"][:, node])
            got = [tm.predict(P[h], node)[0] for h in rows]
            err.append(np.abs(np.array(got) - exact_z).max())
        print(f"prediction round trip (zeta, f16 vs float, 200 nodes x {len(rows)} hours): max {max(err) * 1000:.2f} mm")
    print(f"wrote {out}: {len(data) / 1e6:.2f} MB, K={tm.K} N={tm.N} T={tm.T} meshID=0x{mesh_id:08x}")
    print(f"constituents: {' '.join(tm.names)}; fitted on {res['hours']} hours")
