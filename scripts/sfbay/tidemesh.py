"""Read and verify `sfbay.tidemesh` files (format: docs/SFBAY.md), and predict from them.

usage: python tidemesh.py FILE.tidemesh [MESH.nc]     prints a summary and runs the checks;
                                                      with MESH.nc also checks the mesh against sfbaymesh
"""
import os
import struct
import sys
import zlib

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sfbaymesh as sm  # noqa: E402

MAGIC = b"TMSH"
HEADER = struct.Struct("<4sHHIIII8x")  # magic, version, K, N, T, meshID, constantsID, reserved
FIELDS = ("zeta", "ua", "va", "us", "vs")  # mean block order


def write(path, names, region, z0, const):
    """z0: dict field -> (N,); const: dict field -> (K, N, 2) (re, im), fields as in FIELDS."""
    K, N, T = len(names), region.node_count, region.triangle_count
    if K > 24:
        raise ValueError("at most 24 constituents")
    for n in names:
        if len(n) > 8 or not n.isascii():
            raise ValueError(f"bad constituent name {n!r}")
    node, tri = region.node_block(), region.triangle_block()
    mesh_id = zlib.crc32(tri, zlib.crc32(node)) & 0xFFFFFFFF
    mean = np.zeros((N, 8), "<f2")
    for i, k in enumerate(FIELDS):
        mean[:, i] = z0[k]
    zeta = np.asarray(const["zeta"], "<f2")                                        # (K, N, 2)
    cur = lambda u, v: np.concatenate([np.asarray(const[u], "<f2"), np.asarray(const[v], "<f2")], axis=2)  # (K, N, 4)
    for arr in (mean, zeta, cur("ua", "va"), cur("us", "vs")):
        if not np.isfinite(arr.astype(np.float32)).all():
            raise ValueError("non-finite value (f16 overflow or NaN)")
    tail = mean.tobytes() + zeta.tobytes() + cur("ua", "va").tobytes() + cur("us", "vs").tobytes()
    constants_id = zlib.crc32(tail) & 0xFFFFFFFF  # everything after the triangle block
    with open(path + ".tmp", "wb") as f:
        f.write(HEADER.pack(MAGIC, 1, K, N, T, mesh_id, constants_id))
        f.write(b"".join(n.encode("ascii").ljust(8, b" ") for n in names))
        f.write(node)
        f.write(tri)
        f.write(tail)
    os.replace(path + ".tmp", path)
    return mesh_id


class TideMesh:
    def __init__(self, data: bytes):
        magic, version, K, N, T, mesh_id, constants_id = HEADER.unpack_from(data, 0)
        if magic != MAGIC or version != 1:
            raise ValueError("not a version 1 tidemesh")
        if any(data[24:32]):
            raise ValueError("reserved header bytes are not zero")
        self.K, self.N, self.T, self.mesh_id, self.constants_id = K, N, T, mesh_id, constants_id
        tail = HEADER.size + 8 * K + 16 * (N + T)
        if constants_id and zlib.crc32(data[tail:]) & 0xFFFFFFFF != constants_id:
            raise ValueError("constantsID does not match the constant blocks")
        o = HEADER.size
        self.names = [data[o + 8 * i:o + 8 * i + 8].decode("ascii").rstrip(" ") for i in range(K)]
        o += 8 * K

        def take(dtype, count):
            nonlocal o
            a = np.frombuffer(data, dtype, count, o)
            o += a.nbytes
            return a

        self.nodes = take(sm.NODE_DTYPE, N)
        self.tris = take(sm.TRI_DTYPE, T)
        self.node_bytes = self.nodes.tobytes()
        self.tri_bytes = self.tris.tobytes()
        self.mean = take("<f2", N * 8).reshape(N, 8)
        self.zeta = take("<f2", K * N * 2).reshape(K, N, 2)
        self.dm = take("<f2", K * N * 4).reshape(K, N, 4)
        self.sf = take("<f2", K * N * 4).reshape(K, N, 4)
        if o != len(data):
            raise ValueError(f"{len(data) - o} trailing bytes")

    def check(self):
        crc = zlib.crc32(self.tri_bytes, zlib.crc32(self.node_bytes)) & 0xFFFFFFFF
        assert crc == self.mesh_id, f"meshID 0x{self.mesh_id:08x} != CRC 0x{crc:08x}"
        tri = np.stack([self.tris["a"], self.tris["b"], self.tris["c"]], 1).astype(np.int64)
        assert tri.max() < self.N, "triangle refers past the node block"
        x, y = self.nodes["lon"].astype(np.float64), self.nodes["lat"].astype(np.float64)
        cross = ((x[tri[:, 1]] - x[tri[:, 0]]) * (y[tri[:, 2]] - y[tri[:, 0]])
                 - (y[tri[:, 1]] - y[tri[:, 0]]) * (x[tri[:, 2]] - x[tri[:, 0]]))
        assert (cross > 0).all(), f"{(cross <= 0).sum()} triangles not counter-clockwise"
        assert (np.diff(self.nodes["index"].astype(np.int64)) > 0).all(), "node indices not ascending"
        assert not self.mean[:, 5:].any(), "mean block padding not zero"
        for a in (self.mean, self.zeta, self.dm, self.sf):
            assert np.isfinite(a.astype(np.float32)).all(), "non-finite constants"
        return True

    def predict(self, phasors, node):
        """phasors: (K, 2) array of (c, s) from `tide-cli basis` at one instant.
        Returns (zeta, ua, va, us, vs) at local node `node`, including Z0 and mean currents."""
        p = np.asarray(phasors, np.float64)
        z = self.mean[node, 0] + (self.zeta[:, node].astype(np.float64) * p).sum()
        dm = self.dm[:, node].astype(np.float64)
        sf = self.sf[:, node].astype(np.float64)
        return (float(z),
                float(self.mean[node, 1] + (dm[:, 0:2] * p).sum()), float(self.mean[node, 2] + (dm[:, 2:4] * p).sum()),
                float(self.mean[node, 3] + (sf[:, 0:2] * p).sum()), float(self.mean[node, 4] + (sf[:, 2:4] * p).sum()))

    def summary(self):
        return (f"K={self.K} ({' '.join(self.names)}) N={self.N} T={self.T} meshID=0x{self.mesh_id:08x}\n"
                f"lon {self.nodes['lon'].min():.4f}..{self.nodes['lon'].max():.4f} "
                f"lat {self.nodes['lat'].min():.4f}..{self.nodes['lat'].max():.4f} "
                f"depth {self.nodes['depth'].min():.1f}..{self.nodes['depth'].max():.1f} m\n"
                f"M2 zeta amplitude max {np.hypot(*self.zeta[0].astype(np.float32).T).max():.3f} m, "
                f"depth-mean M2 |u| max {np.hypot(*self.dm[0, :, :2].astype(np.float32).T).max():.2f} m/s")


if __name__ == "__main__":
    data = open(sys.argv[1], "rb").read()
    tm = TideMesh(data)
    tm.check()
    print(f"{sys.argv[1]}: {len(data) / 1e6:.2f} MB")
    print(tm.summary())
    if len(sys.argv) > 2:
        r = sm.select_region(sm.load_mesh(sys.argv[2]))
        assert r.node_block() == tm.node_bytes and r.triangle_block() == tm.tri_bytes, "mesh differs from sfbaymesh's"
        assert r.mesh_id == tm.mesh_id
        print("mesh matches sfbaymesh.select_region")
    print("ok")
