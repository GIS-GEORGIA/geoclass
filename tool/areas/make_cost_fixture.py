#!/usr/bin/env python3
"""Writes test/fixtures/least_cost/: a piece of the built Kazbegi grid, and the least-cost answers for it
from GRASS GIS and from SciPy, for test/least_cost_test.dart.

    python3 tool/areas/build_area.py kazbegi && python3 tool/areas/make_cost_fixture.py

Two cost models, as lib/terrain/least_cost.dart has them:
    slope    each cell costs 1 + (slope / theta)^2 per metre, slope from gdaldem (Horn); a move between two
             neighbours costs the mean of their costs times the distance (30 m, or 30 m x sqrt 2 diagonally).
             The reference is GRASS r.cost (cumulative cost, 8 neighbours) and r.drain (the path), and SciPy's
             Dijkstra on the same weights.
    tobler   a move takes distance / v minutes, v = 6 exp(-3.5 |dh / distance + 0.05|) km/h (Tobler's hiking
             function), so uphill and downhill differ. GRASS and GDAL have no such tool: the reference is
             SciPy's Dijkstra on weights made here with NumPy.

Files:
    area.json             the area's metadata, with the size and sha256 changed to the piece's
    dem.u16               the piece, raw UInt16 little-endian
    expected.json         start and end cells; per model: the end's cost, r.drain's path (slope only)
    slope_cost.f64        the cumulative cost from the start, per cell, metres (NaN where unreachable)
    tobler_cost.f64       the same in minutes
    slope.f32             gdaldem's slope, degrees (NaN at the edge): the slope r.cost's costs were made from
"""

import hashlib
import gzip
import json
import math
import os
import shutil
import subprocess
import tempfile

import numpy as np
from osgeo import gdal, osr
from scipy.sparse import coo_matrix
from scipy.sparse.csgraph import dijkstra

import build_area as ba

gdal.UseExceptions()

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
SOURCE = os.path.join(ROOT, 'build', 'areas', 'kazbegi', '1')
OUT = os.path.join(ROOT, 'test', 'fixtures', 'least_cost')

# Steep ground west of Stepantsminda: a 160 x 120 piece; a route across a ridge.
ROW0, COL0, W, H = 150, 230, 160, 120
START, END = (100, 12), (14, 146)
THETA = 15.0

# Neighbours: (row, col) offsets.
STEPS = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]


def tif(path, data, bounds, nodata=-9999.0):
    h, w = data.shape
    ds = gdal.GetDriverByName('GTiff').Create(path, w, h, 1, gdal.GDT_Float64)
    ds.SetGeoTransform((bounds[0], ba.CELL, 0, bounds[3], 0, -ba.CELL))
    srs = osr.SpatialReference()
    srs.SetFromUserInput(ba.CRS)
    ds.SetProjection(srs.ExportToWkt())
    band = ds.GetRasterBand(1)
    band.SetNoDataValue(nodata)
    band.WriteArray(np.where(np.isnan(data), nodata, data))
    ds = None


def read(path):
    ds = gdal.Open(path)
    band = ds.GetRasterBand(1)
    a = band.ReadAsArray().astype(np.float64)
    nd = band.GetNoDataValue()
    if nd is not None:
        a[a == nd] = np.nan
    return a


def gdal_slope(heights, bounds, work):
    src = os.path.join(work, 'dem.tif')
    tif(src, heights, bounds)
    out = os.path.join(work, 'slope.tif')
    gdal.DEMProcessing(out, src, 'slope')  # Horn, degrees, no edges: as lib/terrain/slope.dart
    s = read(out)
    s[s == -9999] = np.nan
    return s


def grass_cost(cost, bounds, work):
    """r.cost from START over the per-cell cost, and r.drain's path back from END."""
    path = os.path.join(work, 'cost.tif')
    tif(path, cost, bounds)
    centre = lambda rc: (bounds[0] + (rc[1] + 0.5) * ba.CELL, bounds[3] - (rc[0] + 0.5) * ba.CELL)
    (sx, sy), (ex, ey) = centre(START), centre(END)
    steps = [
        f'r.in.gdal -o input={path} output=cost --quiet',
        'g.region raster=cost',
        f'r.cost input=cost output=acc outdir=dir start_coordinates={sx},{sy} --quiet',
        f'r.drain -d input=acc direction=dir output=path start_coordinates={ex},{ey} --quiet',
        f'r.out.gdal input=acc output={work}/acc.tif type=Float64 --quiet -c',
        f'r.out.gdal input=path output={work}/path.tif type=Int32 nodata=0 --quiet -c',
    ]
    script = os.path.join(work, 'run.sh')
    with open(script, 'w') as f:
        f.write('set -e\n' + '\n'.join(steps) + '\n')
    subprocess.run(['grass', '--tmp-location', path, '--exec', 'bash', script], check=True, capture_output=True, text=True)
    acc = read(os.path.join(work, 'acc.tif'))
    drained = read(os.path.join(work, 'path.tif'))
    return acc, np.argwhere(np.nan_to_num(drained) > 0)


def scipy_cost(weight):
    """Dijkstra from START, where weight(a, b, distance) gives a move's cost or NaN where it can't be made."""
    rows, cols, vals = [], [], []
    for dr, dc in STEPS:
        d = ba.CELL * (math.sqrt(2) if dr and dc else 1)
        r0, r1 = max(0, -dr), H - max(0, dr)
        c0, c1 = max(0, -dc), W - max(0, dc)
        a = np.arange(H * W).reshape(H, W)[r0:r1, c0:c1]
        b = np.arange(H * W).reshape(H, W)[r0 + dr : r1 + dr, c0 + dc : c1 + dc]
        w = weight(a.ravel(), b.ravel(), d)
        ok = ~np.isnan(w)
        rows.append(a.ravel()[ok])
        cols.append(b.ravel()[ok])
        vals.append(w[ok])
    g = coo_matrix((np.concatenate(vals), (np.concatenate(rows), np.concatenate(cols))), shape=(H * W, H * W)).tocsr()
    dist = dijkstra(g, directed=True, indices=START[0] * W + START[1])
    dist[np.isinf(dist)] = np.nan
    return dist.reshape(H, W)


def main():
    with open(os.path.join(SOURCE, 'area.json'), encoding='utf-8') as f:
        meta = json.load(f)
    with open(os.path.join(SOURCE, 'dem.u16.gz'), 'rb') as f:
        full = np.frombuffer(gzip.decompress(f.read()), dtype='<u2').reshape(meta['height'], meta['width'])
    piece = full[ROW0 : ROW0 + H, COL0 : COL0 + W].copy()
    x0, _, _, y1 = meta['bounds']
    left, top = x0 + COL0 * ba.CELL, y1 - ROW0 * ba.CELL
    bounds = [left, top - H * ba.CELL, left + W * ba.CELL, top]
    # As the app reads them: steps × 0.1 in double precision (build_area.decode gives float32).
    heights = piece.astype(np.float64) * ba.SCALE
    heights[piece == ba.NODATA] = np.nan

    work = tempfile.mkdtemp(prefix='geoclass-cost-')
    try:
        slope = gdal_slope(heights, bounds, work)
        cell_cost = 1 + (slope / THETA) ** 2  # NaN where there is no slope
        acc_cells, drained = grass_cost(cell_cost, bounds, work)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    # r.cost counts in cells (a move east or west is 1); the app counts in metres.
    grass_slope = acc_cells * ba.CELL

    flat = cell_cost.ravel()
    slope_acc = scipy_cost(lambda a, b, d: (flat[a] + flat[b]) / 2 * d)
    hs = heights.ravel()

    def tobler(a, b, d):
        v = 6 * np.exp(-3.5 * np.abs((hs[b] - hs[a]) / d + 0.05))  # km/h
        return d / (v * 1000 / 60)  # minutes

    tobler_acc = scipy_cost(tobler)

    both = ~np.isnan(grass_slope) & ~np.isnan(slope_acc)
    gap = np.nanmax(np.abs(grass_slope[both] - slope_acc[both]) / np.maximum(1, slope_acc[both]))
    assert (np.isnan(grass_slope) == np.isnan(slope_acc)).all(), 'GRASS and SciPy reach different cells'
    print(f'r.cost and SciPy agree to {gap:.2e} (relative)')

    raw = piece.tobytes()
    valid = piece[piece != ba.NODATA]
    meta.update(id='least-cost-fixture', bounds=bounds, width=W, height=H,
                min=round(float(valid.min()) * ba.SCALE, 1), max=round(float(valid.max()) * ba.SCALE, 1))
    meta['grid'] = dict(meta['grid'], file='dem.u16.gz', sha256=hashlib.sha256(raw).hexdigest())
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, 'area.json'), 'w', encoding='utf-8') as f:
        json.dump(meta, f, ensure_ascii=False, indent=1)
        f.write('\n')
    with open(os.path.join(OUT, 'dem.u16'), 'wb') as f:
        f.write(raw)
    grass_slope.astype('<f8').tofile(os.path.join(OUT, 'slope_cost.f64'))
    slope.astype('<f4').tofile(os.path.join(OUT, 'slope.f32'))
    tobler_acc.astype('<f8').tofile(os.path.join(OUT, 'tobler_cost.f64'))
    # r.drain lists the path's cells; order them from the end back to the start by following the cost down.
    path = [list(END)]
    cells = {tuple(c) for c in drained.tolist()}
    while tuple(path[-1]) != START:
        r, c = path[-1]
        nxt = min(((r + dr, c + dc) for dr, dc in STEPS if (r + dr, c + dc) in cells and [r + dr, c + dc] not in path),
                  key=lambda rc: grass_slope[rc])
        path.append(list(nxt))
    expected = {
        'start': list(START),
        'end': list(END),
        'theta': THETA,
        'slope': {'cost': float(grass_slope[END]), 'path': path[::-1], 'source': 'GRASS GIS 8.3.2 r.cost, r.drain -d'},
        'tobler': {'cost': float(tobler_acc[END]), 'source': f'SciPy {__import__("scipy").__version__} dijkstra'},
    }
    with open(os.path.join(OUT, 'expected.json'), 'w', encoding='utf-8') as f:
        json.dump(expected, f, indent=1)
        f.write('\n')
    print(f'wrote {OUT}: slope cost {grass_slope[END]:.1f} m over {len(path)} cells; tobler {tobler_acc[END]:.1f} min')


if __name__ == '__main__':
    main()
