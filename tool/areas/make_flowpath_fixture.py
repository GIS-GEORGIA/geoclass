#!/usr/bin/env python3
"""Writes test/fixtures/watershed/paths.json: GRASS r.drain's paths down the fixture's flow directions.

    python3 tool/areas/make_watershed_fixture.py && python3 tool/areas/make_flowpath_fixture.py

For a few start cells, r.drain -d follows the D8 directions in test/fixtures/watershed/flow.u8 (r.watershed -s,
as degrees counterclockwise from east: GRASS code × 45, as the r.drain manual shows for r.watershed) from the
cell downhill until the water leaves the piece. The app's flowPath (lib/terrain/watershed.dart) must give the
same cells. Needs GRASS GIS (grass on the PATH), GDAL's Python bindings and NumPy.
"""

import json
import os
import shutil
import subprocess
import tempfile

import numpy as np

import build_area as ba
import build_watershed as bw

HERE = os.path.dirname(os.path.abspath(__file__))
DIR = os.path.abspath(os.path.join(HERE, '..', '..', 'test', 'fixtures', 'watershed'))

STARTS = [(5, 5), (20, 130), (60, 75), (100, 20), (115, 140), (45, 10)]


def main():
    with open(os.path.join(DIR, 'area.json'), encoding='utf-8') as f:
        meta = json.load(f)
    w, h, bounds, cell = meta['width'], meta['height'], meta['bounds'], meta['cell']
    heights = ba.decode(np.fromfile(os.path.join(DIR, 'dem.u16'), dtype='<u2').reshape(h, w)).astype(np.float64)
    flow = np.fromfile(os.path.join(DIR, 'flow.u8'), dtype=np.uint8).reshape(h, w)
    degrees = np.where(flow < 8, (flow.astype(np.float64) + 1) * 45, np.nan)
    work = tempfile.mkdtemp(prefix='geoclass-drain-')
    try:
        bw._write_tif(os.path.join(work, 'dem.tif'), heights, bounds, cell)
        bw._write_tif(os.path.join(work, 'dir.tif'), degrees, bounds, cell)
        steps = [
            f'r.in.gdal -o input={work}/dem.tif output=dem --quiet',
            f'r.in.gdal -o input={work}/dir.tif output=dir --quiet',
            'g.region raster=dem',
        ]
        for k, (r, c) in enumerate(STARTS):
            x = bounds[0] + (c + 0.5) * cell
            y = bounds[3] - (r + 0.5) * cell
            steps.append(f'r.drain -d input=dem direction=dir output=path{k} start_coordinates={x},{y} --quiet')
            steps.append(f'r.out.gdal input=path{k} output={work}/path{k}.tif type=Int32 nodata=0 --quiet -c')
        with open(os.path.join(work, 'run.sh'), 'w') as f:
            f.write('set -e\n' + '\n'.join(steps) + '\n')
        subprocess.run(
            ['grass', '--tmp-location', os.path.join(work, 'dem.tif'), '--exec', 'bash', os.path.join(work, 'run.sh')],
            check=True,
            capture_output=True,
            text=True,
        )
        paths = []
        for k, start in enumerate(STARTS):
            cells = np.argwhere(bw._read(os.path.join(work, f'path{k}.tif')) > 0)
            paths.append({'start': list(start), 'cells': sorted([int(r), int(c)] for r, c in cells)})
    finally:
        shutil.rmtree(work, ignore_errors=True)
    with open(os.path.join(DIR, 'paths.json'), 'w', encoding='utf-8') as f:
        json.dump({'source': 'GRASS r.drain -d on flow.u8 (code x 45 degrees)', 'paths': paths}, f, indent=1)
        f.write('\n')
    print(f'wrote paths.json: {[len(p["cells"]) for p in paths]} cells')


if __name__ == '__main__':
    main()
