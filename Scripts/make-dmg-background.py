#!/usr/bin/env python3
"""Draw the MacmonDash DMG Finder background (Docker-style drag-and-drop).

Writes:
  Resources/dmg-background.png      (540×380, 1×)
  Resources/dmg-background@2x.png   (1080×760, for Retina)
"""
import math
import os

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT1 = os.path.join(ROOT, "Resources", "dmg-background.png")
OUT2 = os.path.join(ROOT, "Resources", "dmg-background@2x.png")

# Finder window content size (matches make-release / dmgbuild window_rect)
W1, H1 = 540, 380

BG = (255, 255, 255)
INK = (28, 36, 32)
ACCENT = (45, 120, 55)

# Icon centers in the 540×380 window (must match dmgbuild icon_locations)
APP_XY = (140, 175)
APPS_XY = (400, 175)


def load_font(size: int) -> ImageFont.ImageFont:
    candidates = [
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/SFNSText.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/Library/Fonts/Arial.ttf",
    ]
    for path in candidates:
        if os.path.isfile(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def bezier(p0, p1, p2, p3, steps=80):
    pts = []
    for i in range(steps + 1):
        t = i / steps
        u = 1 - t
        x = u**3 * p0[0] + 3 * u**2 * t * p1[0] + 3 * u * t**2 * p2[0] + t**3 * p3[0]
        y = u**3 * p0[1] + 3 * u**2 * t * p1[1] + 3 * u * t**2 * p2[1] + t**3 * p3[1]
        pts.append((x, y))
    return pts


def draw_thick_curve(draw: ImageDraw.ImageDraw, pts, width, color):
    for i in range(len(pts) - 1):
        draw.line([pts[i], pts[i + 1]], fill=color, width=width)
    r = max(width // 2, 1)
    for x, y in pts:
        draw.ellipse([x - r, y - r, x + r, y + r], fill=color)


def draw_arrowhead(draw: ImageDraw.ImageDraw, tip, direction, size, color):
    dx, dy = direction
    length = math.hypot(dx, dy) or 1.0
    ux, uy = dx / length, dy / length
    px, py = -uy, ux
    base = (tip[0] - ux * size, tip[1] - uy * size)
    left = (base[0] + px * size * 0.65, base[1] + py * size * 0.65)
    right = (base[0] - px * size * 0.65, base[1] - py * size * 0.65)
    draw.polygon([tip, left, right], fill=color)


def render(scale: int) -> Image.Image:
    w, h = W1 * scale, H1 * scale
    img = Image.new("RGB", (w, h), BG)
    draw = ImageDraw.Draw(img)

    left = (APP_XY[0] * scale, APP_XY[1] * scale)
    right = (APPS_XY[0] * scale, APPS_XY[1] * scale)

    # Curve under icons: left → down → right, arrow toward Applications
    p0 = (left[0] + 20 * scale, left[1] + 70 * scale)
    p1 = (left[0] + 60 * scale, left[1] + 150 * scale)
    p2 = (right[0] - 80 * scale, right[1] + 150 * scale)
    p3 = (right[0] - 10 * scale, right[1] + 70 * scale)
    pts = bezier(p0, p1, p2, p3)

    draw_thick_curve(draw, pts, width=11 * scale, color=ACCENT)
    tip = pts[-1]
    prev = pts[-8]
    draw_arrowhead(
        draw, tip, (tip[0] - prev[0], tip[1] - prev[1]), size=24 * scale, color=ACCENT
    )

    font = load_font(21 * scale)
    text = "drag and drop"
    bbox = draw.textbbox((0, 0), text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    # Sit between the icons, above the arrow dip
    tx = (w - tw) // 2
    ty = int((left[1] + right[1]) / 2) + 8 * scale
    draw.text((tx, ty), text, font=font, fill=INK)

    return img


def main():
    os.makedirs(os.path.join(ROOT, "Resources"), exist_ok=True)
    img1 = render(1)
    img2 = render(2)
    img1.save(OUT1, "PNG", optimize=True)
    img2.save(OUT2, "PNG", optimize=True)
    print(f"Wrote {OUT1} ({img1.size[0]}×{img1.size[1]})")
    print(f"Wrote {OUT2} ({img2.size[0]}×{img2.size[1]})")


if __name__ == "__main__":
    main()
