"""Draws the app icon for web and Android, and the Play feature graphic. Needs Pillow."""
import os

from PIL import Image, ImageDraw, ImageFont

TEAL = (0, 121, 107, 255)
WHITE = (255, 255, 255, 255)
SCALE = 4


def draw(size, maskable, safe=0.72):
    s = size * SCALE
    img = Image.new("RGBA", (s, s), TEAL if maskable else (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if not maskable:
        d.rounded_rectangle((0, 0, s - 1, s - 1), radius=s // 5, fill=TEAL)
    # Maskable icons keep their content inside the central safe zone.
    k = safe if maskable else 1.0
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

RES = "android/app/src/main/res"
for folder, size in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
    draw(size, False).save(f"{RES}/mipmap-{folder}/ic_launcher.png")
# Android masks adaptive icons down to the central 61%.
draw(432, True, safe=0.58).save(f"{RES}/mipmap-xxxhdpi/ic_launcher_foreground.png")


def feature_graphic():
    img = Image.new("RGB", (1024, 500), TEAL[:3])
    img.paste(draw(300, True), (70, 100))
    d = ImageDraw.Draw(img)
    font = "assets/fonts/NotoSansGeorgian-"
    d.text((410, 135), "GeoClass", font=ImageFont.truetype(font + "Bold.ttf", 96), fill=WHITE)
    d.text((412, 275), "გეოგრაფიული თამაშები კლასისთვის", font=ImageFont.truetype(font + "Regular.ttf", 28), fill=WHITE)
    d.text((412, 325), "Geography games for the classroom", font=ImageFont.truetype(font + "Regular.ttf", 28), fill=WHITE)
    os.makedirs("docs/play", exist_ok=True)
    img.save("docs/play/feature-graphic.png")


feature_graphic()
