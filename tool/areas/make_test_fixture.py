#!/usr/bin/env python3
"""Writes test/fixtures/terrain/: a small piece of the built Kazbegi grid plus what GDAL says about it.

    python3 tool/areas/build_area.py kazbegi && python3 tool/areas/make_test_fixture.py

The app's tests read these files to check its own grid reading, bilinear heights and UTM conversion
against GDAL, without the network and without the full package (build/ is not in git).

Files:
    area.json    the area's metadata, with the size and sha256 changed to the piece's
    dem.u16      the piece, raw UInt16 little-endian (not compressed: the client gets it decoded)
    expected.json  heights at points (GDAL bilinear) and the UTM position of WGS84 points (GDAL/PROJ)
    hillshade.u8   gdaldem hillshade of the piece (defaults: Horn, azimuth 315°, altitude 45°), one byte per cell
    viewshed.json  gdal_viewshed of the piece from a few observers (Edge mode, as the CLI runs it): one '1' (seen)
                   or '0' per cell, rows north to south
    slope.f32      gdaldem slope of the piece (defaults: Horn, degrees), float32 little-endian, -9999 for none
    profile.json   a three-vertex line across the piece (through the empty cell) and its profile: GDAL bilinear
                   heights every half cell, geodesic distances (PROJ's geod), and the summary numbers
"""

import gzip
import hashlib
import json
import os

import numpy as np
from pyproj import Geod
from osgeo import gdal, osr

import build_area as ba

gdal.UseExceptions()

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
SOURCE = os.path.join(ROOT, 'build', 'areas', 'kazbegi', '1')
OUT = os.path.join(ROOT, 'test', 'fixtures', 'terrain')

# A 40 × 30 piece around Gergeti Trinity church; one cell made "no data" to test that case too.
ROW0, COL0, W, H = 200, 400, 40, 30
HOLE = (12, 20)


def main():
    with open(os.path.join(SOURCE, 'area.json'), encoding='utf-8') as f:
        meta = json.load(f)
    with open(os.path.join(SOURCE, 'dem.u16.gz'), 'rb') as f:
        full = np.frombuffer(gzip.decompress(f.read()), dtype='<u2').reshape(meta['height'], meta['width'])
    piece = full[ROW0 : ROW0 + H, COL0 : COL0 + W].copy()
    piece[HOLE] = ba.NODATA
    raw = piece.tobytes()

    x0, _, _, y1 = meta['bounds']
    left = x0 + COL0 * ba.CELL
    top = y1 - ROW0 * ba.CELL
    bounds = [left, top - H * ba.CELL, left + W * ba.CELL, top]
    valid = piece[piece != ba.NODATA]
    meta.update(
        id='fixture',
        bounds=bounds,
        width=W,
        height=H,
        min=round(float(valid.min()) * ba.SCALE, 1),
        max=round(float(valid.max()) * ba.SCALE, 1),
    )
    meta['grid'] = dict(meta['grid'], file='dem.u16.gz', sha256=hashlib.sha256(raw).hexdigest())

    # The piece as a GeoTIFF in metres, so GDAL can be asked about it.
    heights = ba.decode(piece)
    ds = gdal.GetDriverByName('MEM').Create('', W, H, 1, gdal.GDT_Float32)
    ds.SetGeoTransform((bounds[0], ba.CELL, 0, bounds[3], 0, -ba.CELL))
    utm = osr.SpatialReference()
    utm.SetFromUserInput(ba.CRS)
    ds.SetProjection(utm.ExportToWkt())
    band = ds.GetRasterBand(1)
    band.SetNoDataValue(-9999)
    band.WriteArray(np.where(np.isnan(heights), -9999, heights))

    def gdal_bilinear(x, y):
        """GDAL's bilinear height at (x, y): warp to one tiny cell centred there."""
        half = 0.005
        out = gdal.Warp('', ds, format='MEM', outputBounds=(x - half, y - half, x + half, y + half),
                        xRes=2 * half, yRes=2 * half, resampleAlg='bilinear', dstNodata=-9999,
                        outputType=gdal.GDT_Float64)
        v = float(out.GetRasterBand(1).ReadAsArray()[0, 0])
        return None if v == -9999 else round(v, 4)

    rng = np.random.default_rng(7)
    points = []
    # Cell centres, fractions between them, and points next to the empty cell.
    for row, col in [(0, 0), (5, 7), (29, 39), (12, 19), (11, 20), (13, 21)]:
        points.append((bounds[0] + (col + 0.5) * ba.CELL, bounds[3] - (row + 0.5) * ba.CELL))
    for _ in range(30):
        points.append((bounds[0] + rng.uniform(1, W - 1) * ba.CELL, bounds[3] - rng.uniform(1, H - 1) * ba.CELL))
    # Inside the empty cell, then in the cells around it, where one of the four neighbours is empty.
    for dx, dy in [(0.37, 0.81), (0.5, 0.5), (0.9, 0.1), (1.2, 0.5), (0.5, 1.3), (-0.3, -0.2), (1.4, 1.1)]:
        points.append((bounds[0] + (HOLE[1] + dx) * ba.CELL, bounds[3] - (HOLE[0] + dy) * ba.CELL))
    heights_at = [{'x': round(x, 3), 'y': round(y, 3), 'h': gdal_bilinear(round(x, 3), round(y, 3))} for x, y in points]

    wgs = osr.SpatialReference()
    wgs.ImportFromEPSG(4326)
    wgs.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)
    to_utm = osr.CoordinateTransformation(wgs, utm)
    places = [('Gergeti Trinity', 44.6203, 42.6625), ('Kazbek summit', 44.5181, 42.6966), ('Box corner', 44.48, 42.6)]
    utm_of = []
    for name, lon, lat in places:
        x, y = to_utm.TransformPoint(lon, lat)[:2]
        utm_of.append({'name': name, 'lat': lat, 'lon': lon, 'x': round(x, 4), 'y': round(y, 4)})

    # gdaldem's defaults; edge cells and cells next to the empty one come out as 0 (no data).
    shaded = gdal.DEMProcessing('', ds, 'hillshade', format='MEM')
    shade = shaded.GetRasterBand(1).ReadAsArray().astype(np.uint8)

    # gdaldem's defaults again: Horn, degrees; edge cells and cells next to the empty one are -9999.
    sloped = gdal.DEMProcessing('', ds, 'slope', format='MEM')
    slope = sloped.GetRasterBand(1).ReadAsArray().astype('<f4')

    profile = make_profile(bounds, to_utm, osr.CoordinateTransformation(utm, wgs), gdal_bilinear)
    views = make_viewsheds(piece, bounds, utm)

    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, 'slope.f32'), 'wb') as f:
        f.write(slope.tobytes())
    with open(os.path.join(OUT, 'viewshed.json'), 'w', encoding='utf-8') as f:
        json.dump(views, f, indent=1)
        f.write('\n')
    with open(os.path.join(OUT, 'profile.json'), 'w', encoding='utf-8') as f:
        json.dump(profile, f, indent=1)
        f.write('\n')
    with open(os.path.join(OUT, 'hillshade.u8'), 'wb') as f:
        f.write(shade.tobytes())
    with open(os.path.join(OUT, 'area.json'), 'w', encoding='utf-8') as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
        f.write('\n')
    with open(os.path.join(OUT, 'dem.u16'), 'wb') as f:
        f.write(raw)
    with open(os.path.join(OUT, 'expected.json'), 'w', encoding='utf-8') as f:
        json.dump({'heights': heights_at, 'utm': utm_of, 'gdal': gdal.__version__}, f, indent=1)
        f.write('\n')
    print(f'wrote {OUT}: {W}×{H} cells, {len(heights_at)} heights, {len(utm_of)} UTM points')


# Line vertices as (row, column) of the piece, in cells from its top-left corner. The middle segment crosses
# the empty cell, so the profile has a gap.
LINE = [(3.5, 3.5), (25.5, 14.5), (2.5, 25.5), (20.5, 37.5)]


# Observers: (row, col, height above ground, curvature coefficient). The CLI's -cc default, none, and a
# large one so that the curvature arithmetic shows in so small a piece; corners and edges reach every pass.
VIEWS = [(15, 10, 10.0, 0.85714), (5, 33, 1.7, 0.85714), (0, 0, 30.0, 0.0), (29, 39, 1.7, 0.0), (20, 25, 2.0, 50.0)]


def make_viewsheds(piece, bounds, utm):
    """gdal_viewshed from each of VIEWS, on the heights in double precision as the app reads them.

    GDAL reads the empty cell as a height; it is given -9999 there, far below the ground, as the app does.
    """
    heights = np.where(piece == ba.NODATA, -9999.0, piece.astype(np.float64) * ba.SCALE)
    ds = gdal.GetDriverByName('MEM').Create('', W, H, 1, gdal.GDT_Float64)
    ds.SetGeoTransform((bounds[0], ba.CELL, 0, bounds[3], 0, -ba.CELL))
    ds.SetProjection(utm.ExportToWkt())
    ds.GetRasterBand(1).WriteArray(heights)
    out = []
    for row, col, height, cc in VIEWS:
        x = bounds[0] + (col + 0.5) * ba.CELL
        y = bounds[3] - (row + 0.5) * ba.CELL
        seen = gdal.ViewshedGenerate(
            ds.GetRasterBand(1), 'MEM', '', [], x, y, height, 0.0, 1, 0, 0, -1, cc, gdal.GVM_Edge, 0.0
        )
        cells = seen.GetRasterBand(1).ReadAsArray()
        out.append(dict(row=row, col=col, height=height, curvature=cc, seen=''.join(str(int(v)) for v in cells.ravel())))
    return out


def make_profile(bounds, to_utm, from_utm, height_at):
    """The profile as the app is meant to make it, worked out independently: vertices are given as WGS84,
    samples go every half cell or less along the straight UTM segment between vertices, heights are GDAL
    bilinear, and distance along the line is the geodesic length of each segment shared out evenly."""
    geod = Geod(ellps='WGS84')
    vertices = []
    for row, col in LINE:
        lon, lat = from_utm.TransformPoint(bounds[0] + col * ba.CELL, bounds[3] - row * ba.CELL)[:2]
        vertices.append((round(lat, 7), round(lon, 7)))
    utm = [to_utm.TransformPoint(lon, lat)[:2] for lat, lon in vertices]

    samples = []  # (distance, height or None)
    sections = []
    start = 0.0
    for k in range(len(vertices) - 1):
        (x0, y0), (x1, y1) = utm[k], utm[k + 1]
        length = geod.inv(vertices[k][1], vertices[k][0], vertices[k + 1][1], vertices[k + 1][0])[2]
        steps = max(1, int(np.ceil(np.hypot(x1 - x0, y1 - y0) / (ba.CELL / 2))))
        for i in range(0 if k == 0 else 1, steps + 1):
            t = i / steps
            samples.append((start + t * length, height_at(round(x0 + t * (x1 - x0), 6), round(y0 + t * (y1 - y0), 6))))
        a, b = height_at(x0, y0), height_at(x1, y1)
        sections.append({'start': start, 'length': length, 'from': a, 'to': b,
                         'grade': None if a is None or b is None else (b - a) / length})
        start += length

    heights = [h for _, h in samples if h is not None]
    ups = [b[1] - a[1] for a, b in zip(samples, samples[1:]) if a[1] is not None and b[1] is not None]
    return {
        'vertices': [{'lat': lat, 'lon': lon} for lat, lon in vertices],
        'samples': [{'d': round(d, 4), 'h': h} for d, h in samples],
        'length': round(start, 4),
        'min': min(heights),
        'max': max(heights),
        'ascent': round(sum(u for u in ups if u > 0), 4),
        'descent': round(-sum(u for u in ups if u < 0), 4),
        'sections': sections,
    }


if __name__ == '__main__':
    main()
