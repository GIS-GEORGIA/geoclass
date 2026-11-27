"""Draws the decorative contour/graticule backgrounds used by the slides (synthetic terrain, not real data)."""
import numpy as np, matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import qrcode, sys, os
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
rng = np.random.default_rng(1916)  # Aslanikashvili's birth year
x, y = np.meshgrid(np.linspace(0, 16, 1600), np.linspace(0, 9, 900))
z = np.zeros_like(x)
for _ in range(14):
    cx, cy, s, a = rng.uniform(0, 16), rng.uniform(0, 9), rng.uniform(1.2, 3.5), rng.uniform(-1, 1.6)
    z += a * np.exp(-((x - cx) ** 2 + (y - cy) ** 2) / (2 * s * s))
def bg(name, face, line, alpha, grid, side=None):
    fig = plt.figure(figsize=(16, 9), dpi=120)
    ax = fig.add_axes([0, 0, 1, 1]); ax.set_axis_off(); fig.patch.set_facecolor(face)
    zz = z.copy()
    if side == 'right':
        zz = np.where(x > 9.5, z, np.nan)
    ax.contour(x, y, zz, levels=26, colors=line, linewidths=0.7, alpha=alpha)
    for gx in np.arange(0, 16.1, 2): ax.axvline(gx, color=grid, lw=0.5, alpha=0.5)
    for gy in np.arange(0, 9.1, 1.5): ax.axhline(gy, color=grid, lw=0.5, alpha=0.5)
    ax.set_xlim(0, 16); ax.set_ylim(0, 9)
    fig.savefig(f'{out}/{name}.png', facecolor=face); plt.close(fig)
bg('bg_title', '#16233A', '#5E86A8', 0.55, '#2C4466')
bg('bg_light', '#F6F2EA', '#C9BFA9', 0.35, '#E4DCCB', side='right')
bg('bg_section', '#F6F2EA', '#C9BFA9', 0.30, '#E4DCCB')
for name, url in [('qr_repo', 'https://github.com/GIS-GEORGIA/geoclass'), ('qr_doi', 'https://doi.org/10.5281/zenodo.24144115')]:
    img = qrcode.make(url, border=1, box_size=12)
    img.save(f'{out}/{name}.png')
print('ok')
