"""Shared SFBOFS mesh helpers for the San Francisco Bay model (see docs/SFBAY.md).

Used by the offline packer (pack.py, fetch.py) and the live residual job, so
both cut the same region, number it the same way, move currents from elements
to nodes with the same weights and agree on the meshID. Needs only numpy and
netCDF4.

    import sfbaymesh as sm
    mesh = sm.load_mesh("n000.nc")                 # or an OPeNDAP URL
    region = sm.select_region(mesh)                # docs/SFBAY.md box
    region.mesh_id                                 # CRC-32 of node + triangle blocks
    ds = netCDF4.Dataset(url)
    fields = sm.extract(ds, region)                # dict of per-node float32 arrays

API (stable):
    BOX                                  (lon_min, lon_max, lat_min, lat_max)
    load_mesh(source) -> Mesh            lon/lat (-180..180), h, nv (3, E) 0-based, lonc/latc
    select_region(mesh, box=BOX) -> Region
    Region.nodes          (N,) SFBOFS node indices (0-based, ascending); local node i = nodes[i]
    Region.lon/lat/depth  (N,) float32, exactly as stored in the tidemesh
    Region.triangles      (T, 3) local node indices, counter-clockwise in lon/lat
    Region.elements       (T,) SFBOFS element index of each triangle (ascending)
    Region.node_span      slice of SFBOFS node indices covering Region.nodes
    Region.elem_span      slice of SFBOFS element indices covering every element that
                          touches a kept node (what elements_to_nodes needs)
    Region.elements_to_nodes(values)     values[..., elem_span] -> [..., N], area-weighted mean
    Region.node_block() / triangle_block() / mesh_id
    extract(ds, region, time_index=0) -> {"zeta","ua","va","us","vs"} per node (float32)
"""
from __future__ import annotations

import zlib
from dataclasses import dataclass, field

import numpy as np

BOX = (-122.80, -122.30, 37.70, 37.95)  # lon_min, lon_max, lat_min, lat_max

#: Depth-mean current = mean of these sigma layers; surface = layer 0.
DEPTH_MEAN_LAYERS = (2, 7, 12, 17)
SURFACE_LAYER = 0

#: SFBOFS time origin (seconds since 2013-01-01T00:00:00Z) in unix seconds.
EPOCH_2013 = 1356998400

NODE_DTYPE = np.dtype([("lon", "<f4"), ("lat", "<f4"), ("depth", "<f4"), ("index", "<u4")])
TRI_DTYPE = np.dtype([("a", "<u4"), ("b", "<u4"), ("c", "<u4"), ("element", "<u4")])

_EARTH_RADIUS = 6_371_000.0


@dataclass
class Mesh:
    lon: np.ndarray   # (Nn,) float64, degrees east in -180..180
    lat: np.ndarray   # (Nn,)
    h: np.ndarray     # (Nn,) depth, m positive down
    nv: np.ndarray    # (3, E) 0-based node indices
    lonc: np.ndarray  # (E,)
    latc: np.ndarray  # (E,)


def _wrap(lon):
    lon = np.asarray(lon, np.float64)
    return np.where(lon > 180, lon - 360, lon)


def load_mesh(source) -> Mesh:
    """Mesh from a SFBOFS fields/stations file path, OPeNDAP URL or open netCDF4.Dataset."""
    import netCDF4

    ds = source if isinstance(source, netCDF4.Dataset) else netCDF4.Dataset(source)
    try:
        nv = np.asarray(ds["nv"][:], np.int64) - 1  # FVCOM is 1-based
        return Mesh(lon=_wrap(ds["lon"][:]), lat=np.asarray(ds["lat"][:], np.float64),
                    h=np.asarray(ds["h"][:], np.float64), nv=nv,
                    lonc=_wrap(ds["lonc"][:]), latc=np.asarray(ds["latc"][:], np.float64))
    finally:
        if ds is not source:
            ds.close()


@dataclass
class Region:
    nodes: np.ndarray
    lon: np.ndarray
    lat: np.ndarray
    depth: np.ndarray
    triangles: np.ndarray
    elements: np.ndarray
    node_span: slice
    elem_span: slice
    # Averaging operator as (node, element-in-span, weight) triples, node-sorted.
    _avg_node: np.ndarray = field(repr=False)
    _avg_elem: np.ndarray = field(repr=False)
    _avg_w: np.ndarray = field(repr=False)

    @property
    def node_count(self) -> int:
        return len(self.nodes)

    @property
    def triangle_count(self) -> int:
        return len(self.elements)

    def elements_to_nodes(self, values) -> np.ndarray:
        """Area-weighted mean over the elements touching each node.

        `values` holds element values for `elem_span` on its last axis
        (shape [..., elem_span.stop - elem_span.start]); returns [..., N] float64.
        Every element of the full mesh touching a kept node counts, including
        ones that are not themselves kept, so box-edge nodes are not biased.
        """
        v = np.asarray(values, np.float64)
        contrib = v[..., self._avg_elem] * self._avg_w
        starts = np.flatnonzero(np.r_[True, np.diff(self._avg_node) != 0])
        return np.add.reduceat(contrib, starts, axis=-1)

    def node_block(self) -> bytes:
        a = np.zeros(self.node_count, NODE_DTYPE)
        a["lon"], a["lat"], a["depth"], a["index"] = self.lon, self.lat, self.depth, self.nodes
        return a.tobytes()

    def triangle_block(self) -> bytes:
        a = np.zeros(self.triangle_count, TRI_DTYPE)
        a["a"], a["b"], a["c"] = self.triangles.T
        a["element"] = self.elements
        return a.tobytes()

    @property
    def mesh_id(self) -> int:
        """CRC-32 (IEEE, zlib) of the node block followed by the triangle block."""
        return zlib.crc32(self.triangle_block(), zlib.crc32(self.node_block())) & 0xFFFFFFFF


def _local_xy(lon, lat, lat0):
    """Local equirectangular metres (good to <0.1 % over the bay)."""
    k = np.radians(1.0) * _EARTH_RADIUS
    return lon * k * np.cos(np.radians(lat0)), lat * k


def select_region(mesh: Mesh, box=BOX) -> Region:
    lon0, lon1, lat0, lat1 = box
    keep = (mesh.lon >= lon0) & (mesh.lon <= lon1) & (mesh.lat >= lat0) & (mesh.lat <= lat1)
    nodes = np.flatnonzero(keep)
    local = np.full(len(mesh.lon), -1, np.int64)
    local[nodes] = np.arange(len(nodes))

    nv = mesh.nv  # (3, E)
    elements = np.flatnonzero(keep[nv].all(axis=0))
    tri = local[nv[:, elements]].T.copy()  # (T, 3)

    # Stored coordinates are float32; orient against exactly those.
    lon32 = mesh.lon[nodes].astype(np.float32)
    lat32 = mesh.lat[nodes].astype(np.float32)
    x, y = lon32.astype(np.float64), lat32.astype(np.float64)
    cross = ((x[tri[:, 1]] - x[tri[:, 0]]) * (y[tri[:, 2]] - y[tri[:, 0]])
             - (y[tri[:, 1]] - y[tri[:, 0]]) * (x[tri[:, 2]] - x[tri[:, 0]]))
    cw = cross < 0
    tri[cw, 1], tri[cw, 2] = tri[cw, 2].copy(), tri[cw, 1].copy()

    # Averaging weights: every element of the full mesh that touches a kept node.
    touch = np.flatnonzero(keep[nv].any(axis=0))
    elem_span = slice(int(touch.min()), int(touch.max()) + 1)
    mx, my = _local_xy(mesh.lon, mesh.lat, 0.5 * (lat0 + lat1))
    a, b, c = nv[:, touch]
    area = 0.5 * np.abs((mx[b] - mx[a]) * (my[c] - my[a]) - (my[b] - my[a]) * (mx[c] - mx[a]))
    pn, pe, pw = [], [], []
    for corner in (a, b, c):
        m = keep[corner]
        pn.append(local[corner[m]])
        pe.append(touch[m] - elem_span.start)
        pw.append(area[m])
    pn, pe, pw = np.concatenate(pn), np.concatenate(pe), np.concatenate(pw)
    order = np.lexsort((pe, pn))
    pn, pe, pw = pn[order], pe[order], pw[order]
    total = np.bincount(pn, weights=pw, minlength=len(nodes))
    if (total <= 0).any() or len(np.unique(pn)) != len(nodes):
        raise ValueError("a kept node touches no element of positive area")
    pw = pw / total[pn]

    return Region(nodes=nodes, lon=lon32, lat=lat32, depth=mesh.h[nodes].astype(np.float32),
                  triangles=tri.astype(np.uint32), elements=elements.astype(np.uint32),
                  node_span=slice(int(nodes.min()), int(nodes.max()) + 1), elem_span=elem_span,
                  _avg_node=pn, _avg_elem=pe, _avg_w=pw)


def extract(ds, region: Region, time_index: int = 0) -> dict:
    """Read one time step of an open SFBOFS fields dataset (local or OPeNDAP) for the region.

    Slices only the region's contiguous spans. Returns float32 arrays on the
    region's nodes: zeta (m), ua/va depth-mean u/v and us/vs surface u/v (m/s),
    plus "time" (unix seconds, float).
    """
    ns, es = region.node_span, region.elem_span
    t = time_index
    zeta = np.asarray(ds["zeta"][t, ns], np.float64)[region.nodes - ns.start]
    us = np.asarray(ds["u"][t, SURFACE_LAYER, es], np.float64)
    vs = np.asarray(ds["v"][t, SURFACE_LAYER, es], np.float64)
    lay = list(DEPTH_MEAN_LAYERS)
    step = lay[1] - lay[0]
    if all(b - a == step for a, b in zip(lay, lay[1:])):  # one strided request
        sl = slice(lay[0], lay[-1] + 1, step)
        ua = np.asarray(ds["u"][t, sl, es], np.float64).mean(axis=0)
        va = np.asarray(ds["v"][t, sl, es], np.float64).mean(axis=0)
    else:
        ua = np.mean([np.asarray(ds["u"][t, k, es], np.float64) for k in lay], axis=0)
        va = np.mean([np.asarray(ds["v"][t, k, es], np.float64) for k in lay], axis=0)
    out = {"zeta": zeta}
    for k, v in (("ua", ua), ("va", va), ("us", us), ("vs", vs)):
        out[k] = region.elements_to_nodes(v)
    out = {k: v.astype(np.float32) for k, v in out.items()}
    out["time"] = _unix_time(ds["time"], t)
    return out


def _unix_time(var, t):
    units = getattr(var, "units", "")
    if units.startswith("seconds since 2013-01-01"):
        return float(var[t]) + EPOCH_2013
    import netCDF4

    d = netCDF4.num2date(var[t], units, only_use_cftime_datetimes=False, only_use_python_datetimes=True)
    import calendar

    return calendar.timegm(d.timetuple()) + d.microsecond * 1e-6


if __name__ == "__main__":
    import sys

    r = select_region(load_mesh(sys.argv[1]))
    print(f"N={r.node_count} T={r.triangle_count} node_span={r.node_span.start}:{r.node_span.stop} "
          f"elem_span={r.elem_span.start}:{r.elem_span.stop} meshID=0x{r.mesh_id:08x}")
