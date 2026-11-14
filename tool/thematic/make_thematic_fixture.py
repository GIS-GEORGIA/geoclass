"""Reference numbers for lib/thematic: what QGIS and PROJ give for the same inputs.

    QT_QPA_PLATFORM=offscreen python3 tool/thematic/make_thematic_fixture.py

Writes test/fixtures/thematic/expected.json:
  areas      each region's and municipality's area in km² on the WGS84 ellipsoid (PROJ's geod, Karney), its
             rings filled even-odd as assets/ge_units.json means them;
  classes    QGIS's equal interval, quantile and Jenks breaks (QgsClassification*) for 3 to 7 classes, for a few
             datasets: skewed random values, values with ties, and the municipalities' areas; and the least
             within-class sum of squares any k classes can have ('jenks_sse', exact, by dynamic programming here).
             QGIS's Jenks doesn't always reach it: its backtracking steps one value too far
             (k = matrixOne[k][j] - 1 where matrixOne holds i4), so the app's Jenks is checked against the
             optimum, and against QGIS only for being no worse;
  ramps      QGIS's ColorBrewer colours (QgsColorBrewerColorRamp) for the ramps the app offers.
"""
import json
import random
from pathlib import Path

from pyproj import Geod
from qgis.core import (
    QgsApplication,
    QgsClassificationEqualInterval,
    QgsClassificationJenks,
    QgsClassificationQuantile,
    QgsColorBrewerColorRamp,
)

ROOT = Path(__file__).resolve().parents[2]
RAMPS = ['Blues', 'Greens', 'Oranges', 'Purples', 'YlGnBu', 'YlOrRd']
geod = Geod(ellps='WGS84')


def inside(p, ring):
    x, y = p
    c = False
    for (x1, y1), (x2, y2) in zip(ring, ring[1:] + ring[:1]):
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
            c = not c
    return c


def area_km2(rings):
    total = 0.0
    for i, r in enumerate(rings):
        a, _ = geod.polygon_area_perimeter([p[0] for p in r], [p[1] for p in r])
        depth = sum(1 for j, o in enumerate(rings) if j != i and inside(r[0], o))
        total += abs(a) * (1 if depth % 2 == 0 else -1)
    return total / 1e6


def sse(sorted_values, uppers):
    total, lo = 0.0, None
    for b in uppers:
        c = [x for x in sorted_values if (lo is None or x > lo) and x <= b]
        if c:
            m = sum(c) / len(c)
            total += sum((x - m) ** 2 for x in c)
        lo = b
    return total


def optimal_sse(values, k):
    # Fisher's exact optimum over contiguous groups of the sorted values, with prefix sums.
    v = sorted(values)
    n = len(v)
    p1, p2 = [0.0], [0.0]
    for x in v:
        p1.append(p1[-1] + x)
        p2.append(p2[-1] + x * x)

    def cost(i, j):  # values i..j-1
        w = j - i
        s = p1[j] - p1[i]
        return (p2[j] - p2[i]) - s * s / w

    inf = float('inf')
    best = [[inf] * (n + 1) for _ in range(k + 1)]
    best[0][0] = 0.0
    for c in range(1, k + 1):
        for j in range(1, n + 1):
            best[c][j] = min((best[c - 1][i] + cost(i, j) for i in range(c - 1, j)), default=inf)
    return best[k][n]


def main():
    app = QgsApplication([], False)
    app.initQgis()
    units = json.loads((ROOT / 'assets/ge_units.json').read_text())
    areas = {u['id']: area_km2(u['rings']) for key in ('regions', 'municipalities') for u in units[key]}

    rnd = random.Random(7)
    datasets = {
        'skewed': [round(rnd.lognormvariate(3, 1.2), 3) for _ in range(64)],
        'ties': [rnd.choice([1, 2, 2, 3, 5, 8, 8, 8, 13, 21, 40]) for _ in range(40)],
        'municipality_areas': [areas[u['id']] for u in units['municipalities']],
    }
    methods = {
        'equal': QgsClassificationEqualInterval(),
        'quantile': QgsClassificationQuantile(),
        'jenks': QgsClassificationJenks(),
    }
    classes = {}
    for name, values in datasets.items():
        classes[name] = {'values': values}
        for m, c in methods.items():
            classes[name][m] = {str(k): [r.upperBound() for r in c.classes(values, k)] for k in range(3, 8)}
        classes[name]['jenks_sse'] = {str(k): optimal_sse(values, k) for k in range(3, 8)}
        classes[name]['qgis_jenks_sse'] = {
            str(k): sse(sorted(values), classes[name]['jenks'][str(k)]) for k in range(3, 8)
        }

    ramps = {}
    for r in RAMPS:
        ramps[r] = {}
        for k in range(3, 8):
            ramp = QgsColorBrewerColorRamp(r, k)
            ramps[r][str(k)] = [ramp.color(i / (k - 1)).name() for i in range(k)]

    out = {
        'about': 'Made by tool/thematic/make_thematic_fixture.py with QGIS and pyproj; see there.',
        'areas': areas,
        'classes': classes,
        'ramps': ramps,
    }
    (ROOT / 'test/fixtures/thematic/expected.json').write_text(json.dumps(out, indent=1))
    print('areas', len(areas), 'tbilisi', round(areas['ge_tbilisi'], 1), 'kakheti', round(areas.get('ge_kakheti', 0), 1))


main()
