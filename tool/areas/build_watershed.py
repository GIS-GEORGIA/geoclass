#!/usr/bin/env python3
"""Adds the flow directions to built elevation packages, for the watershed games.

    python3 tool/areas/build_area.py kutaisi-rioni && python3 tool/areas/build_watershed.py [area ids...]

For each area in <out>/<id>/<version>/ (default build/areas, every area found) GRASS GIS works out where
water flows from each cell, with r.watershed in single-flow-direction mode (-s: D8, water goes to one of
the eight neighbours). r.watershed finds its way through pits by least-cost search instead of filling them.
Two files are written next to the grid:

    flow.u8.gz      one byte per cell, rows north to south: the direction water leaves the cell, as
                    0 north-east, 1 north, 2 north-west, 3 west, 4 south-west, 5 south, 6 south-east, 7 east
                    (GRASS's drainage codes 1-8 less one); 255 where it leaves the area or there is no data
    watershed.json  the file's sha256, how it was made, and the upstream area that makes a stream

The app derives flow accumulation, streams and basins from these directions; test/watershed_test.dart
checks that against r.watershed's own accumulation and r.water.outlet's basins
(tool/areas/make_watershed_fixture.py). Needs GRASS GIS (grass on the PATH), GDAL's Python bindings and NumPy.
"""

import argparse
import gzip
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np
from osgeo import gdal, osr

import build_area as ba

gdal.UseExceptions()

# Cells of upstream area that make a stream on the map: 1 km² of 30 m cells.
STREAM_CELLS = 1112
NONE = 255


def _grass_version():
    out = subprocess.run(['grass', '--version'], capture_output=True, text=True).stdout
    line = next((l for l in out.splitlines() if l.startswith('GRASS GIS')), 'GRASS GIS')
    return line.strip()


def _write_tif(path, heights, bounds, cell):
    h, w = heights.shape
    ds = gdal.GetDriverByName('GTiff').Create(path, w, h, 1, gdal.GDT_Float64)
    ds.SetGeoTransform((bounds[0], cell, 0, bounds[3], 0, -cell))
    utm = osr.SpatialReference()
    utm.SetFromUserInput(ba.CRS)
    ds.SetProjection(utm.ExportToWkt())
    band = ds.GetRasterBand(1)
    band.SetNoDataValue(-9999)
    band.WriteArray(np.where(np.isnan(heights), -9999, heights))
    ds = None


def _read(path):
    ds = gdal.Open(path)
    return ds.GetRasterBand(1).ReadAsArray()


def grass_watershed(heights, bounds, cell, outlets=()):
    """GRASS on one grid: the drainage codes, the accumulation (cells, absolute), and for each outlet
    (row, col) the r.water.outlet basin as a 0/1 array."""
    work = tempfile.mkdtemp(prefix='geoclass-grass-')
    try:
        dem = os.path.join(work, 'dem.tif')
        _write_tif(dem, heights, bounds, cell)
        steps = [
            f'r.in.gdal -o input={dem} output=dem --quiet',
            'g.region raster=dem',
            'r.watershed -s elevation=dem drainage=dir accumulation=acc --quiet',
            f'r.out.gdal input=dir output={work}/dir.tif type=Int16 nodata=-32768 --quiet -c',
            f'r.out.gdal input=acc output={work}/acc.tif type=Float64 --quiet -c',
        ]
        for k, (row, col) in enumerate(outlets):
            x = bounds[0] + (col + 0.5) * cell
            y = bounds[3] - (row + 0.5) * cell
            steps.append(f'r.water.outlet input=dir output=basin{k} coordinates={x},{y} --quiet')
            steps.append(f'r.out.gdal input=basin{k} output={work}/basin{k}.tif type=Byte nodata=0 --quiet -c')
        script = os.path.join(work, 'run.sh')
        with open(script, 'w') as f:
            f.write('set -e\n' + '\n'.join(steps) + '\n')
        subprocess.run(
            ['grass', '--tmp-location', dem, '--exec', 'bash', script],
            check=True,
            capture_output=True,
            text=True,
        )
        drainage = _read(os.path.join(work, 'dir.tif')).astype(np.int32)
        acc = np.abs(_read(os.path.join(work, 'acc.tif')))
        basins = [(_read(os.path.join(work, f'basin{k}.tif')) > 0).astype(np.uint8) for k in range(len(outlets))]
        return drainage, acc, basins
    finally:
        shutil.rmtree(work, ignore_errors=True)


def encode_flow(drainage):
    """GRASS drainage codes (1-8, counterclockwise from north-east; 0 or negative where water leaves or there
    is no data) to the package's bytes."""
    flow = np.full(drainage.shape, NONE, dtype=np.uint8)
    inside = (drainage >= 1) & (drainage <= 8)
    flow[inside] = (drainage[inside] - 1).astype(np.uint8)
    return flow


def build(folder):
    with open(os.path.join(folder, 'area.json'), encoding='utf-8') as f:
        meta = json.load(f)
    with open(os.path.join(folder, meta['grid']['file']), 'rb') as f:
        steps = np.frombuffer(gzip.decompress(f.read()), dtype='<u2').reshape(meta['height'], meta['width'])
    drainage, _, _ = grass_watershed(ba.decode(steps).astype(np.float64), meta['bounds'], meta['cell'])
    flow = encode_flow(drainage)
    raw = flow.tobytes()
    with open(os.path.join(folder, 'flow.u8.gz'), 'wb') as f:
        f.write(gzip.compress(raw, compresslevel=9, mtime=0))
    info = {
        'file': 'flow.u8.gz',
        'type': 'uint8',
        'order': 'rows north to south, west to east',
        'directions': '0 NE, 1 N, 2 NW, 3 W, 4 SW, 5 S, 6 SE, 7 E; 255 out of the area or no data',
        'sha256': hashlib.sha256(raw).hexdigest(),
        'stream_cells': STREAM_CELLS,
        'source': f'{_grass_version()}, r.watershed -s (single flow direction, D8) on dem.u16.gz',
    }
    with open(os.path.join(folder, 'watershed.json'), 'w', encoding='utf-8') as f:
        json.dump(info, f, ensure_ascii=False, indent=2)
        f.write('\n')
    return info, int((flow == NONE).sum())


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('ids', nargs='*', help='areas to do (default: every built area)')
    p.add_argument('--out', default=os.path.join(ba.HERE, '..', '..', 'build', 'areas'))
    args = p.parse_args(argv)
    out = os.path.abspath(args.out)
    ids = args.ids or sorted(d for d in os.listdir(out) if os.path.isdir(os.path.join(out, d)))
    for area_id in ids:
        versions = sorted(int(v) for v in os.listdir(os.path.join(out, area_id)) if v.isdigit())
        if not versions:
            sys.exit(f'{area_id}: not built')
        folder = os.path.join(out, area_id, str(versions[-1]))
        info, leaving = build(folder)
        print(f'{area_id}/{versions[-1]}: flow.u8.gz {info["sha256"][:12]}, {leaving} cells drain out of the area')


if __name__ == '__main__':
    main()
