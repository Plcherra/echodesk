"""Center brand marks in square app-icon canvases with safe padding."""

from __future__ import annotations

import os

from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "assets"))
ICON_DIR = os.path.join(ROOT, "icon")
BRAND_DIR = os.path.join(ROOT, "brand")
SIZE = 1024
# Leave ~18% margin so iOS/Android circular masks don't clip the mark.
SAFE_RATIO = 0.64


def content_bbox(im: Image.Image, bg_threshold: int = 248) -> tuple[int, int, int, int]:
    """BBox of non-near-white / opaque content."""
    im = im.convert("RGBA")
    px = im.load()
    w, h = im.size
    min_x, min_y, max_x, max_y = w, h, 0, 0
    found = False
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a < 12:
                continue
            if r >= bg_threshold and g >= bg_threshold and b >= bg_threshold:
                continue
            found = True
            if x < min_x:
                min_x = x
            if y < min_y:
                min_y = y
            if x > max_x:
                max_x = x
            if y > max_y:
                max_y = y
    if not found:
        return (0, 0, w, h)
    return (min_x, min_y, max_x + 1, max_y + 1)


def fit_centered(
    src_path: str,
    out_path: str,
    *,
    bg: tuple[int, int, int] = (251, 250, 248),
    safe_ratio: float = SAFE_RATIO,
) -> None:
    src = Image.open(src_path).convert("RGBA")
    box = content_bbox(src)
    mark = src.crop(box)

    # Drop near-white so cream canvas shows through (cleaner edges).
    px = mark.load()
    mw, mh = mark.size
    for y in range(mh):
        for x in range(mw):
            r, g, b, a = px[x, y]
            if a > 0 and r >= 248 and g >= 248 and b >= 248:
                px[x, y] = (r, g, b, 0)

    canvas = Image.new("RGBA", (SIZE, SIZE), (*bg, 255))
    max_side = int(SIZE * safe_ratio)
    scale = min(max_side / mark.size[0], max_side / mark.size[1])
    nw = max(1, int(mark.size[0] * scale))
    nh = max(1, int(mark.size[1] * scale))
    resized = mark.resize((nw, nh), Image.Resampling.LANCZOS)
    x = (SIZE - nw) // 2
    y = (SIZE - nh) // 2
    canvas.paste(resized, (x, y), resized)
    canvas.convert("RGB").save(out_path, quality=95)
    print(f"wrote {out_path} (content {box}, placed {nw}x{nh} at {x},{y})")


def main() -> None:
    swirl_src = os.path.join(ICON_DIR, "app_icon_swirl.png")
    ribbon_src = os.path.join(BRAND_DIR, "logo_ribbon_navy_teal_transparent.png")
    if not os.path.exists(ribbon_src):
        ribbon_src = os.path.join(BRAND_DIR, "logo_ribbon_navy_teal.png")

    # Fixed, centered versions.
    fit_centered(
        swirl_src,
        os.path.join(ICON_DIR, "app_icon_swirl.png"),
        safe_ratio=0.72,  # circular mark can fill more
    )
    fit_centered(
        ribbon_src,
        os.path.join(ICON_DIR, "app_icon_ribbon_centered.png"),
        safe_ratio=0.62,  # wide mark needs more side padding
    )
    # Active launcher icon = centered ribbon (current brand direction).
    fit_centered(
        ribbon_src,
        os.path.join(ICON_DIR, "app_icon.png"),
        safe_ratio=0.62,
    )
    # Also refresh brand export used by splash tooling.
    fit_centered(
        ribbon_src,
        os.path.join(BRAND_DIR, "app_icon_ribbon.png"),
        safe_ratio=0.62,
    )


if __name__ == "__main__":
    main()
