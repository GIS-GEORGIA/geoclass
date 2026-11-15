#!/usr/bin/env python3
"""Builds the satellite time-lapse packages: one clear true-colour frame a year for each site.

    python3 tool/timelapse/build_timelapse.py [site ids...] [--out build/timelapse] [--from 1984] [--to 2025]

Sites are listed in tool/timelapse/sites.json: id, version, names, a WGS84 box [west, south, east, north] and
the cell size of the frames (10 m, or 20 m for a large site).

Where the frames come from (both open, no account needed):
    1984-2016  Landsat 5, 7 (before its scan-line fault of 31 May 2003) and 8, Collection 2 Level-2 surface
               reflectance, 30 m, from Microsoft Planetary Computer's STAC API. Its blob storage needs a
               short-lived token, which the same service gives to anyone (no account): AWS keeps Landsat in a
               requester-pays bucket, which would need an AWS account and payment.
    2017-      Sentinel-2 Level-2A surface reflectance, 10 m, from Element 84's Earth Search STAC API (the
               public sentinel-cogs bucket on AWS).
GDAL reads only the part of each cloud-optimised GeoTIFF that the site needs; nothing else is kept.

How a year's frame is chosen: the scenes of May to October are tried, June to September first, then by the
scene's own cloud cover. For each, the quality band is read over the site and the share of cells that are
cloud, cloud shadow, cirrus or missing is counted. The first scene with at most 1 % such cells is taken;
otherwise the best one if it has at most 5 %; otherwise the year is left out (and listed as such).

Every frame is resampled (bilinear) to one UTM grid per site, so all years line up cell for cell. Colours
are the surface reflectance of the red, green and blue bands with the same fixed stretch for every year and
sensor, so a change of colour is a change on the ground (or of season), not of processing.

Each site gets <out>/<id>/<version>/:
    site.json        grid, corners, attribution, and the frames: year, date, sensor, resolution, scene, file
    <year>.jpg       the frame, rows north to south
and <out>/catalog.json lists every site built so far.
"""

import argparse
import datetime
import io
import json
import math
import os
import sys
import time

import numpy as np
import requests
from osgeo import gdal, osr
from PIL import Image

gdal.UseExceptions()
gdal.SetConfigOption('GDAL_DISABLE_READDIR_ON_OPEN', 'EMPTY_DIR')
gdal.SetConfigOption('CPL_VSIL_CURL_ALLOWED_EXTENSIONS', '.tif,.TIF')
gdal.SetConfigOption('GDAL_HTTP_MAX_RETRY', '4')
gdal.SetConfigOption('GDAL_HTTP_RETRY_DELAY', '2')

HERE = os.path.dirname(os.path.abspath(__file__))
SITES_FILE = os.path.join(HERE, 'sites.json')

PC_SEARCH = 'https://planetarycomputer.microsoft.com/api/stac/v1/search'
PC_TOKEN = 'https://planetarycomputer.microsoft.com/api/sas/v1/token/landsat-c2-l2'
ES_SEARCH = 'https://earth-search.aws.element84.com/v1/search'
USER_AGENT = 'geoclass-timelapse-build'

SENTINEL_FROM = 2017
L7_FAULT = '2003-05-31'
MONTHS = (5, 6, 7, 8, 9, 10)
PREFERRED = (6, 7, 8, 9)
TRIES = 8
GOOD, FAIR = 0.01, 0.05

# Fixed stretch: surface reflectance 0..0.3 to 0..255, with a gamma that lifts the dark vegetation.
TOP, GAMMA = 0.3, 1 / 1.6
JPEG_QUALITY = 85

LANDSAT_ATTRIBUTION = 'Landsat imagery courtesy of the U.S. Geological Survey'
SENTINEL_ATTRIBUTION = 'Contains modified Copernicus Sentinel data'


# --- The grid ---


def utm_epsg(bbox):
    lon = (bbox[0] + bbox[2]) / 2
    lat = (bbox[1] + bbox[3]) / 2
    zone = int((lon + 180) // 6) % 60 + 1
    return (32600 if lat >= 0 else 32700) + zone


def _srs(epsg):
    s = osr.SpatialReference()
    s.ImportFromEPSG(epsg)
    s.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)
    return s


def grid(site):
    """The site's UTM grid: crs, bounds snapped outward to the cell size, size, and its corners in WGS84."""
    epsg = utm_epsg(site['bbox'])
    cell = float(site['cell'])
    to_utm = osr.CoordinateTransformation(_srs(4326), _srs(epsg))
    west, south, east, north = site['bbox']
    edge = []
    for i in range(21):
        t = i / 20
        lon, lat = west + (east - west) * t, south + (north - south) * t
        edge += [(lon, south), (lon, north), (west, lat), (east, lat)]
    xs, ys = zip(*[to_utm.TransformPoint(lon, lat)[:2] for lon, lat in edge])
    bounds = (
        math.floor(min(xs) / cell) * cell,
        math.floor(min(ys) / cell) * cell,
        math.ceil(max(xs) / cell) * cell,
        math.ceil(max(ys) / cell) * cell,
    )
    back = osr.CoordinateTransformation(_srs(epsg), _srs(4326))
    x0, y0, x1, y1 = bounds
    # North-west, north-east, south-east, south-west: the order the app's overlay takes.
    corners = [back.TransformPoint(x, y)[:2] for x, y in [(x0, y1), (x1, y1), (x1, y0), (x0, y0)]]
    return {
        'crs': f'EPSG:{epsg}',
        'bounds': list(bounds),
        'cell': cell,
        'width': round((x1 - x0) / cell),
        'height': round((y1 - y0) / cell),
        'corners': [[round(lat, 7), round(lon, 7)] for lon, lat in corners],
    }


def read_band(path, g, resample):
    """One band of a (remote) raster on the site's grid, as float32; NaN where the source has no data."""
    out = gdal.Warp(
        '',
        path,
        format='MEM',
        dstSRS=g['crs'],
        outputBounds=g['bounds'],
        xRes=g['cell'],
        yRes=g['cell'],
        resampleAlg=resample,
        outputType=gdal.GDT_Float32,
        dstNodata=float('nan'),
        errorThreshold=0,
    )
    return out.GetRasterBand(1).ReadAsArray().astype(np.float32)


# --- Clouds ---


def landsat_bad(qa):
    """Landsat Collection 2 QA_PIXEL: fill (bit 0), dilated cloud (1), cirrus (2), cloud (3), shadow (4)."""
    q = np.nan_to_num(qa, nan=1).astype(np.uint16)
    return (q & 0b11111) != 0


def sentinel_bad(scl):
    """Sentinel-2 scene classification: no data (0), saturated (1), shadow (3), cloud (8, 9), cirrus (10)."""
    s = np.nan_to_num(scl, nan=0).astype(np.uint8)
    return np.isin(s, [0, 1, 3, 8, 9, 10])


# Bright and white: a cloud even where the product's own mask missed it (Sentinel-2's scene classification
# before processing baseline 04.00 often calls cumulus "bare soil" or "unclassified"). Bare soil and mine
# spoil are bright too, but reddish: their blue is well below their red.
BRIGHT_BLUE, WHITE_RATIO = 0.15, 0.85


def white_bright(blue, red):
    with np.errstate(invalid='ignore', divide='ignore'):
        return (np.nan_to_num(blue) > BRIGHT_BLUE) & (np.nan_to_num(blue / red) > WHITE_RATIO)


def bad_share(mask):
    return float(mask.mean()) if mask.size else 1.0


# --- Colour ---


def to_rgb(r, g, b):
    """Surface reflectance to 8-bit true colour, the same for every year. Missing cells are black."""
    out = []
    for band in (r, g, b):
        v = np.clip(np.nan_to_num(band, nan=0) / TOP, 0, 1) ** GAMMA
        out.append(np.rint(v * 255).astype(np.uint8))
    return np.dstack(out)


def jpeg(rgb):
    buf = io.BytesIO()
    Image.fromarray(rgb, 'RGB').save(buf, 'JPEG', quality=JPEG_QUALITY, optimize=True, progressive=True)
    return buf.getvalue()


# --- Catalogues ---


def search(url, body):
    """All items of a STAC search, following the next pages."""
    items = []
    while True:
        r = requests.post(url, json=body, timeout=90, headers={'user-agent': USER_AGENT})
        r.raise_for_status()
        j = r.json()
        items += j['features']
        nxt = [link for link in j.get('links', []) if link.get('rel') == 'next']
        if not nxt or 'body' not in nxt[0] or len(items) > 1000:
            return items
        body = nxt[0]['body']


class Token:
    """Planetary Computer's read token for Landsat, fetched again before it runs out."""

    def __init__(self):
        self.value, self.until = None, 0

    def __call__(self):
        if time.time() > self.until - 300:
            r = requests.get(PC_TOKEN, timeout=60, headers={'user-agent': USER_AGENT})
            r.raise_for_status()
            j = r.json()
            self.value = j['token']
            expiry = j.get('msft:expiry')
            self.until = (
                datetime.datetime.fromisoformat(expiry.replace('Z', '+00:00')).timestamp() if expiry else time.time() + 1800
            )
        return self.value


def month(item):
    return int(item['properties']['datetime'][5:7])


def order(items):
    """June to September first, then May and October; within each, by the scene's cloud cover."""
    return sorted(items, key=lambda i: (month(i) not in PREFERRED, i['properties'].get('eo:cloud_cover', 100)))


def candidates(site, year, find=search):
    """The scenes worth trying for a year, best first, with how to read them."""
    when = f'{year}-05-01T00:00:00Z/{year}-10-31T23:59:59Z'
    if year >= SENTINEL_FROM:
        items = find(
            ES_SEARCH,
            {
                'collections': ['sentinel-2-l2a'],
                'bbox': site['bbox'],
                'datetime': when,
                'limit': 100,
                'query': {'eo:cloud_cover': {'lt': 40}},
            },
        )
        return [('sentinel', i) for i in order(items) if month(i) in MONTHS][:TRIES]
    items = find(
        PC_SEARCH,
        {
            'collections': ['landsat-c2-l2'],
            'bbox': site['bbox'],
            'datetime': when,
            'limit': 200,
            'query': {'eo:cloud_cover': {'lt': 40}, 'platform': {'in': ['landsat-5', 'landsat-7', 'landsat-8', 'landsat-9']}},
        },
    )
    usable = [
        i
        for i in items
        if month(i) in MONTHS
        and not (i['properties']['platform'] == 'landsat-7' and i['properties']['datetime'][:10] > L7_FAULT)
    ]
    return [('landsat', i) for i in order(usable)][:TRIES]


def scale_offset(item, asset, kind):
    """How a band's numbers become reflectance, from the item when it says, else the product's rule."""
    bands = item['assets'][asset].get('raster:bands') or [{}]
    scale, offset = bands[0].get('scale'), bands[0].get('offset')
    # Earth Search has already taken baseline 04.00's 1000 off these pixels, but its raster:bands still give
    # offset -0.1: taken off twice, the frame comes out dark.
    if item['properties'].get('earthsearch:boa_offset_applied') is True:
        return float(scale if scale is not None else 1e-4), 0.0
    if scale is not None:
        return float(scale), float(offset or 0)
    if kind == 'landsat':
        return 2.75e-05, -0.2
    # Sentinel-2 processing baseline 04.00 (from January 2022) added 1000 to every value.
    baseline = str(item['properties'].get('s2:processing_baseline', '0'))
    return 1e-4, (-0.1 if baseline >= '04.00' else 0.0)


class Reader:
    """Reads an item's bands over the site's grid. Tests give their own."""

    def __init__(self):
        self.token = Token()
        self._bands = {}  # the chosen scene's bands are read once, for the cloud check and the frame

    def path(self, item, asset, kind):
        href = item['assets'][asset]['href']
        if kind == 'landsat':
            href = f'{href}?{self.token()}'
        return '/vsicurl/' + href

    def quality(self, item, kind, g):
        asset = 'qa_pixel' if kind == 'landsat' else 'scl'
        return read_band(self.path(item, asset, kind), g, 'near')

    def reflectance(self, item, kind, g, asset):
        key = (item['id'], asset)
        if key not in self._bands:
            dn = read_band(self.path(item, asset, kind), g, 'bilinear')
            scale, offset = scale_offset(item, asset, kind)
            dn[dn == 0] = np.nan  # 0 is "no data" in both products
            self._bands[key] = dn * scale + offset
        return self._bands[key]

    def forget(self):
        self._bands.clear()


SENSOR = {
    'landsat-5': ('Landsat 5 TM', 30),
    'landsat-7': ('Landsat 7 ETM+', 30),
    'landsat-8': ('Landsat 8 OLI', 30),
    'landsat-9': ('Landsat 9 OLI-2', 30),
}


def sensor_of(kind, item):
    if kind == 'sentinel':
        platform = item['properties'].get('platform', 'sentinel-2')  # sentinel-2a, -2b, -2c
        return 'Sentinel-' + platform.split('-', 1)[-1].upper(), 10
    return SENSOR.get(item['properties']['platform'], (item['properties']['platform'], 30))


def choose(site, year, g, reader, find=search, log=print):
    """The year's frame as (item, kind, bad share), or None."""
    best = None
    for kind, item in candidates(site, year, find):
        try:
            mask = (landsat_bad if kind == 'landsat' else sentinel_bad)(reader.quality(item, kind, g))
            if bad_share(mask) <= FAIR:  # only then are the colour bands worth reading
                mask |= white_bright(reader.reflectance(item, kind, g, 'blue'), reader.reflectance(item, kind, g, 'red'))
            share = bad_share(mask)
        except RuntimeError as e:
            log(f'  {item["id"]}: unreadable ({e})')
            continue
        log(f'  {item["id"]}: {share:.1%} cloud or missing')
        if share <= GOOD:
            return item, kind, share
        if best is None or share < best[2]:
            best = (item, kind, share)
    return best if best is not None and best[2] <= FAIR else None


def build(site, out_dir, years, reader=None, find=search, log=print):
    reader = reader or Reader()
    g = grid(site)
    folder = os.path.join(out_dir, site['id'], str(site['version']))
    os.makedirs(folder, exist_ok=True)
    frames, missing = [], []
    # Years not built this time are kept from the last build on the same grid, so a range can be redone.
    path = os.path.join(folder, 'site.json')
    if os.path.exists(path):
        with open(path, encoding='utf-8') as f:
            last = json.load(f)
        if last.get('crs') == g['crs'] and last.get('bounds') == g['bounds']:
            frames = [x for x in last['frames'] if x['year'] not in years]
            missing = [y for y in last['missing'] if y not in years]
    for year in years:
        log(f'{site["id"]} {year}')
        picked = choose(site, year, g, reader, find, log)
        if picked is None:
            missing.append(year)
            continue
        item, kind, share = picked
        rgb = to_rgb(*(reader.reflectance(item, kind, g, a) for a in ('red', 'green', 'blue')))
        if hasattr(reader, 'forget'):
            reader.forget()
        name = f'{year}.jpg'
        with open(os.path.join(folder, name), 'wb') as f:
            f.write(jpeg(rgb))
        sensor, res = sensor_of(kind, item)
        frames.append(
            {
                'year': year,
                'date': item['properties']['datetime'][:10],
                'sensor': sensor,
                'resolution': res,
                'scene': item['id'],
                'cloud': round(share, 4),
                'file': name,
            }
        )
    frames.sort(key=lambda x: x['year'])
    missing.sort()
    sources = sorted({'landsat' if f['resolution'] == 30 else 'sentinel' for f in frames})
    meta = {
        'id': site['id'],
        'version': site['version'],
        'ka': site['ka'],
        'en': site['en'],
        'kind': site['kind'],
        'bbox': site['bbox'],
        **g,
        'frames': frames,
        'missing': missing,
        'stretch': {'top': TOP, 'gamma': round(GAMMA, 4)},
        'attribution': [LANDSAT_ATTRIBUTION if s == 'landsat' else SENTINEL_ATTRIBUTION for s in sources],
    }
    with open(os.path.join(folder, 'site.json'), 'w', encoding='utf-8') as f:
        json.dump(meta, f, ensure_ascii=False, indent=1)
    return meta


def write_catalog(out_dir, metas):
    path = os.path.join(out_dir, 'catalog.json')
    sites = {}
    if os.path.exists(path):
        with open(path, encoding='utf-8') as f:
            sites = {s['id']: s for s in json.load(f)['sites']}
    for m in metas:
        sites[m['id']] = {
            'id': m['id'],
            'version': m['version'],
            'ka': m['ka'],
            'en': m['en'],
            'kind': m['kind'],
            'bbox': m['bbox'],
            'years': [f['year'] for f in m['frames']],
        }
    with open(path, 'w', encoding='utf-8') as f:
        json.dump({'sites': [sites[k] for k in sorted(sites)]}, f, ensure_ascii=False, indent=1)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('ids', nargs='*')
    p.add_argument('--out', default='build/timelapse')
    p.add_argument('--from', dest='first', type=int, default=1984)
    p.add_argument('--to', dest='last', type=int, default=datetime.date.today().year - 1)
    a = p.parse_args()
    with open(SITES_FILE, encoding='utf-8') as f:
        sites = json.load(f)
    chosen = [s for s in sites if not a.ids or s['id'] in a.ids]
    if a.ids and len(chosen) != len(a.ids):
        sys.exit(f'unknown site in {a.ids}')
    metas = [build(s, a.out, range(a.first, a.last + 1)) for s in chosen]
    write_catalog(a.out, metas)
    for m in metas:
        print(f'{m["id"]}: {len(m["frames"])} frames, missing {m["missing"]}')


if __name__ == '__main__':
    main()
