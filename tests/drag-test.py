#!/usr/bin/env python3
"""Real-mouse drag-and-drop test for the sidebar (Debug build, throwaway profile). Needs Accessibility permission for the
terminal running it (it moves the real cursor for a few seconds: don't touch the mouse).
  tests/drag-test.py
"""
import os, re, subprocess, sys, time
import ApplicationServices as A, Quartz

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = f"{ROOT}/build/Build/Products/Debug/Feather.app"
LOG = "/private/tmp/feather-drag-test.log"
SITES = ["https://www.python.org", "https://www.mozilla.org", "https://www.apple.com", "https://news.ycombinator.com"]
KEY = {"python.org": "python", "mozilla.org": "mozilla", "apple.com": "apple", "ycombinator.com": "hn"}
passed = failed = 0

def check(name, ok, detail=""):
    global passed, failed
    if ok: passed += 1
    else: failed += 1
    print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else f"   ({detail})"), flush=True)

# This test only ever starts/kills the *Debug* build (matched by its path), never an installed /Applications/Feather.app,
# so a real session can stay open. It does move the real cursor, and the Debug window is brought to the front first.
if not A.AXIsProcessTrusted():
    sys.exit("Accessibility permission is missing for this terminal.")

subprocess.run(["pkill", "-f", "Debug/Feather.app"]); time.sleep(1)
open(LOG, "w").close()
subprocess.run(["open", "-n", "--stdout", LOG, "--stderr", LOG, APP, "--args", "--fresh", "--bench", "--load-all", *[f"--open={u}" for u in SITES]])
for _ in range(40):
    pid = subprocess.run(["pgrep", "-f", "Debug/Feather.app/Contents/MacOS/Feather"], capture_output=True, text=True).stdout.split()
    if pid: pid = int(pid[0]); break
    time.sleep(0.5)
time.sleep(16)
subprocess.run(["osascript", "-e", f'tell application "System Events" to set frontmost of (first process whose unix id is {pid}) to true'])
time.sleep(1)
app = A.AXUIElementCreateApplication(pid)

def attr(e, n):
    err, v = A.AXUIElementCopyAttributeValue(e, n, None)
    return v if err == 0 else None

def frame(e):
    p, s = attr(e, "AXPosition"), attr(e, "AXSize")
    if p is None or s is None: return None
    _, pt = A.AXValueGetValue(p, A.kAXValueCGPointType, None); _, sz = A.AXValueGetValue(s, A.kAXValueCGSizeType, None)
    return (pt.x, pt.y, sz.width, sz.height)

def find(text, roles=("AXStaticText", "AXImage", "AXGroup", "AXButton"), maxd=16, frame_out=False):
    """Center of the first sidebar element whose title/description/help contains `text` (sidebar only: x < 400)."""
    hit = []
    def walk(e, d, wx):
        if hit: return
        label = " ".join(str(attr(e, n)) for n in ("AXTitle", "AXValue", "AXDescription", "AXHelp") if attr(e, n))
        f = frame(e)
        # sidebar = the leftmost 330 pt *of the window* (the window opens wherever macOS last placed it)
        if attr(e, "AXRole") in roles and text in label and f and wx <= f[0] < wx + 330 and f[2] > 4:
            hit.append(f if frame_out else (f[0] + f[2] / 2, f[1] + f[3] / 2)); return
        if d < maxd:
            for c in (attr(e, "AXChildren") or []): walk(c, d + 1, wx)
    for w in attr(app, "AXWindows") or []: walk(w, 0, frame(w)[0] if frame(w) else 0)
    return hit[0] if hit else None

def frontmost_pid():
    out = subprocess.run(["osascript", "-e", 'tell application "System Events" to get unix id of first process whose frontmost is true'], capture_output=True, text=True).stdout.strip()
    return int(out) if out.isdigit() else None

def post(kind, x, y):
    # Mouse presses go to whatever is under the cursor/in front: never send one unless the test copy is frontmost.
    if kind != Quartz.kCGEventMouseMoved and frontmost_pid() != pid:
        subprocess.run(["pkill", "-f", "Debug/Feather.app"])
        raise SystemExit(f"ABORT: the test copy (pid {pid}) is not the frontmost app; refusing to send input.")
    ev = Quartz.CGEventCreateMouseEvent(None, kind, (x, y), Quartz.kCGMouseButtonLeft)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)

def drag(src, dst, steps=24):
    post(Quartz.kCGEventMouseMoved, *src); time.sleep(0.2)
    post(Quartz.kCGEventLeftMouseDown, *src); time.sleep(0.15)
    for i in range(1, steps + 1):
        x = src[0] + (dst[0] - src[0]) * i / steps; y = src[1] + (dst[1] - src[1]) * i / steps
        post(Quartz.kCGEventLeftMouseDragged, x, y); time.sleep(0.02)
    time.sleep(0.4)
    post(Quartz.kCGEventLeftMouseUp, *dst); time.sleep(1.2)

def click(pt):
    post(Quartz.kCGEventMouseMoved, *pt); time.sleep(0.15)
    post(Quartz.kCGEventLeftMouseDown, *pt); time.sleep(0.08); post(Quartz.kCGEventLeftMouseUp, *pt); time.sleep(1.0)

def tabs():
    open(LOG, "w").close()
    subprocess.run(["kill", "-USR2", str(pid)]); time.sleep(1.5)
    out = []
    for line in open(LOG).read().splitlines():
        m = re.match(r"TAB (\d+) (\w+) (\S+) back=\S+ (\S+) \|.*pinned=(\w+)", line)
        if m:
            host = m.group(4).split("/")[2]
            out.append((next((v for k, v in KEY.items() if host.endswith(k)), host), m.group(5) == "true", m.group(3) == "selected"))
    return out

def names(t): return [("*" if p else "") + n for n, p, _ in t]

check("starts as [python, mozilla, apple, hn]", names(tabs()) == ["python", "mozilla", "apple", "hn"], names(tabs()))

# A. reorder: hacker news row dropped onto the python row
a, b = find("Hacker News"), find("Welcome to Python.org")
check("found the rows in the accessibility tree", a is not None and b is not None, (a, b))
drag(a, b)
t = tabs(); check("drag a tab onto another row reorders (hn before python)", names(t) == ["hn", "python", "mozilla", "apple"], names(t))

# B. pin by dragging onto the placeholder
src, zone = find("Apple"), find("Drag a tab here")
check("pin placeholder is visible when nothing is pinned", zone is not None)
check("found the Apple row to drag", src is not None, src)
if src and zone:
    drag(src, zone)
    t = tabs(); check("drag a tab onto the pin area pins it (first)", names(t) == ["*apple", "hn", "python", "mozilla"], names(t))

# C. second pin by dragging onto the pinned tiles (container) + unpin by dragging a tile onto the list
# The accessibility element named "Apple" is the whole pinned grid (220 pt wide); its first tile is 48x40 at the left edge.
grid = find("Apple", frame_out=True)
# Tiles are four equal flexible columns now: take the first tile's own width (found as a 40 pt-high button) when we got it,
# otherwise derive it from the 220 pt grid ((220 - 3 gaps of 6) / 4).
tw = grid[2] if grid and grid[2] < 100 else (220 - 18) / 4
tile = (grid[0] + tw / 2, grid[1] + 20) if grid else None
row = find("Welcome to Python.org")
if os.environ.get("DRAG_DEBUG"):
    print("   debug: tile at", tile, " row at", row)
    def dump(e, d=0):
        f = frame(e); label = " ".join(str(attr(e, n)) for n in ("AXTitle", "AXValue", "AXDescription", "AXHelp") if attr(e, n))
        if f and f[0] < 400 and f[1] < 400 and d > 1: print("   ", "  " * min(d, 8), attr(e, "AXRole"), repr(label[:40]), [round(x) for x in f])
        if d < 14:
            for c in (attr(e, "AXChildren") or []): dump(c, d + 1)
    for w in attr(app, "AXWindows") or []: dump(w)
check("found the pinned tile and a list row", tile is not None and row is not None, (tile, row))
if tile and row:
    drag(tile, row)
    t = tabs(); check("dragging a pinned tile onto the list unpins it", not any(p for _, p, _ in t) and names(t) != ["apple", "hn", "python", "mozilla"][:0], names(t))

# D. a plain click still selects (draggable must not swallow taps)
target = find("Mozilla")
check("found the Mozilla row to click", target is not None)
if target:
    click(target)
    t = tabs(); sel = [n for n, _, s in t if s]
    check("clicking a row still selects it", sel == ["mozilla"], sel)

# E. drop a list row onto an existing pinned tile (pins before it), F. reorder inside the pinned grid
py, zone = find("Welcome to Python.org"), find("Drag a tab here")
check("found python row and the pin placeholder", py is not None and zone is not None, (py, zone))
if py and zone:
    drag(py, zone)
    grid = find("Python", frame_out=True)
    hn = find("Hacker News")
    if grid and hn:
        tw = grid[2] if grid[2] < 100 else (220 - 18) / 4
        drag(hn, (grid[0] + tw / 2, grid[1] + 20))
        t = tabs(); check("dropping a row on a pinned tile pins it before that tile", names(t)[:2] == ["*hn", "*python"], names(t))
        grid = find("Hacker News", frame_out=True) or grid
        tw = grid[2] if grid[2] < 100 else (220 - 18) / 4
        drag((grid[0] + tw * 1.5 + 6, grid[1] + 20), (grid[0] + tw / 2, grid[1] + 20))
        t = tabs(); check("dragging one pinned tile onto another reorders the pinned tabs", names(t)[:2] == ["*python", "*hn"], names(t))
    else:
        check("found the pinned grid and the Hacker News row", False, (grid, hn))

print(f"\ndrag test: {passed} passed, {failed} failed")
if passed < 13: failed += 1; print("FAIL  fewer checks ran than expected (a step was skipped)")
subprocess.run(["pkill", "-f", "Debug/Feather.app"])
sys.exit(1 if failed else 0)
