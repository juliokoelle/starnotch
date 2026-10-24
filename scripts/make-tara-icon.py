"""Renders Resources/AppIcon-1024.png and Resources/AppIcon.icns: Tara (Nova) on a night-sky squircle.

    uv run --with pillow python scripts/make-tara-icon.py [art/astra/nova-neutral-640.webp]

Replaces the older notch-and-wheel icon from make-icon.swift.
"""

import random
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SOURCE = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "art/astra/nova-neutral-640.webp"
SIZE, SHAPE, RADIUS = 1024, 824, 185  # macOS icon grid: 824 pt shape centered on 1024


def squircle_mask() -> Image.Image:
    mask = Image.new("L", (SIZE, SIZE), 0)
    inset = (SIZE - SHAPE) // 2
    ImageDraw.Draw(mask).rounded_rectangle((inset, inset, inset + SHAPE, inset + SHAPE), RADIUS, fill=255)
    return mask


def sky() -> Image.Image:
    """Deep navy at the top fading to violet, a soft glow behind the star, a few small stars."""
    top, bottom = (10, 10, 26), (44, 30, 92)
    sky = Image.new("RGB", (SIZE, SIZE))
    draw = ImageDraw.Draw(sky)
    for y in range(SIZE):
        f = y / (SIZE - 1)
        draw.line([(0, y), (SIZE, y)], fill=tuple(round(a + (b - a) * f) for a, b in zip(top, bottom)))
    glow = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(glow).ellipse((262, 280, 762, 780), fill=150)
    glow = glow.filter(ImageFilter.GaussianBlur(110))
    sky = Image.composite(Image.new("RGB", (SIZE, SIZE), (140, 90, 255)), sky, glow)
    rng = random.Random(7)
    draw = ImageDraw.Draw(sky)
    for _ in range(46):
        x, y = rng.randint(110, 914), rng.randint(110, 914)
        if 250 < x < 774 and 260 < y < 800:
            continue  # keep the star's face clear
        r = rng.choice([1.5, 2, 2, 3])
        shade = rng.randint(150, 255)
        draw.ellipse((x - r, y - r, x + r, y + r), fill=(shade, shade, 255))
    return sky


def main() -> int:
    star = Image.open(SOURCE).convert("RGBA")
    star = star.resize((600, 600), Image.LANCZOS)
    canvas = sky().convert("RGBA")
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 110), (212, 232), star.split()[3])
    shadow = shadow.filter(ImageFilter.GaussianBlur(18))
    canvas = Image.alpha_composite(canvas, shadow)
    canvas.alpha_composite(star, (212, 212))

    icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    icon.paste(canvas, (0, 0), squircle_mask())
    # The drop shadow macOS icons carry under the shape
    under = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    under.paste((0, 0, 0, 90), (0, 10), squircle_mask())
    under = under.filter(ImageFilter.GaussianBlur(24))
    out = Image.alpha_composite(under, icon)

    out.save(ROOT / "Resources/AppIcon-1024.png")
    out.save(ROOT / "Resources/AppIcon.icns", sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    print("wrote Resources/AppIcon-1024.png and Resources/AppIcon.icns")
    return 0


if __name__ == "__main__":
    sys.exit(main())
