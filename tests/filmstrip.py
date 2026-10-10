#!/usr/bin/env python3
"""Captures rapid frames of the real Feather window right after an action, to check animations mid-flight.
Debug build + throwaway profile; moves the real cursor briefly. Writes PNG contact sheets to the given directory.
  tests/filmstrip.py <outdir>
"""
import os, subprocess, sys, time
import ApplicationServices as A, Quartz
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = f"{ROOT}/build/Build/Products/Debug/Feather.app"
OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/filmstrips"
os.makedirs(OUT, exist_ok=True)
SITES = ["https://www.python.org", "https://www.mozilla.org", "https://www.apple.com", "https://news.ycombinator.com"]

subprocess.run(["pkill", "-f", "Debug/Feather.app"]); time.sleep(1)
subprocess.run(["open", "-n", "--stdout", "/private/tmp/feather-film.log", "--stderr", "/private/tmp/feather-film.log", APP, "--args", "--fresh", "--bench", "--load-all", *[f"--open={u}" for u in SITES]])
pid = None
for _ in range(40):
    out = subprocess.run(["pgrep", "-f", "Debug/Feather.app/Contents/MacOS/Feather"], capture_output=True, text=True).stdout.split()
    if out: pid = int(out[0]); break
    time.sleep(0.5)
time.sleep(16)
subprocess.run(["osascript", "-e", f'tell application "System Events" to set frontmost of (first process whose unix id is {pid}) to true']); time.sleep(1)
app = A.AXUIElementCreateApplication(pid)

def attr(e, n):
    err, v = A.AXUIElementCopyAttributeValue(e, n, None); return v if err == 0 else None
def frame(e):
    p, s = attr(e, "AXPosition"), attr(e, "AXSize")
    if p is None or s is None: return None
    _, pt = A.AXValueGetValue(p, A.kAXValueCGPointType, None); _, sz = A.AXValueGetValue(s, A.kAXValueCGSizeType, None)
    return (pt.x, pt.y, sz.width, sz.height)
def find(text, maxd=16):
    hit = []
    def walk(e, d):
        if hit: return
        label = " ".join(str(attr(e, n)) for n in ("AXTitle", "AXValue", "AXDescription", "AXHelp") if attr(e, n))
        f = frame(e)
        if text in label and f and f[0] < 400 and f[2] > 4 and attr(e, "AXRole") in ("AXStaticText", "AXButton", "AXImage", "AXGroup"):
            hit.append(f); return
        if d < maxd:
            for c in (attr(e, "AXChildren") or []): walk(c, d + 1)
    for w in attr(app, "AXWindows") or []: walk(w, 0)
    return hit[0] if hit else None
def center(f): return (f[0] + f[2] / 2, f[1] + f[3] / 2)
def post(kind, x, y):
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, Quartz.CGEventCreateMouseEvent(None, kind, (x, y), Quartz.kCGMouseButtonLeft))
def click(pt):
    post(Quartz.kCGEventMouseMoved, *pt); time.sleep(0.25)
    post(Quartz.kCGEventLeftMouseDown, *pt); time.sleep(0.06); post(Quartz.kCGEventLeftMouseUp, *pt)

def window_id():
    for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID):
        if w.get("kCGWindowOwnerPID") == pid and w.get("kCGWindowLayer") == 0 and w["kCGWindowBounds"]["Width"] > 600:
            return w["kCGWindowNumber"], w["kCGWindowBounds"]
    return None, None
WID, BOUNDS = window_id()

def grab():
    img = Quartz.CGWindowListCreateImage(Quartz.CGRectNull, Quartz.kCGWindowListOptionIncludingWindow, WID, Quartz.kCGWindowImageBoundsIgnoreFraming)
    w, h = Quartz.CGImageGetWidth(img), Quartz.CGImageGetHeight(img)
    data = Quartz.CGDataProviderCopyData(Quartz.CGImageGetDataProvider(img))
    return Image.frombuffer("RGBA", (w, h), bytes(data), "raw", "BGRA", Quartz.CGImageGetBytesPerRow(img), 1).convert("RGB")

def film(name, trigger, n=9, gap=0.045, crop=None, width=360):
    """Take one frame before, trigger, then n frames as fast as capture allows; save a labelled contact sheet."""
    before = grab(); t0 = time.time(); trigger()
    frames = []
    for _ in range(n):
        frames.append((time.time() - t0, grab()))
        time.sleep(gap)
    settle = (time.time() - t0, None)
    time.sleep(0.9); final = grab()
    sc = before.width / BOUNDS["Width"]                     # pixels per point
    box = tuple(int(v * sc) for v in crop) if crop else (0, 0, before.width, before.height)   # crop given in points (x, y, w, h)
    box = (box[0], box[1], box[0] + box[2], box[1] + box[3]) if crop else box
    tiles = [("before", before)] + [(f"{t*1000:.0f} ms", im) for t, im in frames] + [("settled", final)]
    th = int(width * (box[3] - box[1]) / (box[2] - box[0]))
    sheet = Image.new("RGB", (width * len(tiles) + 8 * (len(tiles) + 1), th + 34), (24, 24, 26)); d = ImageDraw.Draw(sheet)
    for i, (label, im) in enumerate(tiles):
        x = 8 + i * (width + 8)
        sheet.paste(im.crop(box).resize((width, th)), (x, 26)); d.text((x + 2, 8), label, fill=(210, 210, 220))
    sheet.save(f"{OUT}/{name}.png"); print("wrote", f"{OUT}/{name}.png", f"({len(frames)} frames over {frames[-1][0]*1000:.0f} ms)")

SIDEBAR = (0, 0, 300, 420)                                   # points, relative to the window
# 1. New tab: row slides in, selection pill moves
nt = find("New Tab"); film("1-new-tab", lambda: click(center(nt)), crop=SIDEBAR, n=8)
# 2. Switch tab: pill glides between rows
row = find("Mozilla"); film("2-select-tab", lambda: click(center(row)), crop=SIDEBAR, n=8)
# 3. Close a tab: row collapses (hover first so the close button shows)
hn = find("Hacker News"); post(Quartz.kCGEventMouseMoved, *center(hn)); time.sleep(0.5)
close = find("Close Tab") or find("Close")
film("3-close-tab", lambda: click(center(close)), crop=SIDEBAR, n=8)
# 4. New tab on a settled window: the start page reveals in sequence (content area)
nt = find("New Tab")
film("4-start-page", lambda: click(center(nt)), crop=(300, 0, BOUNDS["Width"] - 300, BOUNDS["Height"]), n=8, width=330)
# 5. Hide the sidebar (whole window)
tog = find("Hide Sidebar") or find("sidebar")
film("5-hide-sidebar", lambda: click(center(tog)), crop=(0, 0, BOUNDS["Width"], BOUNDS["Height"]), n=7, width=420)
subprocess.run(["pkill", "-f", "Debug/Feather.app"]) if "--keep" not in sys.argv else None
