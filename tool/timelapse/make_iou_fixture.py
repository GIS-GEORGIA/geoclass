#!/usr/bin/env python3
"""The time-lapse game's reference answers, from GDAL/OGR and PROJ: test/fixtures/timelapse/iou.json.

Each case is a teacher's outline and a student's, as the game keeps them (lists of rings of [lat, lon]).
For each: the IoU by OGR (the rings of an outline unioned, then Intersection and Union areas, in the site's
UTM zone) and each outline's area in km² by PROJ's geodesic (pyproj.Geod on WGS 84, as the `geod` tool).
worker/test/timelapse.test.ts and test/timelapse_test.dart check their own IoU and areas against these.

    python3 tool/timelapse/make_iou_fixture.py
"""

import json
import math
import random
from pathlib import Path

import pyproj
from osgeo import ogr, osr

OUT = Path(__file__).resolve().parents[2] / 'test' / 'fixtures' / 'timelapse' / 'iou.json'
GEOD = pyproj.Geod(ellps='WGS84')
osr.UseExceptions()
ogr.UseExceptions()


def wgs84():
    s = osr.SpatialReference()
    s.ImportFromEPSG(4326)
    s.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)
    return s


def ogr_outline(rings, to_utm):
    """The union of an outline's rings, in UTM metres."""
    out = ogr.Geometry(ogr.wkbMultiPolygon)
    for ring in rings:
        r = ogr.Geometry(ogr.wkbLinearRing)
        for lat, lon in ring + [ring[0]]:
            r.AddPoint_2D(lon, lat)
        p = ogr.Geometry(ogr.wkbPolygon)
        p.AddGeometry(r)
        p.Transform(to_utm)
        assert p.IsValid(), ring
        out.AddGeometry(p)
    return out.UnionCascaded()


def geodesic_km2(geom, to_wgs):
    """The geodesic area of a (multi)polygon in UTM, taken back to lon/lat for PROJ."""
    g = geom.Clone()
    g.Transform(to_wgs)
    polys = [g] if g.GetGeometryType() == ogr.wkbPolygon else [g.GetGeometryRef(i) for i in range(g.GetGeometryCount())]
    total = 0.0
    for p in polys:
        for k in range(p.GetGeometryCount()):
            pts = p.GetGeometryRef(k).GetPoints()
            a, _ = GEOD.polygon_area_perimeter([q[0] for q in pts], [q[1] for q in pts])
            total += abs(a) if k == 0 else -abs(a)
    return total / 1e6


def blob(lat, lon, radius_m, n, rng, wobble=0.35):
    """A star-shaped ring (never crossing itself) of n vertices about a point."""
    out = []
    for i in range(n):
        t = 2 * math.pi * i / n
        r = radius_m * (1 + wobble * (rng.random() * 2 - 1))
        out.append([round(lat + r * math.sin(t) / 111_320, 6), round(lon + r * math.cos(t) / (111_320 * math.cos(math.radians(lat))), 6)])
    return out


def rect(lat, lon, w_m, h_m):
    dlat = h_m / 111_320
    dlon = w_m / (111_320 * math.cos(math.radians(lat)))
    return [[lat, lon], [lat, round(lon + dlon, 6)], [round(lat + dlat, 6), round(lon + dlon, 6)], [round(lat + dlat, 6), lon]]


def cases():
    rng = random.Random(7)
    pit = (41.373, 44.452)  # Madneuli
    yield 'same', [rect(*pit, 800, 600)], [rect(*pit, 800, 600)]
    yield 'apart', [rect(*pit, 800, 600)], [rect(pit[0] + 0.02, pit[1], 800, 600)]
    yield 'half', [rect(*pit, 800, 600)], [rect(pit[0], pit[1] + 400 / (111_320 * math.cos(math.radians(pit[0]))), 800, 600)]
    yield 'inside', [rect(*pit, 800, 600)], [rect(pit[0] + 0.001, pit[1] + 0.001, 300, 200)]
    l_shape = [[41.37, 44.45], [41.37, 44.47], [41.375, 44.47], [41.375, 44.455], [41.385, 44.455], [41.385, 44.45]]
    yield 'concave', [l_shape], [rect(41.371, 44.451, 1500, 1200)]
    # Two of the teacher's rings overlap: they count once.
    yield 'overlapping_rings', [rect(*pit, 800, 600), rect(pit[0] + 0.003, pit[1] + 0.004, 800, 600)], [rect(pit[0] + 0.001, pit[1] + 0.002, 900, 700)]
    # Chiatura: many pits, the student finds some and draws one where there is none.
    pits = [blob(42.29 + 0.01 * i, 43.25 + 0.015 * i, 300 + 60 * i, 12, rng) for i in range(5)]
    found = [blob(42.29 + 0.01 * i + 0.0005, 43.25 + 0.015 * i, 320 + 60 * i, 9, rng) for i in (0, 2, 3)] + [blob(42.33, 43.33, 250, 7, rng)]
    yield 'many_pits', pits, found
    for k in range(5):
        lat, lon = 41.6 + rng.random() * 0.2, 41.6 + rng.random() * 3.3
        r = 300 + rng.random() * 3000
        yield f'blob_{k}', [blob(lat, lon, r, 10 + k * 7, rng)], [blob(lat + 0.0003 * k, lon - 0.0004 * k, r * (0.8 + 0.1 * k), 8 + k * 5, rng)]
    # Tbilisi: a city of 15 km across, drawn roughly.
    yield 'city', [blob(41.72, 44.80, 8000, 40, rng, 0.2)], [blob(41.725, 44.81, 7500, 24, rng, 0.25)]


def main():
    out = []
    for name, truth, answer in cases():
        lat0 = sum(p[0] for p in truth[0]) / len(truth[0])
        lon0 = sum(p[1] for p in truth[0]) / len(truth[0])
        utm = osr.SpatialReference()
        utm.ImportFromEPSG((32600 if lat0 >= 0 else 32700) + int((lon0 + 180) // 6) + 1)
        to_utm = osr.CoordinateTransformation(wgs84(), utm)
        to_wgs = osr.CoordinateTransformation(utm, wgs84())
        t = ogr_outline(truth, to_utm)
        a = ogr_outline(answer, to_utm)
        union = t.Union(a).GetArea()
        out.append({
            'name': name,
            'truth': truth,
            'answer': answer,
            'iou': round(t.Intersection(a).GetArea() / union, 6) if union else 0,
            'truth_km2': round(geodesic_km2(t, to_wgs), 6),
            'answer_km2': round(geodesic_km2(a, to_wgs), 6),
        })
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({'source': 'GDAL/OGR ' + __import__('osgeo').__version__ + ', PROJ geodesic via pyproj ' + pyproj.__version__, 'cases': out}, indent=1) + '\n')
    for c in out:
        print(f"{c['name']:18} iou {c['iou']:.4f}  truth {c['truth_km2']:.4f} km²  answer {c['answer_km2']:.4f} km²")


if __name__ == '__main__':
    main()
