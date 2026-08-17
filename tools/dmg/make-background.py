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

INK   = (40, 45, 55)                 # Dark ink for light background
EDGE  = (255, 255, 255, 180)         # Light highlight below for engraved effect

# Icon centres, shared with the dmgbuild settings file. Keep in sync.
APP_XY  = (150, 185)
APPS_XY = (390, 185)


def sleek_background(scale: int) -> Image.Image:
    """A sleek, modern light gradient background for the DMG installer."""
    tw, th = W * scale, H * scale
    out = Image.new("RGB", (tw, th))
    draw = ImageDraw.Draw(out)
    
    # Modern light gradient: soft white to platinum/silver
    color_top = (245, 247, 250)
    color_bottom = (210, 215, 225)
    
    for y in range(th):
        r = int(color_top[0] + (color_bottom[0] - color_top[0]) * y / th)
        g = int(color_top[1] + (color_bottom[1] - color_top[1]) * y / th)
        b = int(color_top[2] + (color_bottom[2] - color_top[2]) * y / th)
        draw.line([(0, y), (tw, y)], fill=(r, g, b))
        
    # Subtle top highlight
    draw.line([(0, 0), (tw, 0)], fill=(255, 255, 255))
    
    return out


def engrave(draw, fn, *, scale):
    """Draw something twice: a light edge one pixel low, then the dark ink."""
    fn(draw, EDGE, 1 * scale, scale)
    fn(draw, INK + (255,), 0, scale)


def arrow(draw, colour, dy, scale):
    s = scale
    y = 185 * s + dy
    
    x_end = 300 * s
    x_start = 226 * s
    
    # Straight stem dimensions
    shaft_half = 10 * s
    head_len = 36 * s
    head_half = 32 * s
    
    pts = [
        (x_start, y - shaft_half),
        (x_end - head_len, y - shaft_half),
        (x_end - head_len, y - head_half),
        (x_end, y),
        (x_end - head_len, y + head_half),
        (x_end - head_len, y + shaft_half),
        (x_start, y + shaft_half)
    ]
    
    # Draw outline for extra contrast like the reference image
    outline_color = (255, 255, 255, 255) if colour == INK + (255,) else None
    if outline_color:
        draw.polygon(pts, fill=colour, outline=outline_color, width=2*s)
    else:
        draw.polygon(pts, fill=colour)


def build(scale: int, app_name: str) -> Image.Image:
    img = sleek_background(scale).convert("RGBA")
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
