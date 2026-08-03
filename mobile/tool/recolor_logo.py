"""Recolor EchoDesk ribbon logo from blue-purple to navy-teal brand palette."""

from __future__ import annotations

import colorsys
import os

from PIL import Image

ROOT = os.path.join(os.path.dirname(__file__), "..", "assets", "brand")
ROOT = os.path.abspath(ROOT)

SRC_WHITE = os.path.join(ROOT, "logo_candidate_ribbon.png")
SRC_DARK = os.path.join(ROOT, "splash_frame.png")


def remap_pixel(r: int, g: int, b: int, a: int, *, dark_bg: bool = False):
    if a < 8:
        return (r, g, b, a)

    mx = max(r, g, b)
    mn = min(r, g, b)
    if mx < 18 and not dark_bg:
        return (r, g, b, a)
    if mn > 245 and a > 200:
        return (r, g, b, a)

    rf, gf, bf = r / 255.0, g / 255.0, b / 255.0
    h, s, v = colorsys.rgb_to_hsv(rf, gf, bf)

    if s < 0.12 or v < 0.08:
        return (r, g, b, a)

    # Purple/magenta -> teal; blue-violet nudged toward navy/teal.
    if h >= 0.70 or h <= 0.05:
        t = ((h - 0.70) % 1.0) / 0.35 if h >= 0.70 else (h + 0.05) / 0.10
        h = 0.48 + 0.06 * min(max(t, 0), 1)
        s = min(1.0, s * 0.95)
    elif 0.58 <= h < 0.70:
        h = 0.55 + (h - 0.58) * 0.35
        s = min(1.0, s * 1.02)
    elif 0.50 <= h < 0.58:
        h = 0.52 + (h - 0.50) * 0.5

    if 0.55 <= h <= 0.68 and v > 0.35:
        v = max(0.18, v * 0.92)

    nr, ng, nb = colorsys.hsv_to_rgb(h, min(s, 1.0), min(v, 1.0))
    return (int(nr * 255), int(ng * 255), int(nb * 255), a)


def recolor(path: str, out_path: str, *, dark_bg: bool = False) -> None:
    im = Image.open(path).convert("RGBA")
    px = im.load()
    w, h = im.size
    for y in range(h):
        for x in range(w):
            px[x, y] = remap_pixel(*px[x, y], dark_bg=dark_bg)
    im.save(out_path)
    print("wrote", out_path, im.size)


def make_transparent_bg(im: Image.Image, threshold: int = 248) -> Image.Image:
    """Turn near-white background into alpha so splash can use navy canvas."""
    im = im.convert("RGBA")
    px = im.load()
    w, h = im.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if r >= threshold and g >= threshold and b >= threshold:
                px[x, y] = (r, g, b, 0)
    return im


def main() -> None:
    os.makedirs(ROOT, exist_ok=True)
    out_ribbon = os.path.join(ROOT, "logo_ribbon_navy_teal.png")
    out_dark = os.path.join(ROOT, "splash_logo_navy_teal.png")
    recolor(SRC_WHITE, out_ribbon, dark_bg=False)
    recolor(SRC_DARK, out_dark, dark_bg=True)

    logo = make_transparent_bg(Image.open(out_ribbon))
    bbox = logo.getbbox()
    if bbox:
        logo = logo.crop(bbox)
    logo.save(os.path.join(ROOT, "logo_ribbon_navy_teal_transparent.png"))

    size = 1024
    # Splash: deep navy + transparent logo
    canvas = Image.new("RGBA", (size, size), (11, 28, 44, 255))
    lw = int(size * 0.58)
    ratio = lw / logo.size[0]
    lh = int(logo.size[1] * ratio)
    logo_r = logo.resize((lw, lh), Image.Resampling.LANCZOS)
    x = (size - lw) // 2
    y = (size - lh) // 2
    canvas.paste(logo_r, (x, y), logo_r)
    splash_path = os.path.join(ROOT, "splash_screen.png")
    canvas.convert("RGB").save(splash_path, quality=95)
    print("wrote", splash_path)

    # Launcher icon candidate on brand cream
    icon = Image.new("RGBA", (size, size), (251, 250, 248, 255))
    lw = int(size * 0.70)
    ratio = lw / logo.size[0]
    lh = int(logo.size[1] * ratio)
    logo_r = logo.resize((lw, lh), Image.Resampling.LANCZOS)
    x = (size - lw) // 2
    y = (size - lh) // 2
    icon.paste(logo_r, (x, y), logo_r)
    icon_path = os.path.join(ROOT, "app_icon_ribbon.png")
    icon.convert("RGB").save(icon_path, quality=95)
    print("wrote", icon_path)


if __name__ == "__main__":
    main()
