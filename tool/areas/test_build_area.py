"""Reference tests for build_area.py, on small made-up tiles (no network).

    python3 -m unittest discover -s tool/areas

Heights in the made-up tiles are a plane in longitude and latitude, which bilinear resampling reproduces
exactly, so every output cell can be checked against the formula. The same warp done by the gdalwarp
command is the second reference.
"""

import gzip
import hashlib
import json
import math
import os
import subprocess
import tempfile
import unittest

import numpy as np
from osgeo import gdal, osr

import build_area as ba

STEP = 1 / 120  # 30″ cells keep the made-up tiles small


def plane(lon, lat):
    return 500 + 1500 * (lat - 42) + 800 * (lon - 44)


def make_tile(folder, lat, lon, hole=None, offset=0.0):
    """A 1° tile like Copernicus's, heights from plane(); hole = (row0, row1, col0, col1) set to no data."""
    n = round(1 / STEP)
    path = os.path.join(folder, ba.tile_name(lat, lon) + '.tif')
    ds = gdal.GetDriverByName('GTiff').Create(path, n, n, 1, gdal.GDT_Float32)
    ds.SetGeoTransform((lon, STEP, 0, lat + 1, 0, -STEP))
    srs = osr.SpatialReference()
    srs.ImportFromEPSG(4326)
    ds.SetProjection(srs.ExportToWkt())
    cols = lon + (np.arange(n) + 0.5) * STEP
    rows = lat + 1 - (np.arange(n) + 0.5) * STEP
    grid = plane(cols[None, :], rows[:, None]).astype(np.float32) + offset
    band = ds.GetRasterBand(1)
    band.SetNoDataValue(-32767)
    if hole:
        r0, r1, c0, c1 = hole
        grid[r0:r1, c0:c1] = -32767
    band.WriteArray(grid)
    ds = None
    return path


def cell_centres(meta):
    """WGS84 lon/lat of every cell centre of a built area."""
    utm = osr.SpatialReference()
    utm.SetFromUserInput(ba.CRS)
    wgs = osr.SpatialReference()
    wgs.ImportFromEPSG(4326)
    wgs.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)
    back = osr.CoordinateTransformation(utm, wgs)
    x0, _, _, y1 = meta['bounds']
    xs = x0 + (np.arange(meta['width']) + 0.5) * meta['cell']
    ys = y1 - (np.arange(meta['height']) + 0.5) * meta['cell']
    pts = [(x, y) for y in ys for x in xs]
    lonlat = np.array([back.TransformPoint(x, y)[:2] for x, y in pts])
    return lonlat[:, 0].reshape(meta['height'], meta['width']), lonlat[:, 1].reshape(meta['height'], meta['width'])


def read_grid(folder, meta):
    with open(os.path.join(folder, meta['grid']['file']), 'rb') as f:
        raw = gzip.decompress(f.read())
    return raw, np.frombuffer(raw, dtype='<u2').reshape(meta['height'], meta['width'])


class Tiles(unittest.TestCase):
    def test_names(self):
        self.assertEqual(ba.tile_name(42, 44), 'Copernicus_DSM_COG_10_N42_00_E044_00_DEM')

    def test_a_box_inside_one_tile_needs_one_tile(self):
        self.assertEqual(ba.tiles_for([44.48, 42.6, 44.7, 42.72]), [ba.tile_name(42, 44)])

    def test_a_box_across_a_degree_needs_both_tiles(self):
        self.assertEqual(ba.tiles_for([43.9, 42.2, 44.1, 42.4]), [ba.tile_name(42, 43), ba.tile_name(42, 44)])

    def test_a_box_ending_on_a_whole_degree_does_not_need_the_next_tile(self):
        self.assertEqual(ba.tiles_for([44.5, 42.5, 45.0, 43.0]), [ba.tile_name(42, 44)])

    def test_without_a_source_folder_it_reads_the_public_bucket(self):
        name = ba.tile_name(42, 44)
        self.assertEqual(
            ba.tile_paths([44.48, 42.6, 44.7, 42.72], None),
            [f'/vsicurl/https://copernicus-dem-30m.s3.amazonaws.com/{name}/{name}.tif'],
        )

    def test_the_three_areas_need_only_tiles_that_exist_at_30_m(self):
        # Checked on AWS 2026-11-12: N41 E043–E046 are missing at 30 m, everything N42–N43 E040–E046 is there.
        for area in ba.load_areas():
            for name in ba.tiles_for(ba.grid_bbox(ba.utm_bounds(area['bbox']))):
                self.assertNotRegex(name, r'_N41_00_E04[3-6]_', area['id'])


class Encoding(unittest.TestCase):
    def test_steps_of_a_tenth_of_a_metre_little_endian(self):
        steps = ba.encode(np.array([[0.0, 1234.56, np.nan, 5193.0]], dtype=np.float32))
        self.assertEqual(steps.tolist(), [[0, 12346, ba.NODATA, 51930]])
        self.assertEqual(steps.tobytes()[2:4], (12346).to_bytes(2, 'little'))

    def test_decode_is_the_inverse_within_half_a_step(self):
        heights = np.array([[0.0, 99.94, 3000.06, np.nan]], dtype=np.float32)
        back = ba.decode(ba.encode(heights))
        self.assertTrue(np.isnan(back[0, 3]))
        np.testing.assert_allclose(back[0, :3], heights[0, :3], atol=0.05 + 1e-4)

    def test_refuses_heights_it_cannot_store(self):
        with self.assertRaises(ValueError):
            ba.encode(np.array([[-0.5, 10.0]], dtype=np.float32))
        with self.assertRaises(ValueError):
            ba.encode(np.array([[ba.MAX_HEIGHT + 1]], dtype=np.float32))
        with self.assertRaises(ValueError):
            ba.encode(np.array([[np.nan]], dtype=np.float32))


class Build(unittest.TestCase):
    area = {'id': 'test', 'version': 1, 'ka': 'ტესტი', 'en': 'Test', 'bbox': [44.48, 42.6, 44.7, 42.72]}

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.src = os.path.join(self.tmp.name, 'src')
        self.out = os.path.join(self.tmp.name, 'out')
        os.makedirs(self.src)

    def tearDown(self):
        self.tmp.cleanup()

    def build(self, area=None):
        area = area or self.area
        meta = ba.build(area, self.out, self.src)
        folder = os.path.join(self.out, area['id'], str(area['version']))
        return meta, folder

    def test_heights_match_the_formula_at_every_cell(self):
        make_tile(self.src, 42, 44)
        meta, folder = self.build()
        _, steps = read_grid(folder, meta)
        lon, lat = cell_centres(meta)
        self.assertFalse((steps == ba.NODATA).any())
        np.testing.assert_allclose(ba.decode(steps), plane(lon, lat), atol=0.05 + 1e-3)

    def test_matches_the_gdalwarp_command(self):
        tile = make_tile(self.src, 42, 44)
        meta, folder = self.build()
        ref = os.path.join(self.tmp.name, 'ref.tif')
        x0, y0, x1, y1 = meta['bounds']
        subprocess.run(
            ['gdalwarp', '-q', '-t_srs', ba.CRS, '-te', str(x0), str(y0), str(x1), str(y1), '-tr', '30', '30',
             '-r', 'bilinear', '-et', '0', '-ot', 'Float32', tile, ref],
            check=True,
        )
        ds = gdal.Open(ref)
        expected = ds.GetRasterBand(1).ReadAsArray()
        _, steps = read_grid(folder, meta)
        self.assertEqual(steps.shape, expected.shape)
        np.testing.assert_allclose(ba.decode(steps), expected, atol=0.05 + 1e-3)

    def test_grid_is_aligned_to_30_m_and_covers_the_box(self):
        make_tile(self.src, 42, 44)
        meta, _ = self.build()
        x0, y0, x1, y1 = meta['bounds']
        for v in meta['bounds']:
            self.assertEqual(v % 30, 0)
        self.assertEqual(meta['width'], (x1 - x0) / 30)
        self.assertEqual(meta['height'], (y1 - y0) / 30)
        utm = osr.SpatialReference()
        utm.SetFromUserInput(ba.CRS)
        wgs = osr.SpatialReference()
        wgs.ImportFromEPSG(4326)
        wgs.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)
        to_utm = osr.CoordinateTransformation(wgs, utm)
        west, south, east, north = self.area['bbox']
        for lon, lat in [(west, south), (west, north), (east, south), (east, north), ((west + east) / 2, north)]:
            x, y = to_utm.TransformPoint(lon, lat)[:2]
            self.assertTrue(x0 <= x <= x1 and y0 <= y <= y1, (lon, lat))
        # About 18 × 13 km.
        self.assertTrue(550 < meta['width'] < 650 and 400 < meta['height'] < 500, (meta['width'], meta['height']))

    def test_two_tiles_join_without_a_seam(self):
        make_tile(self.src, 42, 43)
        make_tile(self.src, 42, 44)
        area = dict(self.area, bbox=[43.95, 42.3, 44.05, 42.35])
        meta, folder = self.build(area)
        _, steps = read_grid(folder, meta)
        lon, lat = cell_centres(meta)
        self.assertTrue((lon < 44).any() and (lon > 44).any())
        np.testing.assert_allclose(ba.decode(steps), plane(lon, lat), atol=0.05 + 1e-3)

    def test_a_box_on_a_whole_degree_also_reads_the_tile_the_grid_reaches_into(self):
        # Mestia's box starts at 43.00 N; the 30 m grid reaches a few metres south of it, into N42.
        make_tile(self.src, 42, 44)
        make_tile(self.src, 41, 44)
        area = dict(self.area, bbox=[44.4, 42.0, 44.5, 42.05])
        self.assertEqual(ba.tiles_for(area['bbox']), [ba.tile_name(42, 44)])
        meta, folder = self.build(area)
        _, steps = read_grid(folder, meta)
        self.assertFalse((steps == ba.NODATA).any())
        lon, lat = cell_centres(meta)
        self.assertTrue((lat < 42).any())
        np.testing.assert_allclose(ba.decode(steps), plane(lon, lat), atol=0.05 + 1e-3)

    def test_a_hole_in_the_source_stays_no_data(self):
        # Rows and columns of the made-up tile: 42.72 N is row 33.6, 44.55–44.6 E are columns 66–72.
        make_tile(self.src, 42, 44, hole=(40, 46, 66, 72))
        meta, folder = self.build()
        _, steps = read_grid(folder, meta)
        lon, lat = cell_centres(meta)
        inside = (lon > 44.56) & (lon < 44.59) & (lat < 42.66) & (lat > 42.625)
        self.assertTrue(inside.any())
        self.assertTrue((steps[inside] == ba.NODATA).all())
        far = (lon < 44.5) | (lat < 42.61)
        self.assertTrue((steps[far] != ba.NODATA).all())

    def test_heights_below_sea_level_stop_the_build(self):
        make_tile(self.src, 42, 44, offset=-2000)
        with self.assertRaises(ValueError):
            self.build()

    def test_area_json_describes_the_grid(self):
        make_tile(self.src, 42, 44)
        meta, folder = self.build()
        raw, steps = read_grid(folder, meta)
        with open(os.path.join(folder, 'area.json'), encoding='utf-8') as f:
            saved = json.load(f)
        self.assertEqual(saved, meta)
        self.assertEqual(len(raw), meta['width'] * meta['height'] * 2)
        self.assertEqual(hashlib.sha256(raw).hexdigest(), meta['grid']['sha256'])
        self.assertEqual(meta['min'], round(float(steps.min()) * ba.SCALE, 1))
        self.assertEqual(meta['max'], round(float(steps.max()) * ba.SCALE, 1))
        self.assertTrue(meta['attribution'].startswith('produced using Copernicus WorldDEM-30'))
        self.assertEqual(meta['ka'], 'ტესტი')

    def test_same_input_gives_the_same_bytes(self):
        make_tile(self.src, 42, 44)
        _, folder = self.build()
        first = open(os.path.join(folder, 'dem.u16.gz'), 'rb').read()
        self.build()
        self.assertEqual(open(os.path.join(folder, 'dem.u16.gz'), 'rb').read(), first)

    def test_a_missing_tile_stops_the_build(self):
        with self.assertRaises(SystemExit):
            self.build()

    def test_catalog_lists_the_newest_version_of_each_area(self):
        make_tile(self.src, 42, 44)
        self.build(dict(self.area, id='b'))
        self.build(dict(self.area, id='a', version=1))
        self.build(dict(self.area, id='a', version=2, en='Newer'))
        catalog = ba.write_catalog(self.out)
        self.assertEqual([(a['id'], a['version']) for a in catalog['areas']], [('a', 2), ('b', 1)])
        self.assertEqual(catalog['areas'][0]['en'], 'Newer')
        with open(os.path.join(self.out, 'catalog.json'), encoding='utf-8') as f:
            self.assertEqual(json.load(f), catalog)


class Definitions(unittest.TestCase):
    def test_areas_json_is_complete(self):
        areas = ba.load_areas()
        self.assertEqual(len({a['id'] for a in areas}), len(areas))
        for a in areas:
            self.assertRegex(a['id'], r'^[a-z0-9-]+$')
            self.assertIsInstance(a['version'], int)
            self.assertTrue(a['ka'] and a['en'])
            west, south, east, north = a['bbox']
            self.assertTrue(40 <= west < east <= 47 and 41 <= south < north <= 44, a['id'])
            # Small enough for a phone: under 40 km a side.
            km = math.cos(math.radians(south)) * 111.32
            self.assertLess((east - west) * km, 40, a['id'])
            self.assertLess((north - south) * 111.32, 40, a['id'])


if __name__ == '__main__':
    unittest.main()
