#!/usr/bin/env python3
"""Captures the screenshots used on the website (site/assets/), from the CURRENT app, using only made-up demo sites.

  python3 tools/site-screenshots.py [path/to/Feather.app]      (default: the Debug build in build/)

Nothing private is involved: a throwaway profile, and a local web server that pretends to be eight small websites
(notes.localhost, recipes.localhost, ...) with their own icons, so no third-party logos or pages appear.
Needs: pip install pillow. Writes WebP files; run `python3 tools/site-screenshots.py` again whenever the app's look changes.
"""
import io, json, os, shutil, socket, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer as HTTPServer
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import Quartz

ROOT = Path(__file__).resolve().parent.parent
APP = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "build/Build/Products/Debug/Feather.app"
OUT = ROOT / "site/assets"
PORT = 8841
HOME = Path.home()
PROFILE_ROOT = HOME / "Library/Containers/dev.feather.Feather/Data/tmp"

# The app only loads plain-http pages from localhost and raw IP addresses, so four loopback names stand in for four websites.
# host -> (name, accent colour, letter)
SITES = {
    "localhost": ("Notes",   (160, 154, 218), "N"),
    "127.0.0.1": ("Recipes", (240, 140, 188), "R"),
    "[::1]":     ("Trips",   (84, 204, 199),  "T"),
    "[::ffff:127.0.0.1]": ("Music", (115, 166, 247), "M"),
}
# (host, path) -> (headline, blurb)
PAGES = {
    ("localhost", "/"):      ("A quiet place to think", "Short notes, long thoughts, and nothing in between asking for your attention."),
    ("127.0.0.1", "/"):      ("Cook something simple tonight", "Twelve weeknight dinners that need one pan and about twenty minutes."),
    ("[::1]", "/"):          ("Plan a long weekend", "Trams, tiles and a sunset worth the climb. Three days without a spreadsheet."),
    ("[::ffff:127.0.0.1]", "/"): ("Quiet focus mix", "Two hours of instrumental pieces for the kind of work that needs a closed door."),
    ("localhost", "/reading"):   ("Reading list", "Seven books waiting by the window. Start with the short one."),
    ("localhost", "/garden"):    ("What to plant this autumn", "Bulbs, garlic and a few brave greens that will thank you in spring."),
    ("127.0.0.1", "/miso"):      ("Miso soup in ten minutes", "Dashi, miso, tofu, and a little patience. That is the whole recipe."),
    ("[::1]", "/lisbon"):        ("A long weekend in Lisbon", "Tram 28, the tiles of Alfama, and the miradouro at sunset."),
    ("[::ffff:127.0.0.1]", "/spring"): ("Spring collection, first draft", "Colour studies, a few silhouettes, and a list of things still to decide."),
    ("127.0.0.1", "/weather"):   ("Clear until Thursday", "Light wind from the west, a cool morning, and a warm afternoon."),
}
PINNED = list(SITES)
TABS = [("127.0.0.1", "/miso"), ("localhost", "/garden"), ("localhost", "/reading"), ("[::ffff:127.0.0.1]", "/spring"), ("[::1]", "/lisbon")]


def icon_png(letter, rgb):
    img = Image.new("RGBA", (128, 128), (0, 0, 0, 0)); d = ImageDraw.Draw(img)
    d.rounded_rectangle((4, 4, 124, 124), radius=30, fill=rgb + (255,))
    for path in ("/System/Library/Fonts/SFNSRounded.ttf", "/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/Supplemental/Arial Bold.ttf"):
        try: font = ImageFont.truetype(path, 78); break
        except Exception: font = None
    font = font or ImageFont.load_default()
    box = d.textbbox((0, 0), letter, font=font)
    d.text(((128 - (box[2] - box[0])) / 2 - box[0], (128 - (box[3] - box[1])) / 2 - box[1] - 2), letter, font=font, fill=(255, 255, 255, 255))
    buf = io.BytesIO(); img.save(buf, "PNG"); return buf.getvalue()


def page(host, path):
    name, rgb, letter = SITES[host]
    headline, blurb = PAGES.get((host, path), PAGES[(host, "/")])
    col = "rgb(%d,%d,%d)" % rgb
    body = "".join(f"<p>{t}</p>" for t in (
        blurb,
        "It starts small: one idea, written down before it gets away. The rest follows, a little at a time, in whatever order suits you.",
        "Nothing here tracks you, and nothing here is in a hurry. Take the afternoon.",
    ))
    return f"""<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>{headline} - {name}</title><link rel=icon href=/icon.png>
<style>:root{{color-scheme:light dark;--a:{col}}}
body{{margin:0;font:18px/1.6 ui-rounded,system-ui,sans-serif;background:Canvas;color:CanvasText}}
header{{display:flex;align-items:center;gap:12px;padding:22px 56px;font-weight:700}} header i{{width:26px;height:26px;border-radius:8px;background:var(--a);display:inline-block}}
.hero{{margin:8px 56px 0;height:250px;border-radius:26px;background:radial-gradient(120% 140% at 15% 0%,color-mix(in srgb,var(--a) 85%,white),var(--a) 45%,color-mix(in srgb,var(--a) 55%,black))}}
main{{max-width:680px;margin:0 auto;padding:34px 24px 80px}} h1{{font-size:46px;line-height:1.1;margin:0 0 14px;letter-spacing:-.02em}}
p{{margin:0 0 16px;opacity:.82}}</style>
<header><i></i>{name}</header><div class=hero></div><main><h1>{headline}</h1>{body}</main>""".encode()


class Demo(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        raw = self.headers.get("Host", "")
        host = ("[::ffff:127.0.0.1]" if raw.startswith("[::ffff") else "[::1]") if raw.startswith("[") else raw.rsplit(":", 1)[0]
        if host not in SITES: self.send_response(404); self.end_headers(); return
        if self.path == "/icon.png": data, ctype = icon_png(SITES[host][2], SITES[host][1]), "image/png"
        elif self.path == "/signin": data, ctype = SIGNIN.encode(), "text/html"
        else: data, ctype = page(host, self.path), "text/html; charset=utf-8"
        self.send_response(200); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)


SIGNIN = """<!doctype html><title>Sign in - Notes</title><link rel=icon href=/icon.png><meta name=color-scheme content="light dark">
<body style="font:20px ui-rounded,system-ui;display:grid;place-items:center;height:90vh"><div style="text-align:center"><h1>Sign in to Notes</h1><p>Use your security key.</p></div>
<script>setTimeout(()=>navigator.credentials.get({publicKey:{challenge:new Uint8Array(32),rpId:location.hostname,userVerification:"discouraged",timeout:120000}}).catch(()=>{}),800)</script>"""


LOAD_ALL = ["--load-all", "--lifecycle=off"]      # load every tab (not just the selected one) and never unload, so titles and icons are all there


def url(host, path="/"): return f"http://{host}:{PORT}{path}"


def seed(profile, with_bookmarks=True):
    d = PROFILE_ROOT / f"FeatherProfile-{profile}"; shutil.rmtree(d, ignore_errors=True); d.mkdir(parents=True)
    import uuid
    if with_bookmarks:
        (d / "bookmarks.json").write_text(json.dumps([{"id": str(uuid.uuid4()), "title": SITES[h][0], "url": url(h)} for h in PINNED]))
        now = time.time() - 978307200
        (d / "history.json").write_text(json.dumps([{"url": url(h, p), "title": PAGES.get((h, p), PAGES[(h, "/")])[0], "lastVisit": now - 600 * i, "visits": 1} for i, (h, p) in enumerate(TABS)]))
    return d


def shot(name, args, appearance, size, wait=9, new_tab=False, crop=None, round_corners=0):
    seed_dir = seed(name)
    cmd = ["open", "-n", str(APP), "--args", f"--profile={name}", f"--appearance={appearance}", f"--window-size={size}"] + args
    subprocess.run(cmd); time.sleep(wait)
    pid = int(subprocess.run(["pgrep", "-f", f"{APP}/Contents/MacOS/Feather"], capture_output=True, text=True).stdout.split()[0])
    subprocess.run(["osascript", "-e", f'tell application "System Events" to set frontmost of (first process whose unix id is {pid}) to true'], capture_output=True)
    time.sleep(2)
    if new_tab:      # clear the history the loads just recorded (so no "recent sites" chips with machine-looking names), then a fresh tab selects the start page (and shows no address, so no plain-http padlock in a marketing image)
        subprocess.run(["osascript", "-e", f'tell application "System Events" to tell (first process whose unix id is {pid}) to click menu item "Clear History" of menu "History" of menu bar item "History" of menu bar 1'], capture_output=True); time.sleep(1.5)
        subprocess.run(["osascript", "-e", 'tell application "System Events" to keystroke "t" using command down'], capture_output=True); time.sleep(2.5)
    win = None
    for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID):
        b = w["kCGWindowBounds"]
        if w.get("kCGWindowOwnerPID") == pid and b["Width"] > 600 and b["Height"] > 400: win = w["kCGWindowNumber"]; break
    png = Path(f"/tmp/feather-shot-{name}.png")
    subprocess.run(["screencapture", "-x", "-o", "-l", str(win), str(png)], check=True)
    subprocess.run(["kill", "-9", str(pid)]); time.sleep(1)
    img = Image.open(png).convert("RGBA")      # keep the window's rounded, transparent corners
    if crop: img = img.crop((int(crop[0] * img.width), int(crop[1] * img.height), int(crop[2] * img.width), int(crop[3] * img.height)))
    if round_corners:      # cut the crop out as a floating card with transparent rounded corners
        mask = Image.new("L", img.size, 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.width - 1, img.height - 1), radius=round_corners, fill=255)
        img.putalpha(mask)
    if img.width > 2200: img = img.resize((2200, round(img.height * 2200 / img.width)), Image.LANCZOS)
    OUT.mkdir(parents=True, exist_ok=True)
    img.save(OUT / f"{name}.webp", "WEBP", quality=88, method=6)
    print(f"{name}: {img.width}x{img.height} -> site/assets/{name}.webp ({(OUT / f'{name}.webp').stat().st_size // 1024} KB)")


def main():
    class Dual(HTTPServer): address_family = socket.AF_INET6          # "::" answers 127.0.0.1, ::1, localhost and ::ffff:127.0.0.1
    srv = Dual(("::", PORT), Demo); threading.Thread(target=srv.serve_forever, daemon=True).start()
    pinned = [f"--open-pinned={url(h)}" for h in PINNED]
    tabs = [f"--open={url(h, p)}" for h, p in TABS]
    names = ("app-dark", "app-light", "securitykey")
    try:
        shot("app-dark", pinned + tabs + LOAD_ALL, "dark", "1280x800", wait=14, new_tab=True)
        shot("app-light", pinned + tabs + LOAD_ALL, "light", "1280x800", wait=14, new_tab=True)
        shot("securitykey", [f"--open={url('localhost', '/signin')}"], "dark", "900x560", wait=10, crop=(0.312, 0.347, 0.685, 0.653), round_corners=34)
    finally:
        srv.shutdown()
        for h in names: shutil.rmtree(PROFILE_ROOT / f"FeatherProfile-{h}", ignore_errors=True)


main()
