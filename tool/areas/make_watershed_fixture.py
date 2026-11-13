#!/usr/bin/env python3
"""Writes test/fixtures/watershed/: a piece of the built Kutaisi–Rioni grid, GRASS's flow directions on it,
GRASS's basins at a few outlets, and PROJ's geodesic and UTM numbers for the app's area sums.

    python3 tool/areas/build_area.py kutaisi-rioni && python3 tool/areas/make_watershed_fixture.py

Files:
    area.json        the area's metadata, with the size and sha256 changed to the piece's
    dem.u16          the piece, raw UInt16 little-endian
    flow.u8          tool/areas/build_watershed.py's directions for the piece (r.watershed -s), raw
    expected.json    basins: for each outlet, r.water.outlet's basin as row runs [row, first col, end col);
                     polygons: geodesic area and perimeter on WGS84 (PROJ's geod, Karney's method);
                     scale: the UTM point scale factor at points (PROJ's factors)
"""

import gzip
import hashlib
import json
import os

import numpy as np
from osgeo import osr
from pyproj import Geod, Proj

import build_area as ba
import build_watershed as bw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
SOURCE = os.path.join(ROOT, 'build', 'areas', 'kutaisi-rioni', '1')
OUT = os.path.join(ROOT, 'test', 'fixtures', 'watershed')

# Hills north of Kutaisi: a 150 × 120 piece.
ROW0, COL0, W, H = 40, 300, 150, 120

OFFSETS = [(-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1)]


def accumulation(flow):
    """Cells draining through each cell, itself included, from the directions alone."""
    h, w = flow.shape
    target = np.full(h * w, -1, dtype=np.int64)
    for r in range(h):
        for c in range(w):
            k = flow[r, c]
            if k == bw.NONE:
                continue
            dr, dc = OFFSETS[k]
            if 0 <= r + dr < h and 0 <= c + dc < w:
                target[r * w + c] = (r + dr) * w + c + dc
    indeg = np.bincount(target[target >= 0], minlength=h * w)
    acc = np.ones(h * w, dtype=np.int64)
    queue = list(np.nonzero(indeg == 0)[0])
    while queue:
        i = queue.pop()
        t = target[i]
        if t >= 0:
            acc[t] += acc[i]
            indeg[t] -= 1
            if indeg[t] == 0:
                queue.append(t)
    return acc.reshape(h, w)


def runs(mask):
    out = []
    for r in range(mask.shape[0]):
        row = mask[r]
        c = 0
        while c < row.size:
            if row[c]:
                e = c
                while e < row.size and row[e]:
                    e += 1
                out.append([r, c, e])
                c = e
            else:
                c += 1
    return out


def main():
    with open(os.path.join(SOURCE, 'area.json'), encoding='utf-8') as f:
        meta = json.load(f)
    with open(os.path.join(SOURCE, 'dem.u16.gz'), 'rb') as f:
        full = np.frombuffer(gzip.decompress(f.read()), dtype='<u2').reshape(meta['height'], meta['width'])
    piece = full[ROW0 : ROW0 + H, COL0 : COL0 + W].copy()
    x0, _, _, y1 = meta['bounds']
    left = x0 + COL0 * ba.CELL
    top = y1 - ROW0 * ba.CELL
    bounds = [left, top - H * ba.CELL, left + W * ba.CELL, top]
    heights = ba.decode(piece).astype(np.float64)

    drainage, _, _ = bw.grass_watershed(heights, bounds, ba.CELL)
    flow = bw.encode_flow(drainage)
    acc = accumulation(flow)

    # Outlets: streams of three sizes whose basins stay clear of the piece's edge.
    edge = np.zeros(flow.shape, dtype=bool)
    edge[0, :] = edge[-1, :] = edge[:, 0] = edge[:, -1] = True
    chosen, sizes = [], []
    for want in (300, 1200, 3000):
        order = np.argsort(np.abs(acc.ravel() - want))
        for i in order[:2000]:
            r, c = divmod(int(i), W)
            _, _, (basin,) = bw.grass_watershed(heights, bounds, ba.CELL, [(r, c)])
            if not (basin.astype(bool) & edge).any():
                chosen.append((r, c))
                sizes.append(int(basin.sum()))
                break
    _, _, basins = bw.grass_watershed(heights, bounds, ba.CELL, chosen)

    utm = osr.SpatialReference()
    utm.SetFromUserInput(ba.CRS)
    wgs = osr.SpatialReference()
    wgs.ImportFromEPSG(4326)
    wgs.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)
    to_wgs = osr.CoordinateTransformation(utm, wgs)

    def lonlat(r, c):
        x = bounds[0] + c * ba.CELL
        y = bounds[3] - r * ba.CELL
        lon, lat, _ = to_wgs.TransformPoint(x, y)
        return [lon, lat]

    geod = Geod(ellps='WGS84')
    polygons = []
    for corners in (
        [(10, 10), (10, 60), (70, 60), (70, 10)],
        [(5, 20), (30, 140), (110, 120), (90, 30), (50, 60)],
        [(0, 0), (0, 150), (120, 150), (120, 0)],
    ):
        pts = [lonlat(r, c) for r, c in corners]
        area, perimeter = geod.polygon_area_perimeter([p[0] for p in pts], [p[1] for p in pts])
        polygons.append({'lonlat': pts, 'area_m2': abs(area), 'perimeter_m': perimeter})
    proj = Proj(ba.CRS)
    scale = []
    for lon, lat in ([42.6, 42.3], [43.5, 42.0], [45.0, 41.5], [42.7, 42.25]):
        scale.append({'lonlat': [lon, lat], 'k': proj.get_factors(lon, lat).meridional_scale})

    raw = piece.tobytes()
    valid = piece[piece != ba.NODATA]
    meta.update(
        id='watershed-fixture',
        bounds=bounds,
        width=W,
        height=H,
        min=round(float(valid.min()) * ba.SCALE, 1),
        max=round(float(valid.max()) * ba.SCALE, 1),
    )
    meta['grid'] = dict(meta['grid'], file='dem.u16.gz', sha256=hashlib.sha256(raw).hexdigest())
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, 'area.json'), 'w', encoding='utf-8') as f:
        json.dump(meta, f, ensure_ascii=False, indent=1)
        f.write('\n')
    with open(os.path.join(OUT, 'dem.u16'), 'wb') as f:
        f.write(raw)
    with open(os.path.join(OUT, 'flow.u8'), 'wb') as f:
        f.write(flow.tobytes())
    expected = {
        'basins': [
            {'outlet': [r, c], 'cells': int(b.sum()), 'runs': runs(b)} for (r, c), b in zip(chosen, basins)
        ],
        'polygons': polygons,
        'scale': scale,
    }
    with open(os.path.join(OUT, 'expected.json'), 'w', encoding='utf-8') as f:
        json.dump(expected, f, indent=1)
        f.write('\n')
    print(f'wrote {OUT}: {W}×{H} cells, outlets {chosen} with basins of {sizes} cells')


if __name__ == '__main__':
    main()
