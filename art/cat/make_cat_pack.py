"""Builds Resources/Characters/cat.notchpack from the cat's single images (1254 x 1254 RGBA).

    python3 art/cat/make_cat_pack.py <images folder> [Resources/Characters/cat.notchpack]

Needs Pillow and numpy. Per image:
  1. Defringe. The cut-outs carry a warm rim (a bright orange-pink glow a few pixels wide) and
     colour spill at the edge. The body's alpha is eroded by ~2 px, and the remaining edge band
     takes its colour from the fur just inside it (an interior colour field), so no coloured or
     bright rim is left. Whiskers (thin structures outside the body) keep their alpha and are
     made neutral light grey.
  2. Frame. Every sitting image is scaled so ear tips to baseline have the same height, centred
     on the head and placed on the same baseline, so states and levels don't jump.
  3. Scale to 240 px tall (the biggest figure the app draws is 118 pt) and write the pack.
"""
import json, os, sys, unicodedata
import numpy as np
from PIL import Image, ImageFilter

SRC = sys.argv[1]
OUT = sys.argv[2] if len(sys.argv) > 2 else "Resources/Characters/cat.notchpack"
H = 240

SITTING = {
    # effort levels: sitting, neutral face, the eyes change
    "level-low": "Gato sonolento de olhos semicerrados.png",
    "level-medium": "Gato Fofo com Pupilas Verticais.png",
    "level-high": "Gatinho cinza fofo em 3D.png",
    "level-xhigh": "Gato Chibi com Olhos Sharingan.png",
    "level-max": "Gato Cinzento de Olhos Vermelhos.png",
    "level-ultra": "Gato Cinza de Olhos Vermelhos ULTRA-CODE.png",
    # expressions: their own (yellow) eyes
    "happy": "Joyful Eyes-Closed Plush Cat.png",
    "asleep": "Serene Plush Cat Portrait.png",
    "sleepy": "Sleepy Plush Cat Portrait.png",
    "surprised": "Surprised Golden-Eyed Kitten.png",
    "focused": "Alert Golden-Eyed Fluffy Cat.png",
    "grumpy": "Gato Cinzento Rabugento com Olhos Dourados.png",
}
PEEK_MAX = "Gato cinza de olhos vermelhos intensos.png"


def find(name):
    want = unicodedata.normalize("NFC", name)
    for entry in os.listdir(SRC):
        if unicodedata.normalize("NFC", entry) == want:
            return os.path.join(SRC, entry)
    raise SystemExit(f"missing {name}")


def min_filter(mask, r):
    """Erosion with a (2r+1)^2 square, numpy only."""
    out = mask.copy()
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            out = np.minimum(out, np.roll(np.roll(mask, dy, 0), dx, 1))
    return out


def max_filter(mask, r):
    return 1 - min_filter(1 - mask, r)


def long_strokes(mask, min_extent):
    """Connected pieces of `mask` (8-neighbour) whose bounding box spans at least `min_extent`
    pixels: whiskers. Short strands of fringe fur drop out."""
    h, w = mask.shape
    seen = np.zeros_like(mask, dtype=bool)
    keep = np.zeros(mask.shape, np.float32)
    ys, xs = np.nonzero(mask)
    for y0, x0 in zip(ys, xs):
        if seen[y0, x0]:
            continue
        stack, pixels = [(y0, x0)], []
        seen[y0, x0] = True
        while stack:
            y, x = stack.pop()
            pixels.append((y, x))
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    ny, nx = y + dy, x + dx
                    if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not seen[ny, nx]:
                        seen[ny, nx] = True
                        stack.append((ny, nx))
        py = [p[0] for p in pixels]
        px = [p[1] for p in pixels]
        if max(max(py) - min(py), max(px) - min(px)) >= min_extent:
            for y, x in pixels:
                keep[y, x] = 1
    return keep


def blur(array, radius):
    img = Image.fromarray(np.clip(array * 255, 0, 255).astype(np.uint8))
    return np.asarray(img.filter(ImageFilter.GaussianBlur(radius)), dtype=np.float32) / 255


def defringe(path):
    rgba = np.asarray(Image.open(path).convert("RGBA"), dtype=np.float32) / 255
    rgb, alpha = rgba[..., :3], rgba[..., 3]
    solid = (alpha > 0.5).astype(np.float32)
    # The body: what survives an opening; thin things outside it are whiskers.
    body = max_filter(min_filter(solid, 4), 4)
    # Only things clear of the body's edge (its soft rim is not a whisker).
    near_body = max_filter(body, 2)
    thin = (alpha > 0.04) & (near_body < 0.5)
    # Strokes found well clear of the body (its soft rim never counts), then grown back along
    # thin pixels to their roots at the cheek.
    far = thin & (max_filter(body, 6) < 0.5)
    whiskers = long_strokes(far, min_extent=28)
    for _ in range(6):
        whiskers = max_filter(whiskers, 1) * thin
    whiskers = whiskers * (alpha > 0.02)
    # Body alpha eroded by ~2 px, soft edge kept.
    body_alpha = np.minimum(alpha, min_filter(alpha, 2)) * max_filter(body, 2)
    # Interior colour field: fur colour from well inside the edge, spread outwards.
    inner = min_filter(body, 9)
    field = np.stack([blur(rgb[..., c] * inner, 8) for c in range(3)], -1)
    weight = blur(inner, 8)[..., None]
    field = np.where(weight > 1e-3, field / np.maximum(weight, 1e-3), rgb)
    # Edge band: 0 deep inside, 1 at the silhouette.
    depth = blur(min_filter(body, 5), 2)
    band = np.clip(1 - depth, 0, 1)[..., None]
    # Keep the fur's light and shade (luminance, capped so the rim's glow goes), take the field's colour.
    lum = rgb @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    flum = field @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    lum = np.minimum(lum, flum * 1.08)
    recoloured = field * (lum / np.maximum(flum, 1e-3))[..., None]
    out_rgb = rgb * (1 - band) + recoloured * band
    # The soft outermost pixels were matted on a dark ground: they take the fur colour itself.
    soft = ((alpha < 0.9) & (body_alpha > 0))[..., None]
    out_rgb = np.where(soft, field, out_rgb)
    # Whiskers outside the body: their own alpha, colour pulled toward a neutral light grey.
    outside = (whiskers > 0) & (near_body < 0.5)
    raw_lum = rgb @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    grey = np.repeat(np.clip(np.maximum(raw_lum, 0.6), 0, 0.9)[..., None], 3, -1)
    out_rgb = np.where(outside[..., None], rgb * 0.25 + grey * 0.75, out_rgb)
    out_alpha = np.maximum(body_alpha, alpha * whiskers)
    out = np.dstack([np.clip(out_rgb, 0, 1), np.clip(out_alpha, 0, 1)])
    return Image.fromarray((out * 255).round().astype(np.uint8))


def figure_box(img):
    a = np.asarray(img.getchannel("A")) > 128
    ys, xs = np.nonzero(a)
    top, bottom = ys.min(), ys.max()
    # Head centre: the mask's middle over the upper third (ears to cheeks).
    head = a[top: top + (bottom - top) // 3]
    hx = np.nonzero(head.any(0))[0]
    return top, bottom, (hx.min() + hx.max()) / 2


def frame(img, ref_height, canvas_w, canvas_h, base_y):
    top, bottom, cx = figure_box(img)
    scale = ref_height / (bottom - top)
    w, h = round(img.width * scale), round(img.height * scale)
    scaled = img.resize((w, h), Image.LANCZOS)
    canvas = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))
    x = round(canvas_w / 2 - cx * scale)
    y = round(base_y - bottom * scale)
    canvas.alpha_composite(scaled, (x, y)) if x >= 0 and y >= 0 else canvas.paste(scaled, (x, y), scaled)
    return canvas


def trim(img):
    box = img.getchannel("A").point(lambda v: 255 if v > 2 else 0).getbbox()
    return img.crop(box)


def main():
    os.makedirs(os.path.join(OUT, "cat"), exist_ok=True)
    clean = {key: defringe(find(name)) for key, name in SITTING.items()}
    # One frame for all sitting images: same figure height, baseline and head centre.
    ref = 900
    canvas_w, canvas_h, base = 1400, 1100, 1040
    framed = {key: frame(img, ref, canvas_w, canvas_h, base) for key, img in clean.items()}
    union = None
    for img in framed.values():
        b = img.getchannel("A").point(lambda v: 255 if v > 2 else 0).getbbox()
        union = b if union is None else (min(union[0], b[0]), min(union[1], b[1]), max(union[2], b[2]), max(union[3], b[3]))
    sprites = {}
    for key, img in framed.items():
        cut = img.crop(union)
        scale = H / cut.height
        cut = cut.resize((round(cut.width * scale), H), Image.LANCZOS)
        cut.save(os.path.join(OUT, "cat", f"{key}.png"), optimize=True)
        sprites[key] = {"file": f"cat/{key}.png", "sourceHeight": H}
    # The lying peek over an edge (max eyes): its own frame, cut at the edge it lies on.
    peek = trim(defringe(find(PEEK_MAX)))
    peek = peek.resize((round(peek.width * H * 0.62 / peek.height), round(H * 0.62)), Image.LANCZOS)
    peek.save(os.path.join(OUT, "cat", "peek-max.png"), optimize=True)
    sprites["peek-max"] = {"file": "cat/peek-max.png", "sourceHeight": peek.height}

    base_states = {
        "idle": "level-high", "focus_working": "focused", "working": "focused", "thinking": "level-high",
        "reply_typing": "level-high", "curious": "surprised", "surprised": "surprised",
        "celebrating": "happy", "happy": "happy", "sad": "grumpy", "error_problem": "grumpy",
        "sleepy": "sleepy", "sleeping": "asleep", "peek": "level-high",
    }
    busy = ["focus_working", "working", "thinking", "reply_typing"]
    names = {"low": "Low eyes", "medium": "Medium eyes", "high": "High eyes", "xhigh": "Extra eyes",
             "max": "Max eyes", "ultra": "Ultra eyes"}
    levels = {}
    for level, name in names.items():
        states = {s: sprites[f"level-{level}"] for s in busy}
        if level == "max":
            states["peek"] = sprites["peek-max"]
        levels[level] = {"name": name, "states": states}
    manifest = {
        "format": 1, "id": "cat", "name": "Cat", "version": "1.0", "license": "Apache-2.0",
        "author": "The Starnotch authors",
        "note": "Effort levels change the eyes while the cat works; expressions bring their own eyes.",
        "characters": [{
            "id": "cat", "name": "Cat", "tint": "#B08A7E", "tintable": False,
            "portrait": sprites["level-high"],
            "states": {s: sprites[k] for s, k in base_states.items()},
            "levels": levels,
        }],
    }
    with open(os.path.join(OUT, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print("wrote", OUT, "frame", union)


if __name__ == "__main__":
    main()
