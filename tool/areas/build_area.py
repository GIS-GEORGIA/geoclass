#!/usr/bin/env python3
"""Builds the elevation packages for the terrain games, one folder per area.

    python3 tool/areas/build_area.py [area ids...] [--out build/areas] [--source DIR]

Areas are listed in tool/areas/areas.json: id, version, names and a WGS84 box [west, south, east, north].
Heights come from the Copernicus DEM GLO-30 (2021 release on AWS Open Data). GDAL reads only the part
of each tile that the area needs, straight from the public bucket. --source points at a folder of the same
tiles instead (used by the tests).

Each area gets <out>/<id>/<version>/:
    area.json   size, position, scale, height range, source and the required attribution
    dem.u16.gz  the grid: UInt16 little-endian, rows north to south, 0.1 m per step, 65535 = no data
and <out>/catalog.json lists every area built so far. tool/areas/build_watershed.py then adds the flow
directions (flow.u8.gz, watershed.json) for the watershed game.

The grid is UTM zone 38N (EPSG:32638) with 30 m square cells aligned to multiples of 30 m, so slope and
distance need no latitude correction. Resampling is bilinear, on a mosaic of the tiles, with exact projection. Needs only GDAL's Python bindings and NumPy.
"""

import argparse
import gzip
import hashlib
import json
import math
import os
import sys

import numpy as np
from osgeo import gdal, osr

gdal.UseExceptions()

HERE = os.path.dirname(os.path.abspath(__file__))
AREAS_FILE = os.path.join(HERE, 'areas.json')

CRS = 'EPSG:32638'
CELL = 30.0
SCALE = 0.1  # metres per step
NODATA = 65535
MAX_HEIGHT = (NODATA - 1) * SCALE

SOURCE = 'Copernicus DEM GLO-30, 2021 release (AWS Open Data)'
AWS = '/vsicurl/https://copernicus-dem-30m.s3.amazonaws.com'
# The licence asks for this notice when the data are adapted, which reprojecting and rescaling does.
ATTRIBUTION = (
    'produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 '
    'provided under COPERNICUS by the European Union and ESA; all rights reserved'
)
LICENCE = 'https://dataspace.copernicus.eu/explore-data/data-collections/copernicus-contributing-missions/collections-description/COP-DEM'


def tile_name(lat, lon):
    """The 1° tile whose south-west corner is (lat, lon)."""
    ns = f'N{lat:02d}' if lat >= 0 else f'S{-lat:02d}'
    ew = f'E{lon:03d}' if lon >= 0 else f'W{-lon:03d}'
    return f'Copernicus_DSM_COG_10_{ns}_00_{ew}_00_DEM'


def tiles_for(bbox):
    west, south, east, north = bbox
    # A box ending exactly on a whole degree doesn't need the next tile.
    lats = range(math.floor(south), math.ceil(north))
    lons = range(math.floor(west), math.ceil(east))
    return [tile_name(lat, lon) for lat in lats for lon in lons]


def tile_paths(bbox, source):
    if source is None:
        return [f'{AWS}/{name}/{name}.tif' for name in tiles_for(bbox)]
    paths = [os.path.join(source, f'{name}.tif') for name in tiles_for(bbox)]
    missing = [p for p in paths if not os.path.exists(p)]
    if missing:
        raise SystemExit(f'missing tiles: {", ".join(missing)}')
    return paths


def utm_bounds(bbox):
    """The UTM box that covers the WGS84 box, edges densified, snapped outward to the 30 m grid."""
    wgs = osr.SpatialReference()
    wgs.ImportFromEPSG(4326)
    wgs.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)
    utm = osr.SpatialReference()
    utm.SetFromUserInput(CRS)
    to_utm = osr.CoordinateTransformation(wgs, utm)
    west, south, east, north = bbox
    steps = 20
    edge = []
    for i in range(steps + 1):
        t = i / steps
        lon = west + (east - west) * t
        lat = south + (north - south) * t
        edge += [(lon, south), (lon, north), (west, lat), (east, lat)]
    xs, ys = zip(*[to_utm.TransformPoint(lon, lat)[:2] for lon, lat in edge])
    return (
        math.floor(min(xs) / CELL) * CELL,
        math.floor(min(ys) / CELL) * CELL,
        math.ceil(max(xs) / CELL) * CELL,
        math.ceil(max(ys) / CELL) * CELL,
    )


def grid_bbox(bounds):
    """The WGS84 box of the whole UTM grid, which reaches a little past the area's own box."""
    utm = osr.SpatialReference()
    utm.SetFromUserInput(CRS)
    wgs = osr.SpatialReference()
    wgs.ImportFromEPSG(4326)
    wgs.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)
    back = osr.CoordinateTransformation(utm, wgs)
    x0, y0, x1, y1 = bounds
    steps = 20
    edge = []
    for i in range(steps + 1):
        t = i / steps
        x = x0 + (x1 - x0) * t
        y = y0 + (y1 - y0) * t
        edge += [(x, y0), (x, y1), (x0, y), (x1, y)]
    lons, lats = zip(*[back.TransformPoint(x, y)[:2] for x, y in edge])
    return [min(lons), min(lats), max(lons), max(lats)]


def warp(paths, bounds):
    """Heights in metres on the area's grid, as float32, NaN where there is no data."""
    # One mosaic first, so bilinear sees the neighbouring tile's cells at a tile edge.
    mosaic = gdal.BuildVRT('', paths)
    out = gdal.Warp(
        '',
        mosaic,
        format='MEM',
        dstSRS=CRS,
        outputBounds=bounds,
        xRes=CELL,
        yRes=CELL,
        resampleAlg='bilinear',
        outputType=gdal.GDT_Float32,
        dstNodata=float('nan'),
        multithread=True,
        errorThreshold=0,  # exact projection for every cell, not GDAL's approximation
    )
    return out.GetRasterBand(1).ReadAsArray().astype(np.float32)


def encode(heights):
    """Metres to UInt16 steps of 0.1 m; no data becomes 65535. Refuses heights it can't store."""
    valid = np.isfinite(heights)
    if not valid.any():
        raise ValueError('the area has no height data')
    low, high = float(heights[valid].min()), float(heights[valid].max())
    if low < 0 or high > MAX_HEIGHT:
        raise ValueError(f'heights {low:.1f}..{high:.1f} m are outside 0..{MAX_HEIGHT:.1f} m')
    steps = np.full(heights.shape, NODATA, dtype='<u2')
    steps[valid] = np.rint(heights[valid] / SCALE).astype('<u2')
    return steps


def decode(steps):
    """The inverse of encode, for checks: metres as float32, NaN where there is no data."""
    heights = steps.astype(np.float32) * SCALE
    heights[steps == NODATA] = np.nan
    return heights


def build(area, out_dir, source=None):
    bounds = utm_bounds(area['bbox'])
    # Tiles for the grid, not the box: snapping out to 30 m can cross into the next tile.
    paths = tile_paths(grid_bbox(bounds), source)
    steps = encode(warp(paths, bounds))
    raw = steps.tobytes()
    height, width = steps.shape
    valid = steps[steps != NODATA]
    folder = os.path.join(out_dir, area['id'], str(area['version']))
    os.makedirs(folder, exist_ok=True)
    # mtime 0 and no file name, so the same input always gives the same bytes.
    with open(os.path.join(folder, 'dem.u16.gz'), 'wb') as f:
        f.write(gzip.compress(raw, compresslevel=9, mtime=0))
    meta = {
        'id': area['id'],
        'version': area['version'],
        'ka': area['ka'],
        'en': area['en'],
        'bbox': area['bbox'],
        'crs': CRS,
        'bounds': list(bounds),
        'cell': CELL,
        'width': width,
        'height': height,
        'grid': {
            'file': 'dem.u16.gz',
            'type': 'uint16le',
            'order': 'rows north to south, west to east',
            'scale': SCALE,
            'nodata': NODATA,
            'sha256': hashlib.sha256(raw).hexdigest(),
        },
        'min': round(float(valid.min()) * SCALE, 1),
        'max': round(float(valid.max()) * SCALE, 1),
        'source': SOURCE,
        'surface': 'DSM: buildings and forest are included',
        'datum': 'EGM2008 heights, WGS84 positions',
        'attribution': ATTRIBUTION,
        'licence': LICENCE,
    }
    with open(os.path.join(folder, 'area.json'), 'w', encoding='utf-8') as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
        f.write('\n')
    return meta


def write_catalog(out_dir):
    """Lists every area under out_dir, newest version of each, sorted by id."""
    areas = []
    for area_id in sorted(os.listdir(out_dir)):
        folder = os.path.join(out_dir, area_id)
        if not os.path.isdir(folder):
            continue
        versions = sorted((int(v) for v in os.listdir(folder) if v.isdigit()), reverse=True)
        for version in versions:
            path = os.path.join(folder, str(version), 'area.json')
            if os.path.exists(path):
                with open(path, encoding='utf-8') as f:
                    meta = json.load(f)
                areas.append({k: meta[k] for k in ('id', 'version', 'ka', 'en', 'bbox', 'min', 'max')})
                break
    catalog = {'areas': areas, 'attribution': ATTRIBUTION}
    with open(os.path.join(out_dir, 'catalog.json'), 'w', encoding='utf-8') as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2)
        f.write('\n')
    return catalog


def load_areas(path=AREAS_FILE):
    with open(path, encoding='utf-8') as f:
        return json.load(f)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('ids', nargs='*', help='areas to build (default: all)')
    parser.add_argument('--out', default=os.path.join(HERE, '..', '..', 'build', 'areas'))
    parser.add_argument('--source', help='folder of Copernicus tiles to read instead of AWS')
    args = parser.parse_args(argv)
    areas = load_areas()
    known = {a['id']: a for a in areas}
    unknown = [i for i in args.ids if i not in known]
    if unknown:
        raise SystemExit(f'unknown areas: {", ".join(unknown)}')
    out = os.path.abspath(args.out)
    for area in [known[i] for i in args.ids] or areas:
        meta = build(area, out, args.source)
        print(f"{meta['id']}: {meta['width']}×{meta['height']} cells, {meta['min']}–{meta['max']} m")
    write_catalog(out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
