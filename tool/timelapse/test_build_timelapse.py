"""Tests for build_timelapse.py, with made-up catalogues and bands (no network).

    python3 -m unittest discover -s tool/timelapse

The grid's corners are checked against PROJ's cs2cs and the frame's cells against gdalwarp run on a made-up
raster, so the frames line up with the map as the app draws them.
"""

import io
import json
import os
import subprocess
import tempfile
import unittest

import numpy as np
from osgeo import gdal, osr
from PIL import Image

import build_timelapse as bt

SITE = {'id': 'test', 'version': 1, 'ka': 'ტესტი', 'en': 'Test', 'kind': 'mine', 'bbox': [44.03, 41.35, 44.1, 41.4], 'cell': 10}


def item(id_, date, cloud, platform='landsat-5'):
    return {'id': id_, 'properties': {'datetime': f'{date}T08:00:00Z', 'eo:cloud_cover': cloud, 'platform': platform}, 'assets': {}}


class Grid(unittest.TestCase):
    def test_grid_is_snapped_utm_and_its_corners_are_projs(self):
        g = bt.grid(SITE)
        self.assertEqual(g['crs'], 'EPSG:32638')
        x0, y0, x1, y1 = g['bounds']
        for v in g['bounds']:
            self.assertEqual(v % 10, 0)
        self.assertEqual((g['width'], g['height']), ((x1 - x0) / 10, (y1 - y0) / 10))
        # The box is inside the grid.
        nw, ne, se, sw = g['corners']
        self.assertLessEqual(sw[0], 41.35)
        self.assertGreaterEqual(ne[0], 41.4)
        # cs2cs, the other way: the corners go back to the grid's bounds.
        text = '\n'.join(f'{lat} {lon}' for lat, lon in g['corners'])
        out = subprocess.run(['cs2cs', '-f', '%.3f', 'EPSG:4326', 'EPSG:32638'], input=text, capture_output=True, text=True, check=True)
        xy = [tuple(map(float, line.split()[:2])) for line in out.stdout.strip().splitlines()]
        want = [(x0, y1), (x1, y1), (x1, y0), (x0, y0)]
        for (x, y), (wx, wy) in zip(xy, want):
            self.assertAlmostEqual(x, wx, delta=0.01)
            self.assertAlmostEqual(y, wy, delta=0.01)

    def test_zone_37_for_batumi(self):
        self.assertEqual(bt.utm_epsg([41.55, 41.57, 41.68, 41.67]), 32637)

    def test_read_band_matches_gdalwarp(self):
        g = bt.grid({**SITE, 'cell': 30})
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, 'src.tif')
            ds = gdal.GetDriverByName('GTiff').Create(src, 400, 300, 1, gdal.GDT_Float32)
            ds.SetGeoTransform((44.0, 0.0004, 0, 41.42, 0, -0.0004))
            srs = osr.SpatialReference()
            srs.ImportFromEPSG(4326)
            ds.SetProjection(srs.ExportToWkt())
            ds.GetRasterBand(1).WriteArray(np.add.outer(np.arange(300), np.arange(400) * 3).astype(np.float32))
            ds = None
            ours = bt.read_band(src, g, 'bilinear')
            ref = os.path.join(d, 'ref.tif')
            x0, y0, x1, y1 = g['bounds']
            subprocess.run(
                ['gdalwarp', '-q', '-t_srs', 'EPSG:32638', '-te', str(x0), str(y0), str(x1), str(y1), '-tr', '30', '30',
                 '-r', 'bilinear', '-ot', 'Float32', '-dstnodata', 'nan', '-et', '0', src, ref],
                check=True,
            )
            theirs = gdal.Open(ref).ReadAsArray()
            self.assertEqual(ours.shape, (g['height'], g['width']))
            np.testing.assert_allclose(ours, theirs, atol=1e-3)


class Clouds(unittest.TestCase):
    def test_landsat_qa_bits(self):
        # clear land (21824), fill (1), dilated cloud (2), cirrus (4), cloud (8), shadow (16), water (21952)
        qa = np.array([21824, 1, 2, 4, 8, 16, 21952, np.nan], dtype=np.float32)
        self.assertEqual(bt.landsat_bad(qa).tolist(), [False, True, True, True, True, True, False, True])

    def test_sentinel_scl_classes(self):
        scl = np.array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], dtype=np.float32)
        bad = [True, True, False, True, False, False, False, False, True, True, True, False]
        self.assertEqual(bt.sentinel_bad(scl).tolist(), bad)


class WhiteBright(unittest.TestCase):
    def test_clouds_not_bare_soil(self):
        # cloud, thin cloud, bright reddish spoil, dark forest, missing
        blue = np.array([0.35, 0.16, 0.18, 0.03, np.nan])
        red = np.array([0.36, 0.17, 0.30, 0.02, np.nan])
        self.assertEqual(bt.white_bright(blue, red).tolist(), [True, True, False, False, False])


class Colour(unittest.TestCase):
    def test_fixed_stretch(self):
        r = np.array([[0.0, 0.3, 0.6, np.nan]], dtype=np.float32)
        rgb = bt.to_rgb(r, r, r)
        self.assertEqual(rgb[0, :, 0].tolist(), [0, 255, 255, 0])
        mid = bt.to_rgb(np.array([[0.075]]), np.array([[0.075]]), np.array([[0.075]]))[0, 0, 0]
        self.assertEqual(mid, round(0.25 ** bt.GAMMA * 255))

    def test_scale_offset(self):
        landsat = {'assets': {'red': {}}, 'properties': {}}
        self.assertEqual(bt.scale_offset(landsat, 'red', 'landsat'), (2.75e-05, -0.2))
        old = {'assets': {'red': {}}, 'properties': {'s2:processing_baseline': '03.01'}}
        new = {'assets': {'red': {}}, 'properties': {'s2:processing_baseline': '05.10'}}
        self.assertEqual(bt.scale_offset(old, 'red', 'sentinel'), (1e-4, 0.0))
        self.assertEqual(bt.scale_offset(new, 'red', 'sentinel'), (1e-4, -0.1))
        given = {'assets': {'red': {'raster:bands': [{'scale': 0.0001, 'offset': -0.1}]}}, 'properties': {}}
        self.assertEqual(bt.scale_offset(given, 'red', 'sentinel'), (0.0001, -0.1))
        # Earth Search took the offset off already, though raster:bands still give it.
        applied = {
            'assets': {'red': {'raster:bands': [{'scale': 0.0001, 'offset': -0.1}]}},
            'properties': {'s2:processing_baseline': '05.00', 'earthsearch:boa_offset_applied': True},
        }
        self.assertEqual(bt.scale_offset(applied, 'red', 'sentinel'), (0.0001, 0.0))


class Choosing(unittest.TestCase):
    def test_order_and_landsat7_fault(self):
        items = [
            item('may-clear', '2005-05-10', 1),
            item('jul-cloudy', '2005-07-10', 30),
            item('aug-clear', '2005-08-10', 2),
            item('l7-after-fault', '2005-07-01', 0, 'landsat-7'),
            item('april', '2005-04-01', 0),
        ]
        got = bt.candidates({**SITE}, 2005, find=lambda url, body: items)
        self.assertEqual([i['id'] for _, i in got], ['aug-clear', 'jul-cloudy', 'may-clear'])
        self.assertTrue(all(k == 'landsat' for k, _ in got))

    def test_sentinel_from_2017(self):
        seen = []
        bt.candidates(SITE, 2017, find=lambda url, body: seen.append((url, body['collections'])) or [])
        bt.candidates(SITE, 2016, find=lambda url, body: seen.append((url, body['collections'])) or [])
        self.assertEqual(seen, [(bt.ES_SEARCH, ['sentinel-2-l2a']), (bt.PC_SEARCH, ['landsat-c2-l2'])])

    def test_first_good_else_best_fair_else_none(self):
        class R:
            def __init__(self, shares):
                self.shares = shares

            def quality(self, it, kind, g):
                share = self.shares[it['id']]
                q = np.zeros((10, 100), dtype=np.float32)
                q.flat[: round(share * 1000)] = 8  # cloud
                return q

            def reflectance(self, it, kind, g, asset):
                return np.zeros((10, 100), dtype=np.float32)

        items = [item('a', '2000-07-01', 1), item('b', '2000-08-01', 2), item('c', '2000-09-01', 3)]
        find = lambda url, body: items
        g = bt.grid(SITE)
        quiet = lambda *_: None
        self.assertEqual(bt.choose(SITE, 2000, g, R({'a': 0.2, 'b': 0.01, 'c': 0}), find, quiet)[0]['id'], 'b')
        self.assertEqual(bt.choose(SITE, 2000, g, R({'a': 0.2, 'b': 0.04, 'c': 0.03}), find, quiet)[0]['id'], 'c')
        self.assertIsNone(bt.choose(SITE, 2000, g, R({'a': 0.2, 'b': 0.06, 'c': 0.3}), find, quiet))


class Build(unittest.TestCase):
    def test_frames_and_site_json(self):
        g = bt.grid(SITE)

        class R:
            def quality(self, it, kind, grid):
                return np.zeros((grid['height'], grid['width']), dtype=np.float32) + (4 if kind == 'sentinel' else 21824)

            def reflectance(self, it, kind, grid, asset):
                return np.full((grid['height'], grid['width']), {'red': 0.3, 'green': 0.075, 'blue': 0.0}[asset], dtype=np.float32)

        def find(url, body):
            year = body['datetime'][:4]
            if year == '2001':
                return []
            platform = 'sentinel-2b' if url == bt.ES_SEARCH else 'landsat-5'
            return [item(f'scene-{year}', f'{year}-07-15', 3, platform)]

        with tempfile.TemporaryDirectory() as d:
            meta = bt.build(SITE, d, [2000, 2001, 2017], reader=R(), find=find, log=lambda *_: None)
            bt.write_catalog(d, [meta])
            self.assertEqual([f['year'] for f in meta['frames']], [2000, 2017])
            self.assertEqual(meta['missing'], [2001])
            self.assertEqual([(f['sensor'], f['resolution']) for f in meta['frames']], [('Landsat 5 TM', 30), ('Sentinel-2B', 10)])
            self.assertEqual(len(meta['attribution']), 2)
            folder = os.path.join(d, 'test', '1')
            with open(os.path.join(folder, 'site.json'), encoding='utf-8') as f:
                self.assertEqual(json.load(f)['width'], g['width'])
            im = Image.open(os.path.join(folder, '2000.jpg'))
            self.assertEqual(im.size, (g['width'], g['height']))
            px = np.asarray(im.convert('RGB'))[g['height'] // 2, g['width'] // 2]
            self.assertTrue(abs(int(px[0]) - 255) <= 3 and abs(int(px[1]) - round(0.25 ** bt.GAMMA * 255)) <= 4 and int(px[2]) <= 4, px)
            with open(os.path.join(d, 'catalog.json'), encoding='utf-8') as f:
                self.assertEqual(json.load(f)['sites'][0]['years'], [2000, 2017])
            # Redoing one year keeps the others; a year that is now found leaves the missing list.
            again = bt.build(SITE, d, [2001], reader=R(), find=lambda url, body: [item('scene-2001', '2001-07-15', 3)], log=lambda *_: None)
            self.assertEqual([f['year'] for f in again['frames']], [2000, 2001, 2017])
            self.assertEqual(again['missing'], [])


if __name__ == '__main__':
    unittest.main()
