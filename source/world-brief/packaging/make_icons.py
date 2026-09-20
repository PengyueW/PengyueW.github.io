#!/usr/bin/env python3
"""Draws every icon the four platforms want, from one description, with Pillow.

The mark is the one the web interface already uses in its header: a ring cut into three arcs,
one per news gravity — conflict, politics, society — on the app's ink background.

    python packaging/make_icons.py
"""
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "packaging" / "icons"

INK_TOP = (38, 38, 36)
INK_BOTTOM = (20, 20, 19)
CONFLICT = (227, 73, 72)
POLITICS = (42, 120, 214)
SOCIETY = (27, 175, 122)
PAPER = (252, 252, 251)

SS = 4          # supersampling factor: draw big, shrink down, get smooth edges

def _rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return m

def _vertical_gradient(size, top, bottom):
    g = Image.new("RGB", (1, size))
    px = g.load()
    for y in range(size):
        t = y / max(size - 1, 1)
        px[0, y] = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
    return g.resize((size, size), Image.BILINEAR)

def draw_mark(size, background=True):
    """The icon at `size` pixels, drawn at SS× and reduced."""
    s = size * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    if background:
        bg = _vertical_gradient(s, INK_TOP, INK_BOTTOM).convert("RGBA")
        bg.putalpha(_rounded_mask(s, int(s * 0.2237)))   # the macOS squircle, near enough
        img.alpha_composite(bg)

    d = ImageDraw.Draw(img)
    pad = s * (0.205 if background else 0.06)
    box = (pad, pad, s - pad, s - pad)
    width = int(s * (0.115 if background else 0.13))

    # Three arcs, each a third of the ring, with a hairline of background between them.
    gap = 3.0 if size >= 48 else 0.0
    for start, colour in ((-90, CONFLICT), (30, POLITICS), (150, SOCIETY)):
        d.arc(box, start + gap, start + 120 - gap, fill=colour, width=width)

    # An equator and one meridian read as a globe; below 48 px they only muddy the ring.
    if size >= 48:
        c = s / 2
        r = c - pad - width * 0.5            # radius of the ring's centre line
        line = max(1, int(s * 0.018))
        grid = Image.new("RGBA", (s, s), (0, 0, 0, 0))
        gd = ImageDraw.Draw(grid)
        gd.line((c - r, c, c + r, c), fill=PAPER + (255,), width=line)
        gd.ellipse((c - r * 0.46, c - r, c + r * 0.46, c + r),
                   outline=PAPER + (255,), width=line)
        # Clip the grid to the disc the ring encloses, so it never crosses the coloured arcs.
        disc = Image.new("L", (s, s), 0)
        ImageDraw.Draw(disc).ellipse((pad + width, pad + width, s - pad - width, s - pad - width), fill=190)
        grid.putalpha(Image.composite(grid.getchannel("A"), Image.new("L", (s, s), 0), disc.point(lambda v: 255 if v else 0)))
        grid.putalpha(grid.getchannel("A").point(lambda v: int(v * 0.72)))
        img.alpha_composite(grid)

    img = img.resize((size, size), Image.LANCZOS)
    if size <= 32:
        img = img.filter(ImageFilter.SHARPEN)
    return img

def write_pngs():
    OUT.mkdir(parents=True, exist_ok=True)
    made = {}
    for size in (16, 24, 32, 48, 64, 128, 256, 512, 1024):
        img = draw_mark(size)
        img.save(OUT / f"icon-{size}.png")
        made[size] = img
    made[512].save(OUT / "icon.png")
    draw_mark(1024, background=False).save(OUT / "icon-mark.png")   # for the DMG art and docs
    return made

def write_ico(made):
    """Windows wants every size inside one .ico."""
    sizes = [(s, s) for s in (16, 24, 32, 48, 64, 128, 256)]
    made[256].save(OUT / "icon.ico", format="ICO", sizes=sizes)

def write_icns(made):
    """macOS: build an .iconset and let iconutil turn it into an .icns."""
    iconset = OUT / "WorldBrief.iconset"
    if iconset.exists():
        for f in iconset.iterdir():
            f.unlink()
    iconset.mkdir(parents=True, exist_ok=True)
    plan = [(16, "icon_16x16.png"), (32, "icon_16x16@2x.png"), (32, "icon_32x32.png"),
            (64, "icon_32x32@2x.png"), (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"), (512, "icon_512x512.png"),
            (1024, "icon_512x512@2x.png")]
    for size, name in plan:
        made[size].save(iconset / name)
    if sys.platform != "darwin":
        print("  .icns skipped (iconutil is macOS-only); the .iconset is ready for a Mac runner")
        return False
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT / "icon.icns")], check=True)
    return True

# --------------------------------------------------------------------------------- DMG artwork

def _font(size, bold=False):
    candidates = [
        "/System/Library/Fonts/SFNSDisplay.ttf", "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Helvetica.ttc", "/Library/Fonts/Arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans%s.ttf" % ("-Bold" if bold else ""),
        "C:/Windows/Fonts/segoeui.ttf",
    ]
    for path in candidates:
        try:
            f = ImageFont.truetype(path, size)
            if bold and path.endswith(".ttc"):
                try:
                    f = ImageFont.truetype(path, size, index=1)
                except OSError:
                    pass
            return f
        except OSError:
            continue
    return ImageFont.load_default(size)

def dmg_background(scale=1):
    """The picture behind the installer window: drag the app onto Applications."""
    w, h = 660 * scale, 420 * scale
    img = Image.new("RGB", (w, h), PAPER)

    # A soft band of the three gravities across the top, so the window is unmistakably ours.
    band = Image.new("RGB", (w, 6 * scale))
    bd = ImageDraw.Draw(band)
    for i, colour in enumerate((CONFLICT, POLITICS, SOCIETY)):
        bd.rectangle((w * i // 3, 0, w * (i + 1) // 3, 6 * scale), fill=colour)
    img.paste(band, (0, 0))

    d = ImageDraw.Draw(img)
    d.text((w // 2, 54 * scale), "World Brief", font=_font(34 * scale, bold=True),
           fill=(26, 26, 25), anchor="mm")
    d.text((w // 2, 88 * scale), "Drag the app into your Applications folder.",
           font=_font(15 * scale), fill=(85, 85, 79), anchor="mm")

    # The arrow runs between the two icon centres that the DMG layout script sets (170, 490 @ y 215).
    y = 215 * scale
    x0, x1 = 248 * scale, 412 * scale
    d.line((x0, y, x1 - 14 * scale, y), fill=(200, 199, 192), width=3 * scale)
    d.polygon([(x1, y), (x1 - 15 * scale, y - 9 * scale), (x1 - 15 * scale, y + 9 * scale)],
              fill=(200, 199, 192))

    d.text((w // 2, 338 * scale), "15 minutes a day. Every nation's press. Both sides.",
           font=_font(13 * scale), fill=(138, 138, 130), anchor="mm")
    d.text((w // 2, 366 * scale),
           "Everything runs on this Mac — no account, no cloud, no external AI service.",
           font=_font(12 * scale), fill=(160, 160, 152), anchor="mm")
    return img

def write_dmg_art():
    mac = ROOT / "packaging" / "macos"
    mac.mkdir(parents=True, exist_ok=True)
    dmg_background(1).save(mac / "dmg-background.png")
    dmg_background(2).save(mac / "dmg-background@2x.png")
    # A multi-resolution TIFF keeps the window crisp on Retina; tiffutil ships with macOS.
    if sys.platform == "darwin":
        try:
            subprocess.run(["tiffutil", "-cathidpicheck", str(mac / "dmg-background.png"),
                            str(mac / "dmg-background@2x.png"), "-out", str(mac / "dmg-background.tiff")],
                           check=True, capture_output=True)
            return True
        except (subprocess.CalledProcessError, FileNotFoundError):
            print("  tiffutil unavailable; the DMG will use the 1× PNG background")
    return False

# ------------------------------------------------------------------------- Windows installer art

def write_wizard_bitmaps(made):
    """Inno Setup wants BMPs: a tall panel down the left of the wizard and a small header mark."""
    win = ROOT / "packaging" / "windows"
    win.mkdir(parents=True, exist_ok=True)

    # The large panel: the ink background the icon uses, with the mark and the promise on it.
    w, h = 164, 314
    large = _vertical_gradient(max(w, h), INK_TOP, INK_BOTTOM).resize((w, h), Image.BILINEAR)
    mark = draw_mark(96, background=False)
    large.paste(mark, ((w - 96) // 2, 46), mark)
    d = ImageDraw.Draw(large)
    d.text((w // 2, 172), "World Brief", font=_font(17, bold=True), fill=PAPER, anchor="mm")
    for i, line in enumerate(("15 minutes a day.", "Every nation's press.", "Both sides.")):
        d.text((w // 2, 200 + i * 17), line, font=_font(11), fill=(170, 170, 162), anchor="mm")
    for i, colour in enumerate((CONFLICT, POLITICS, SOCIETY)):
        d.rectangle((w * i // 3, h - 5, w * (i + 1) // 3, h), fill=colour)
    large.convert("RGB").save(win / "wizard-large.bmp", format="BMP")

    small = Image.new("RGB", (55, 55), PAPER)
    m = made[48].resize((48, 48), Image.LANCZOS)
    small.paste(m, (3, 3), m)
    small.save(win / "wizard-small.bmp", format="BMP")
    return True

# ------------------------------------------------------------------------------ Android icons

ANDROID_DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}

def write_android_icons():
    """Launcher icons for the phone: adaptive foreground plus the legacy square and round ones."""
    res = ROOT / "android" / "app" / "src" / "main" / "res"
    if not res.exists():
        return False

    for density, factor in ANDROID_DENSITIES.items():
        folder = res / f"mipmap-{density}"
        folder.mkdir(parents=True, exist_ok=True)

        # Adaptive foreground: 108 dp of canvas, of which only the middle 66 dp is guaranteed
        # visible, so the mark is drawn at 60% and centred.
        canvas = int(108 * factor)
        fg = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
        mark = draw_mark(int(canvas * 0.60), background=False)
        fg.alpha_composite(mark, ((canvas - mark.width) // 2, (canvas - mark.height) // 2))
        fg.save(folder / "ic_launcher_foreground.png")

        # Legacy icons for Android 7 and older launchers: 48 dp, background included.
        legacy = int(48 * factor)
        square = draw_mark(legacy)
        square.save(folder / "ic_launcher.png")

        round_icon = Image.new("RGBA", (legacy, legacy), (0, 0, 0, 0))
        circle = Image.new("L", (legacy * SS, legacy * SS), 0)
        ImageDraw.Draw(circle).ellipse((0, 0, legacy * SS - 1, legacy * SS - 1), fill=255)
        round_icon.paste(square, (0, 0), circle.resize((legacy, legacy), Image.LANCZOS))
        round_icon.save(folder / "ic_launcher_round.png")

    anydpi = res / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    adaptive = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_foreground" />\n'
        '</adaptive-icon>\n'
    )
    (anydpi / "ic_launcher.xml").write_text(adaptive, "utf-8")
    (anydpi / "ic_launcher_round.xml").write_text(adaptive, "utf-8")

    values = res / "values"
    values.mkdir(parents=True, exist_ok=True)
    (values / "ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        '    <color name="ic_launcher_background">#%02X%02X%02X</color>\n</resources>\n'
        % INK_BOTTOM, "utf-8")
    return True

def main():
    made = write_pngs()
    write_ico(made)
    icns = write_icns(made)
    tiff = write_dmg_art()
    wizard = write_wizard_bitmaps(made)
    android = write_android_icons()
    print(f"icons  -> {OUT}")
    print(f"  png   {', '.join(str(s) for s in sorted(made))}")
    print(f"  ico   {(OUT / 'icon.ico').exists()}")
    print(f"  icns  {icns}")
    print(f"  dmg   background{' + retina tiff' if tiff else ''}")
    print(f"  inno  wizard bitmaps {wizard}")
    print(f"  apk   launcher mipmaps {android}")

if __name__ == "__main__":
    main()
