#!/usr/bin/env python3
#
#  compose_screenshots.py
#  CatchMatch
#
#  Created by Michel Storms on 19/09/2026.
#
"""Frame the latest raw captures into Gumroad / landing-page images. #105

Reads   Scripts/screenshots/output/<latest>/raw/*.png
Writes  Scripts/screenshots/output/<latest>/gumroad/
          cover.png            2560x1440  (Gumroad cover, 1280x720 @2x)
          thumbnail.png        1200x1200  (Gumroad thumbnail, 600x600 @2x)
          gallery_01_queue.png …        2560x1440, one per scene, with a headline
Prints the gumroad/ path.
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent
ICON = REPO / "dlp2music/dlp2music/Assets.xcassets/AppIcon.appiconset/mac1024.png"

WIDE = (2560, 1440)
SQUARE = (1200, 1200)
# Coral, sampled from the app icon (top → bottom of its gradient).
TOP = (231, 84, 74)
BOTTOM = (242, 150, 138)
INK = (255, 255, 255)

HEADLINES = {
    "01_Queue": ("Drop in links or files.", "Watch them land in your library."),
    "02_Imported": ("Straight into Apple Music", "and Apple TV."),
    "03_Empty": ("One window. No Terminal.", "Your recordings, purchases and open archives."),
}
COVER_SCENE = "01_Queue"
COVER_LINES = ("CatchMatch", "Your recordings and purchases, in Apple Music.")


def latest_run() -> Path:
    runs = sorted(p for p in (ROOT / "output").glob("*/raw") if any(p.glob("*.png")))
    if not runs:
        sys.exit("No captures in Scripts/screenshots/output/*/raw — run generate_screenshots.sh first.")
    return runs[-1].parent


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    candidates = [
        ("/System/Library/Fonts/SFNS.ttf", None),
        ("/System/Library/Fonts/Helvetica.ttc", 1 if bold else 0),
    ]
    for path, index in candidates:
        try:
            f = ImageFont.truetype(path, size, index=index or 0)
            if path.endswith("SFNS.ttf"):
                try:
                    f.set_variation_by_name("Bold" if bold else "Regular")
                except Exception:
                    pass
            return f
        except OSError:
            continue
    return ImageFont.load_default(size)


def gradient(size: tuple[int, int]) -> Image.Image:
    w, h = size
    img = Image.new("RGBA", size)
    draw = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(h - 1, 1)
        c = tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
        draw.line([(0, y), (w, y)], fill=c + (255,))
    return img


def rounded(img: Image.Image, radius: int) -> Image.Image:
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, *img.size], radius=radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out


def paste_with_shadow(canvas: Image.Image, img: Image.Image, x: int, y: int) -> None:
    pad = 80
    shadow = Image.new("RGBA", (img.width + pad * 2, img.height + pad * 2), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [pad, pad + 24, pad + img.width, pad + img.height + 24], radius=28, fill=(60, 20, 15, 110))
    shadow = shadow.filter(ImageFilter.GaussianBlur(36))
    canvas.alpha_composite(shadow, (x - pad, y - pad))
    canvas.alpha_composite(img, (x, y))


def fit(img: Image.Image, max_w: int, max_h: int) -> Image.Image:
    scale = min(max_w / img.width, max_h / img.height)
    return img.resize((round(img.width * scale), round(img.height * scale)), Image.LANCZOS)


def centered_text(draw: ImageDraw.ImageDraw, text: str, y: int, f: ImageFont.FreeTypeFont,
                  width: int, alpha: int = 255) -> int:
    box = draw.textbbox((0, 0), text, font=f)
    draw.text(((width - (box[2] - box[0])) // 2, y), text, font=f, fill=INK + (alpha,))
    return y + (box[3] - box[1])


def window(raw: Path) -> Image.Image:
    return rounded(Image.open(raw), 24)


def compose_wide(raw: Path, lines: tuple[str, str], out: Path) -> None:
    canvas = gradient(WIDE)
    draw = ImageDraw.Draw(canvas)
    y = centered_text(draw, lines[0], 110, font(104, bold=True), WIDE[0])
    y = centered_text(draw, lines[1], y + 36, font(60), WIDE[0], alpha=225)
    shot = fit(window(raw), 1900, WIDE[1] - y - 150)
    paste_with_shadow(canvas, shot, (WIDE[0] - shot.width) // 2, y + 90)
    canvas.convert("RGB").save(out, optimize=True)


def compose_thumbnail(out: Path) -> None:
    canvas = gradient(SQUARE)
    icon = Image.open(ICON).convert("RGBA").resize((620, 620), Image.LANCZOS)
    paste_with_shadow(canvas, icon, (SQUARE[0] - 620) // 2, 190)
    draw = ImageDraw.Draw(canvas)
    centered_text(draw, "CatchMatch", 880, font(120, bold=True), SQUARE[0])
    canvas.convert("RGB").save(out, optimize=True)


def main() -> None:
    run = latest_run()
    raws = {p.stem: p for p in sorted((run / "raw").glob("*.png"))}
    out_dir = run / "gumroad"
    out_dir.mkdir(exist_ok=True)

    missing = [name for name in HEADLINES if name not in raws]
    if missing:
        sys.exit(f"Missing captures: {', '.join(missing)} — check the ScreenshotTests run.")

    for name, raw in raws.items():
        lines = HEADLINES.get(name, (name.split("_", 1)[-1], ""))
        compose_wide(raw, lines, out_dir / f"gallery_{name.lower()}.png")
    if COVER_SCENE in raws:
        compose_wide(raws[COVER_SCENE], COVER_LINES, out_dir / "cover.png")
    compose_thumbnail(out_dir / "thumbnail.png")
    print(out_dir)


if __name__ == "__main__":
    main()
