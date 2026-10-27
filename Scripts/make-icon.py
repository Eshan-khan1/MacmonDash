#!/usr/bin/env python3
"""Render the MacmonDash app icon: the same bit-graphic fan used in the app,
on a black macOS squircle. Produces Resources/AppIcon.icns (+ 1024px PNG).

Port of FanIconView.draw (FanPanelView.swift) — keep the two in sync.
"""
import math
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "Resources")
ICNS = os.path.join(OUT_DIR, "AppIcon.icns")
PNG = os.path.join(OUT_DIR, "AppIcon-1024.png")

# On-screen TUI greens (sRGB) — same look as the fan in the window.
DIM = (50, 110, 40)
MID = (91, 185, 65)
BRIGHT = (130, 220, 95)
BG = (0, 0, 0)


def fan_shades(n=21, blade_count=7, angle=0.0):
    """Returns n×n grid of shade levels 0..3 (port of FanIconView.draw)."""
    mid_p = (n - 1) / 2.0
    hub_r = mid_p * 0.22
    outer = mid_p * 0.98
    inner = hub_r * 0.85
    shade = [[0] * n for _ in range(n)]

    def put(xi, yi, s):
        if 0 <= xi < n and 0 <= yi < n and s > 0 and s > shade[yi][xi]:
            shade[yi][xi] = s

    def frange(a, b, step):
        v = a
        while v <= b + 1e-9:
            yield v
            v += step

    for b in range(blade_count):
        a0 = angle + b * (2 * math.pi / blade_count)
        for t in frange(0.0, 1.0, 0.04):
            r = inner + (outer - inner) * t
            sweep = t * t * 1.15
            half_w = (0.12 + 0.55 * math.sin(t * math.pi)) * (outer * 0.12)
            for w in frange(-half_w, half_w, 0.35):
                a = a0 + sweep + w * 0.04
                x = mid_p + math.cos(a) * r - math.sin(a) * w
                y = mid_p + math.sin(a) * r + math.cos(a) * w
                edge = w / max(half_w, 0.01)
                s = 3 if edge > 0.35 else (2 if edge > -0.15 else 1)
                xi, yi = int(round(x)), int(round(y))
                put(xi, yi, s)
                put(xi + 1, yi, s)
                put(xi, yi + 1, min(s, 2))

    hc, hr = int(mid_p), int(round(hub_r))
    for dy in range(-hr, hr + 1):
        for dx in range(-hr, hr + 1):
            if dx * dx + dy * dy <= hr * hr:
                put(hc + dx, hc + dy, 2)
    core = max(hr // 2, 1)
    for dy in range(-core, core + 1):
        for dx in range(-core, core + 1):
            if dx * dx + dy * dy <= core * core:
                xi, yi = hc + dx, hc + dy
                if 0 <= xi < n and 0 <= yi < n:
                    shade[yi][xi] = 1

    # Clip to the outer circle like the view does.
    for yi in range(n):
        for xi in range(n):
            dx, dy = xi - mid_p, yi - mid_p
            if dx * dx + dy * dy > outer * outer:
                shade[yi][xi] = 0
    return shade


def squircle_mask(size, radius_frac=0.2237):
    """macOS-style rounded square (approximated with a superellipse)."""
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    r = size * radius_frac
    # Superellipse with exponent 5 drawn as polygon
    pts = []
    steps = 720
    cx = cy = size / 2
    a = b = size / 2
    nexp = 5.0
    for i in range(steps):
        th = 2 * math.pi * i / steps
        c, s = math.cos(th), math.sin(th)
        x = cx + a * math.copysign(abs(c) ** (2 / nexp), c)
        y = cy + b * math.copysign(abs(s) ** (2 / nexp), s)
        pts.append((x, y))
    d.polygon(pts, fill=255)
    _ = r
    return mask


def render(size=1024):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bg = Image.new("RGBA", (size, size), BG + (255,))
    img.paste(bg, (0, 0), squircle_mask(size))
    d = ImageDraw.Draw(img)

    n = 21
    shade = fan_shades(n)
    # Fan occupies ~78% of the icon
    span = size * 0.78
    cell = span / n
    ox = (size - cell * n) / 2
    oy = (size - cell * n) / 2
    colors = {1: DIM, 2: MID, 3: BRIGHT}
    inset = cell * 0.08
    for yi in range(n):
        for xi in range(n):
            s = shade[yi][xi]
            if s == 0:
                continue
            # view is non-flipped (y up); image is y down
            row = n - 1 - yi
            x0 = ox + xi * cell + inset
            y0 = oy + row * cell + inset
            d.rectangle(
                [x0, y0, x0 + cell - 2 * inset, y0 + cell - 2 * inset],
                fill=colors[s] + (255,),
            )
    return img


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    master = render(1024)
    master.save(PNG)

    tmp = tempfile.mkdtemp()
    iconset = os.path.join(tmp, "AppIcon.iconset")
    os.makedirs(iconset)
    for base in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = base * scale
            name = f"icon_{base}x{base}" + ("@2x" if scale == 2 else "") + ".png"
            master.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
    subprocess.check_call(["iconutil", "-c", "icns", iconset, "-o", ICNS])
    shutil.rmtree(tmp)
    print("wrote", ICNS)
    print("wrote", PNG)


if __name__ == "__main__":
    sys.exit(main())
