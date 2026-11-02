"""Draws the app icon into web/icons and web/favicon.png. Needs Pillow."""
from PIL import Image, ImageDraw

TEAL = (0, 121, 107, 255)
WHITE = (255, 255, 255, 255)
SCALE = 4


def draw(size, maskable):
    s = size * SCALE
    img = Image.new("RGBA", (s, s), TEAL if maskable else (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if not maskable:
        d.rounded_rectangle((0, 0, s - 1, s - 1), radius=s // 5, fill=TEAL)
    # Maskable icons keep their content inside the central safe zone.
    k = 0.72 if maskable else 1.0
    cx, cy = s / 2, s / 2

    def p(x, y):
        return (cx + (x - 0.5) * s * k, cy + (y - 0.5) * s * k)

    # Globe
    w = max(2, int(s * k * 0.035))
    (x0, y0), (x1, y1) = p(0.2, 0.28), p(0.8, 0.88)
    d.ellipse((x0, y0, x1, y1), outline=WHITE, width=w)
    (x0, y0), (x1, y1) = p(0.36, 0.28), p(0.64, 0.88)
    d.ellipse((x0, y0, x1, y1), outline=WHITE, width=w)
    a, b = p(0.2, 0.58), p(0.8, 0.58)
    d.line((a, b), fill=WHITE, width=w)

    # Pin on top
    (x0, y0), (x1, y1) = p(0.36, 0.1), p(0.64, 0.38)
    d.ellipse((x0, y0, x1, y1), fill=WHITE, outline=TEAL, width=w)
    d.polygon([p(0.385, 0.31), p(0.615, 0.31), p(0.5, 0.56)], fill=WHITE)
    (x0, y0), (x1, y1) = p(0.45, 0.19), p(0.55, 0.29)
    d.ellipse((x0, y0, x1, y1), fill=TEAL)

    return img.resize((size, size), Image.LANCZOS)


for size in (192, 512):
    draw(size, False).save(f"web/icons/Icon-{size}.png")
    draw(size, True).save(f"web/icons/Icon-maskable-{size}.png")
draw(32, False).save("web/favicon.png")
