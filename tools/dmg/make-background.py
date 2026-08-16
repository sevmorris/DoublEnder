#!/usr/bin/env python3
"""Generate the DMG window background (1x and 2x).

The art is deliberately derived from the faceplate itself: the brushed metal is
sampled from a clean region of de_faceplate.png rather than faked, so the
installer window reads as part of the same object as the app. The arrow and
label are drawn engraved — dark ink with a one-pixel light edge below — matching
how RECORDING and the wordmark are cut into the plate.

Usage: python3 tools/dmg/make-background.py [--out DIR]
"""
import argparse, os
from PIL import Image, ImageDraw, ImageFont

W, H = 540, 380                      # DMG window content size, 1x
PLATE = "DoublEnder/SharedAssets.xcassets/de_faceplate.imageset/de_faceplate.png"
FONT = os.path.expanduser("~/Library/Fonts/Eurostile.otf")

INK   = (36, 33, 30)                 # engraved dark
EDGE  = (255, 255, 255, 90)          # light lower edge that sells the cut

# Icon centres, shared with the dmgbuild settings file. Keep in sync.
APP_XY  = (150, 185)
APPS_XY = (390, 185)


def metal(scale: int) -> Image.Image:
    """A brushed-metal field sampled from the faceplate's own clean bezel.

    Sampled at NATIVE resolution and tiled rather than upscaled: the brushing is
    fine directional detail that turns to mush if a small patch is stretched.
    The source is the top bezel, which is the largest genuinely label-free area
    of the plate (verified: no engraved ink, fully opaque). Vertical tiling is
    mirrored so the horizontal brush direction is preserved and no seam shows.
    """
    src = Image.open(PLATE).convert("RGB")
    sw, sh = src.size
    strip = src.crop((int(sw * 0.12), int(sh * 0.03), int(sw * 0.88), int(sh * 0.16)))

    tw, th = W * scale, H * scale
    if strip.width < tw:                       # widen by mirrored tiling if needed
        reps = -(-tw // strip.width) + 1
        wide = Image.new("RGB", (strip.width * reps, strip.height))
        for i in range(reps):
            piece = strip if i % 2 == 0 else strip.transpose(Image.FLIP_LEFT_RIGHT)
            wide.paste(piece, (i * strip.width, 0))
        strip = wide
    strip = strip.crop((0, 0, tw, strip.height))

    out = Image.new("RGB", (tw, th))
    y, flip = 0, False
    while y < th:
        piece = strip.transpose(Image.FLIP_TOP_BOTTOM) if flip else strip
        out.paste(piece, (0, y))
        y += strip.height
        flip = not flip
    return out


def engrave(draw, fn, *, scale):
    """Draw something twice: a light edge one pixel low, then the dark ink."""
    fn(draw, EDGE, 0, scale)
    fn(draw, INK + (255,), -1 * scale, scale)


def arrow(draw, colour, dy, scale):
    s = scale
    y = 185 * s + dy
    x0, x1 = 236 * s, 306 * s
    shaft = 7 * s
    head = 19 * s
    draw.rounded_rectangle([x0, y - shaft // 2, x1 - head, y + shaft // 2],
                           radius=shaft // 2, fill=colour)
    draw.polygon([(x1, y), (x1 - head, y - head // 2 - 2 * s),
                  (x1 - head, y + head // 2 + 2 * s)], fill=colour)


def build(scale: int, app_name: str) -> Image.Image:
    img = metal(scale).convert("RGBA")
    d = ImageDraw.Draw(img)
    engrave(d, arrow, scale=scale)

    def caption(dr, colour, dy, s):
        f = ImageFont.truetype(FONT, 17 * s)
        txt = f"Drag {app_name} to Applications"
        w = dr.textlength(txt, font=f)
        dr.text(((W * s - w) / 2, 291 * s + dy), txt, font=f, fill=colour)
    engrave(d, caption, scale=scale)
    return img.convert("RGB")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="tools/dmg")
    ap.add_argument("--app-name", default="DoublEnder")
    ap.add_argument("--slug", default="doublender")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    one = build(1, a.app_name)
    two = build(2, a.app_name)
    p1 = os.path.join(a.out, f"dmg-background-{a.slug}.png")
    p2 = os.path.join(a.out, f"dmg-background-{a.slug}@2x.png")
    one.save(p1); two.save(p2)
    print(f"{p1}  {one.size}")
    print(f"{p2}  {two.size}")


if __name__ == "__main__":
    main()
