#!/usr/bin/env python3
"""Generates the TubeRemote app icon in every form iOS can use. Run from the repo root.

  Assets/AppIcon.icon                          layered Liquid Glass icon (iOS 26+): a background fill and two glass
                                               groups (the play mark, the waves), each recoloured for the default,
                                               dark and tinted appearances
  Assets/Assets.xcassets/AppIcon.appiconset    flat icons for iOS 16 to 25: default (opaque), dark and tinted
                                               (transparent; iOS draws the backdrop under those two, and in tinted
                                               mode keeps only luminance, so that one is authored in greys)
"""

import json
import math
import os
import shutil

from PIL import Image, ImageDraw

SIZE = 1024
S = 4
PX = SIZE * S

CENTER = (449, 512)
PLAY = [(231, 290), (231, 734), (642, 512)]
PLAY_ROUND = 56
ARCS = [(246, 46, 140), (346, 44, 90)]
ARC_WIDTH = 28

BG_LIGHT = ((0x3A, 0x35, 0x90), (0x0B, 0x0A, 0x1A))
BG_DARK = ((0x1A, 0x18, 0x3C), (0x06, 0x06, 0x12))

PALETTES = {
    "light": {"play": (255, 255, 255), "waves": (255, 255, 255)},
    "dark": {"play": (238, 238, 255), "waves": (190, 190, 255)},
    "tinted": {"play": (255, 255, 255), "waves": (204, 204, 204)},
}


def px(v):
    return v * S


def rounded_triangle(points, radius):
    """Mask of a triangle with rounded corners: a smaller copy, thickened by a round pen."""
    cx = sum(p[0] for p in points) / 3
    cy = sum(p[1] for p in points) / 3
    sides = [math.dist(points[i], points[(i + 1) % 3]) for i in range(3)]
    area = abs((points[1][0] - points[0][0]) * (points[2][1] - points[0][1])
               - (points[2][0] - points[0][0]) * (points[1][1] - points[0][1])) / 2
    inradius = 2 * area / sum(sides)
    k = (inradius - radius) / inradius
    small = [(px(cx + (x - cx) * k), px(cy + (y - cy) * k)) for x, y in points]
    mask = Image.new("L", (PX, PX), 0)
    d = ImageDraw.Draw(mask)
    d.polygon(small, fill=255)
    for a, b in zip(small, small[1:] + small[:1]):
        d.line([a, b], fill=255, width=int(2 * px(radius)))
    for x, y in small:
        r = px(radius)
        d.ellipse([x - r, y - r, x + r, y + r], fill=255)
    return mask


def waves_mask():
    """Both arcs in one mask; each arc's alpha is baked in so it survives recolouring."""
    mask = Image.new("L", (PX, PX), 0)
    for radius, half_angle, alpha in ARCS:
        arc = Image.new("L", (PX, PX), 0)
        d = ImageDraw.Draw(arc)
        cx, cy, r = px(CENTER[0]), px(CENTER[1]), px(radius)
        # PIL strokes an arc inward from its box, so grow the box by half the pen to centre the stroke on `radius`.
        o = r + px(ARC_WIDTH) / 2
        d.arc([cx - o, cy - o, cx + o, cy + o], -half_angle, half_angle, fill=alpha, width=px(ARC_WIDTH))
        for sign in (-1, 1):
            a = math.radians(sign * half_angle)
            ex, ey = cx + r * math.cos(a), cy + r * math.sin(a)
            cap = px(ARC_WIDTH) / 2
            d.ellipse([ex - cap, ey - cap, ex + cap, ey + cap], fill=alpha)
        mask = Image.composite(arc, mask, arc.point(lambda v: 255 if v else 0))
    return mask


def layer(mask, colour):
    out = Image.new("RGBA", (PX, PX), colour + (0,))
    out.putalpha(mask)
    return out.resize((SIZE, SIZE), Image.LANCZOS)


def gradient(top, bottom):
    """Diagonal, light corner at the top left."""
    col = Image.new("RGB", (PX, PX))
    pixels = col.load()
    for y in range(PX):
        for x in range(0, PX):
            t = (x + y) / (2 * PX)
            pixels[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
    return col


def srgb(c):
    return "srgb:%.5f,%.5f,%.5f,1.00000" % tuple(v / 255 for v in c)


def fills(name):
    return [{"value": {"solid": srgb(PALETTES["light"][name])}},
            {"appearance": "dark", "value": {"solid": srgb(PALETTES["dark"][name])}},
            {"appearance": "tinted", "value": {"solid": srgb(PALETTES["tinted"][name])}}]


def write_icon_package(path, play, waves):
    if os.path.isdir(path):
        shutil.rmtree(path)
    os.makedirs(os.path.join(path, "Assets"))
    layer(play, PALETTES["light"]["play"]).save(os.path.join(path, "Assets", "play.png"))
    layer(waves, PALETTES["light"]["waves"]).save(os.path.join(path, "Assets", "waves.png"))
    glass = {"lighting": "individual", "specular": True}
    document = {
        "fill-specializations": [
            {"value": {"linear-gradient": [srgb(c) for c in BG_LIGHT]}},
            {"appearance": "dark", "value": {"linear-gradient": [srgb(c) for c in BG_DARK]}},
        ],
        "groups": [
            dict(glass, name="Play", shadow={"kind": "neutral", "opacity": 0.5},
                 translucency={"enabled": True, "value": 0.2},
                 layers=[{"name": "Play", "image-name": "play.png", "glass": True,
                          "fill-specializations": fills("play")}]),
            dict(glass, name="Waves", shadow={"kind": "neutral", "opacity": 0.3},
                 translucency={"enabled": True, "value": 0.4},
                 layers=[{"name": "Waves", "image-name": "waves.png", "glass": True,
                          "fill-specializations": fills("waves")}]),
        ],
        "supported-platforms": {"squares": "shared"},
    }
    with open(os.path.join(path, "icon.json"), "w") as fh:
        json.dump(document, fh, indent=2, sort_keys=True)
        fh.write("\n")


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    assets = os.path.join(root, "Assets")
    appiconset = os.path.join(assets, "Assets.xcassets", "AppIcon.appiconset")
    play, waves = rounded_triangle(PLAY, PLAY_ROUND), waves_mask()

    flat = gradient(*BG_LIGHT).convert("RGBA")
    for mask, name in ((play, "play"), (waves, "waves")):
        flat.alpha_composite(layer(mask, PALETTES["light"][name]).resize((PX, PX)))
    flat.resize((SIZE, SIZE), Image.LANCZOS).convert("RGB").save(os.path.join(appiconset, "icon.png"))
    for appearance in ("dark", "tinted"):
        img = Image.new("RGBA", (PX, PX), (0, 0, 0, 0))
        for mask, name in ((play, "play"), (waves, "waves")):
            img.alpha_composite(layer(mask, PALETTES[appearance][name]).resize((PX, PX)))
        img.resize((SIZE, SIZE), Image.LANCZOS).save(os.path.join(appiconset, "icon-%s.png" % appearance))

    contents = {"images": [
        {"filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "dark"}], "filename": "icon-dark.png",
         "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "tinted"}], "filename": "icon-tinted.png",
         "idiom": "universal", "platform": "ios", "size": "1024x1024"},
    ], "info": {"author": "xcode", "version": 1}}
    with open(os.path.join(appiconset, "Contents.json"), "w") as fh:
        json.dump(contents, fh, indent=2)
        fh.write("\n")
    write_icon_package(os.path.join(assets, "AppIcon.icon"), play, waves)


if __name__ == "__main__":
    main()
