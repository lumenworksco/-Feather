#!/usr/bin/env python3
"""Builds the icons and the social-preview image (1200x630) for the website from the app icon and the screenshots in site/assets/.
Run after tools/site-screenshots.py. Needs: pip install pillow."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
A = ROOT / "site/assets"
icon = Image.open(ROOT / "Feather/Assets.xcassets/AppIcon.appiconset/icon_1024.png").convert("RGBA")
for name, size in (("icon-512.png", 512), ("apple-touch-icon.png", 180), ("favicon-32.png", 32)):
    icon.resize((size, size), Image.LANCZOS).save(A / name, optimize=True)

W, H = 1200, 630
bg = Image.new("RGB", (W, H), (18, 18, 22))
glow = Image.new("RGB", (W, H), (0, 0, 0)); d = ImageDraw.Draw(glow)
d.ellipse((-100, -300, 800, 420), fill=(95, 88, 160)); d.ellipse((600, 200, 1400, 900), fill=(60, 56, 110))
bg = Image.blend(bg, glow.filter(ImageFilter.GaussianBlur(170)), 0.9) if False else Image.composite(glow.filter(ImageFilter.GaussianBlur(170)), bg, Image.new("L", (W, H), 235))

def font(size, bold=True):
    for p in ("/System/Library/Fonts/SFNSRounded.ttf", "/System/Library/Fonts/Helvetica.ttc"):
        try:
            f = ImageFont.truetype(p, size)
            try: f.set_variation_by_name("Bold" if bold else "Regular")
            except Exception: pass
            return f
        except Exception: continue
    return ImageFont.load_default()

shot = Image.open(A / "app-dark.webp").convert("RGBA")
sw = 720; shot = shot.resize((sw, round(shot.height * sw / shot.width)), Image.LANCZOS)
shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0)); sh = Image.new("RGBA", shot.size, (0, 0, 0, 190)); shadow.paste(sh, (670, 300), shot.split()[3])
bg = Image.alpha_composite(bg.convert("RGBA"), shadow.filter(ImageFilter.GaussianBlur(30)))
bg.alpha_composite(shot, (650, 250))
bg.alpha_composite(icon.resize((112, 112), Image.LANCZOS), (72, 72))
d = ImageDraw.Draw(bg)
d.text((72, 214), "Feather", font=font(92), fill=(238, 236, 250))
d.text((72, 330), "A small, calm browser", font=font(40, False), fill=(190, 186, 224))
d.text((72, 382), "for your Mac.", font=font(40, False), fill=(190, 186, 224))
d.text((72, 520), "Sidebar tabs. Never loses your tabs.", font=font(26, False), fill=(150, 146, 190))
d.text((72, 558), "Free and open source. macOS 14+.", font=font(26, False), fill=(150, 146, 190))
bg.convert("RGB").save(A / "og-image.png", optimize=True)
print("wrote", ", ".join(p.name for p in sorted(A.glob("*")) if p.suffix in (".png",)))
