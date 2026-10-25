#!/usr/bin/env python3
"""Generate the Settings icon for AI 日志分析 Pro.

Creates a 1024 master and the 29/58/87 px variants used by the bundle.
Everything is composited onto the gradient so the small sizes stay readable.
"""
import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "packaging", "icons")
os.makedirs(OUT, exist_ok=True)

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# Vertical gradient background.
grad = Image.new("RGBA", (1, S))
for y in range(S):
    t = y / (S - 1)
    r = int(18 + (10 - 18) * t)
    g = int(30 + (16 - 30) * t)
    b = int(76 + (40 - 76) * t)
    grad.putpixel((0, y), (r, g, b, 255))
grad = grad.resize((S, S))

mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, S - 1, S - 1), radius=228, fill=255)
img.paste(grad, (0, 0), mask)


def overlay():
    return Image.new("RGBA", (S, S), (0, 0, 0, 0))


# Soft cyan glow behind the sparkle.
glow = overlay()
gd = ImageDraw.Draw(glow)
for i in range(18, 0, -1):
    rr = int(300 * i / 18)
    a = int(6 + (18 - i) * 2.2)
    gd.ellipse((760 - rr, 300 - rr, 760 + rr, 300 + rr), fill=(103, 232, 249, a))
img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(38)))

# Inner border.
d = ImageDraw.Draw(img)
d.rounded_rectangle((3, 3, S - 4, S - 4), radius=226, outline=(255, 255, 255, 34), width=6)

# Glass card (the "log").
card = (176, 292, 712, 828)
shadow = overlay()
ImageDraw.Draw(shadow).rounded_rectangle(
    (card[0] + 12, card[1] + 18, card[2] + 12, card[3] + 18), radius=74, fill=(0, 0, 0, 120)
)
img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(26)))

fg = overlay()
fd = ImageDraw.Draw(fg)
fd.rounded_rectangle(card, radius=74, fill=(255, 255, 255, 16), outline=(255, 255, 255, 48), width=5)


def line(x0, y0, x1, y1, color):
    fd.rounded_rectangle((x0, y0, x1, y1), radius=(y1 - y0) // 2, fill=color)


line(248, 388, 616, 424, (255, 255, 255, 235))
line(248, 476, 552, 512, (103, 232, 249, 255))
line(248, 564, 646, 600, (255, 255, 255, 150))
line(248, 652, 492, 688, (255, 255, 255, 95))


def sparkle(cx, cy, R, r, fill):
    pts = [(cx, cy - R), (cx + r, cy - r), (cx + R, cy), (cx + r, cy + r),
           (cx, cy + R), (cx - r, cy + r), (cx - R, cy), (cx - r, cy - r)]
    fd.polygon(pts, fill=fill)


sparkle(760, 300, 196, 40, (103, 232, 249, 255))
sparkle(760, 300, 118, 24, (255, 255, 255, 245))
sparkle(884, 438, 78, 17, (103, 232, 249, 235))
sparkle(884, 438, 46, 10, (255, 255, 255, 235))

img.alpha_composite(fg)

img.save(os.path.join(OUT, "icon-1024.png"))
for name, size in (("icon.png", 29), ("icon@2x.png", 58), ("icon@3x.png", 87)):
    img.resize((size, size), Image.LANCZOS).save(os.path.join(OUT, name))
    print(name, size)
print("wrote", OUT)
