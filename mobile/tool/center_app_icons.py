"""Center the EchoDesk ribbon-e mark in square app-icon canvases."""

from __future__ import annotations

import os

from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "assets"))
ICON_DIR = os.path.join(ROOT, "icon")
BRAND_DIR = os.path.join(ROOT, "brand")
SIZE = 1024
SAFE_RATIO = 0.66
BG = (251, 250, 248)


def content_bbox(im: Image.Image) -> tuple[int, int, int, int]:
    im = im.convert("RGBA")
    px = im.load()
    w, h = im.size
    corners = [px[2, 2], px[w - 3, 2], px[2, h - 3], px[w - 3, h - 3]]

    def is_bg(r: int, g: int, b: int, a: int) -> bool:
        if a < 10:
            return True
        for cr, cg, cb, _ca in corners:
            if abs(r - cr) < 22 and abs(g - cg) < 22 and abs(b - cb) < 22:
                return True
        return r >= 242 and g >= 242 and b >= 242

    min_x, min_y, max_x, max_y = w, h, 0, 0
    found = False
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if is_bg(r, g, b, a):
                continue
            found = True
            min_x = min(min_x, x)
            min_y = min(min_y, y)
            max_x = max(max_x, x)
            max_y = max(max_y, y)
    if not found:
        return (0, 0, w, h)
    return (min_x, min_y, max_x + 1, max_y + 1)


def fit_centered(src_path: str, out_path: str, *, safe_ratio: float = SAFE_RATIO) -> None:
    src = Image.open(src_path).convert("RGBA")
    mark = src.crop(content_bbox(src))
    px = mark.load()
    mw, mh = mark.size
    for y in range(mh):
        for x in range(mw):
            r, g, b, a = px[x, y]
            if a > 0 and r >= 248 and g >= 248 and b >= 248:
                px[x, y] = (r, g, b, 0)

    canvas = Image.new("RGBA", (SIZE, SIZE), (*BG, 255))
    max_side = int(SIZE * safe_ratio)
    scale = min(max_side / mark.size[0], max_side / mark.size[1])
    nw = max(1, int(mark.size[0] * scale))
    nh = max(1, int(mark.size[1] * scale))
    resized = mark.resize((nw, nh), Image.Resampling.LANCZOS)
    x = (SIZE - nw) // 2
    y = (SIZE - nh) // 2
    canvas.paste(resized, (x, y), resized)
    canvas.convert("RGB").save(out_path, quality=95)
    print(f"wrote {out_path}")


def main() -> None:
    raw = os.path.join(ICON_DIR, "app_icon_e_raw.png")
    if not os.path.exists(raw):
        raise SystemExit(f"missing {raw}")
    fit_centered(raw, os.path.join(ICON_DIR, "app_icon.png"))
    fit_centered(raw, os.path.join(BRAND_DIR, "app_icon_ribbon.png"))


if __name__ == "__main__":
    main()
