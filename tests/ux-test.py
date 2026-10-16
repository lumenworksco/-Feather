#!/usr/bin/env python3
"""End-to-end test with REAL keyboard and mouse events (Debug build, throwaway profile): shortcuts, typing in the address
bar, Escape, links that open new tabs, Cmd-click, zoom, find, pin, sidebar toggle. Moves the cursor and types: don't touch
the machine while it runs. Needs Accessibility permission for the terminal.
  tests/ux-test.py
"""
import os, re, subprocess, sys, time
import ApplicationServices as A, Quartz

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = f"{ROOT}/build/Build/Products/Debug/Feather.app"
LOG = "/private/tmp/feather-ux-test.log"
PORT = int(os.environ.get("FEATHER_TEST_PORT", 8765))
CMD, SHIFT, CTRL = Quartz.kCGEventFlagMaskCommand, Quartz.kCGEventFlagMaskShift, Quartz.kCGEventFlagMaskControl
K = dict(t=17, w=13, l=37, f=3, d=2, s=1, p=35, r=15, zero=29, equals=24, minus=27, one=18, two=19, tab=48, ret=36, esc=53, lb=33, rb=30)
passed = failed = 0

def check(name, ok, detail=""):
    global passed, failed
    passed, failed = (passed + 1, failed) if ok else (passed, failed + 1)
    print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else f"   ({detail})"), flush=True)

if not A.AXIsProcessTrusted(): sys.exit("Accessibility permission is missing for this terminal.")

srv = subprocess.Popen(["python3", "-m", "http.server", str(PORT), "--bind", "127.0.0.1"], cwd=f"{ROOT}/tests/restore", stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.run(["pkill", "-f", "Debug/Feather.app"]); time.sleep(1)
open(LOG, "w").close()
subprocess.run(["open", "-n", "--stdout", LOG, "--stderr", LOG, APP, "--args", "--fresh", "--bench", f"--open=http://localhost:{PORT}/popup.html"])
pid = None
for _ in range(40):
    out = subprocess.run(["pgrep", "-f", "Debug/Feather.app/Contents/MacOS/Feather"], capture_output=True, text=True).stdout.split()
    if out: pid = int(out[0]); break
    time.sleep(0.5)
time.sleep(10)
subprocess.run(["osascript", "-e", f'tell application "System Events" to set frontmost of (first process whose unix id is {pid}) to true']); time.sleep(1)
app = A.AXUIElementCreateApplication(pid)

def attr(e, n):
    err, v = A.AXUIElementCopyAttributeValue(e, n, None); return v if err == 0 else None
def frame(e):
    p, s = attr(e, "AXPosition"), attr(e, "AXSize")
    if p is None or s is None: return None
    _, pt = A.AXValueGetValue(p, A.kAXValueCGPointType, None); _, sz = A.AXValueGetValue(s, A.kAXValueCGSizeType, None)
    return (pt.x, pt.y, sz.width, sz.height)
def find(text, roles, sidebar=False, maxd=22):
    hit = []
    def walk(e, d, wx):
        if hit: return
        label = " ".join(str(attr(e, n)) for n in ("AXTitle", "AXValue", "AXDescription", "AXHelp") if attr(e, n))
        f = frame(e)
        if attr(e, "AXRole") in roles and text in label and f and f[2] > 2 and (not sidebar or wx <= f[0] < wx + 330):
            hit.append(f); return
        if d < maxd:
            for c in (attr(e, "AXChildren") or []): walk(c, d + 1, wx)
    for w in attr(app, "AXWindows") or []: walk(w, 0, frame(w)[0] if frame(w) else 0)
    return hit[0] if hit else None
def center(f): return (f[0] + f[2] / 2, f[1] + f[3] / 2)
def focused():
    e = attr(app, "AXFocusedUIElement")
    return (attr(e, "AXRole"), attr(e, "AXPlaceholderValue"), attr(e, "AXValue")) if e else (None, None, None)

def frontmost_pid():
    out = subprocess.run(["osascript", "-e", 'tell application "System Events" to get unix id of first process whose frontmost is true'], capture_output=True, text=True).stdout.strip()
    return int(out) if out.isdigit() else None
def require_front():
    # Events go to whatever app is in front. Never send one unless that is the test copy itself.
    if frontmost_pid() != pid:
        subprocess.run(["pkill", "-f", "Debug/Feather.app"]); srv.terminate()
        raise SystemExit(f"ABORT: the test copy (pid {pid}) is not the frontmost app (pid {frontmost_pid()}); refusing to send input.")

def press(code, flags=0, settle=0.35):
    require_front()
    for down in (True, False):
        ev = Quartz.CGEventCreateKeyboardEvent(None, code, down); Quartz.CGEventSetFlags(ev, flags)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev); time.sleep(0.03)
    time.sleep(settle)
ANSI = {c: k for k, c in enumerate("asdfhgzxcvbqweryt123465=97-80]ou[ip")}   # US-layout virtual key codes (index = code, with gaps below)
ANSI = dict(a=0, s=1, d=2, f=3, h=4, g=5, z=6, x=7, c=8, v=9, b=11, q=12, w=13, e=14, r=15, y=16, t=17, o=31, u=32, i=34, p=35,
            l=37, j=38, k=40, n=45, m=46)
ANSI.update({"1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, ".": 47, " ": 49, "-": 27})
def type_text(s):
    """Real key presses (virtual key codes), like typing; Unicode-override events are ignored by text fields."""
    require_front()
    for ch in s:
        code = ANSI[ch]
        for down in (True, False):
            ev = Quartz.CGEventCreateKeyboardEvent(None, code, down); Quartz.CGEventSetFlags(ev, 0)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev); time.sleep(0.015)
    time.sleep(0.3)
def mouse(kind, x, y, flags=0):
    if kind != Quartz.kCGEventMouseMoved: require_front()
    ev = Quartz.CGEventCreateMouseEvent(None, kind, (x, y), Quartz.kCGMouseButtonLeft); Quartz.CGEventSetFlags(ev, flags)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)
def click(pt, flags=0):
    mouse(Quartz.kCGEventMouseMoved, *pt); time.sleep(0.2)
    mouse(Quartz.kCGEventLeftMouseDown, *pt, flags); time.sleep(0.08); mouse(Quartz.kCGEventLeftMouseUp, *pt, flags); time.sleep(1.2)

def tabs():
    open(LOG, "w").close(); subprocess.run(["kill", "-USR2", str(pid)]); time.sleep(1.4)
    out = []
    for line in open(LOG).read().splitlines():
        m = re.match(r"TAB (\d+) (\w+) (\S+) back=\S+ (\S+) \| (.*) \| zoom=([\d.]+) \| pinned=(\w+)", line)
        if m: out.append(dict(i=int(m[1]), live=m[2] == "live", sel=m[3] == "selected", url=m[4], title=m[5], zoom=float(m[6]), pinned=m[7] == "true"))
    return out
def sel(t): return next((x["i"] for x in t if x["sel"]), None)

try:
    t = tabs(); check("starts with the page that has the test link", len(t) == 1 and "popup.html" in t[0]["url"], t)

    # --- new tab + typing in the address bar
    press(K["t"], CMD); t = tabs()
    check("Cmd+T opens a new tab and selects it", len(t) == 2 and sel(t) == 1, [x["url"] for x in t])
    role, ph, _ = focused()
    check("...and the address field has keyboard focus", role == "AXTextField" and ph == "Search or enter address", (role, ph))
    type_text("example.com")        # (this tab already had its settle time; the next test types with no pause at all)
    if os.environ.get("UX_DEBUG"): print("   debug: field holds", repr(focused()[2]), "| role", focused()[0], flush=True)
    press(K["ret"]); time.sleep(4); t = tabs()
    if os.environ.get("UX_DEBUG"): print("   debug: tabs after Return:", [(x["sel"], x["url"]) for x in t], flush=True)
    check("typing a domain and pressing Return loads it", "example.com" in t[1]["url"], t[1]["url"])
    # --- clicking the address bar selects its whole text; a second click places the caret
    def selection():
        e = attr(app, "AXFocusedUIElement"); r = attr(e, "AXSelectedTextRange") if e else None
        if r is None: return None
        ok, rng = A.AXValueGetValue(r, A.kAXValueCFRangeType, None); value = attr(e, "AXValue") or ""
        return (rng[1], len(value), attr(e, "AXPlaceholderValue"))
    field = find("example.com", ("AXTextField",), sidebar=True)
    if field is None: check("found the address field to click", False)
    else:
        press(K["one"], CMD); press(K["two"], CMD)                    # focus the page of tab 2 (address field not focused)
        click(center(field)); time.sleep(0.6); sel1 = selection()
        check("one click in the address bar selects all of its text", sel1 is not None and sel1[0] == sel1[1] and sel1[1] > 0 and sel1[2] == "Search or enter address", sel1)
        click(center(field)); time.sleep(0.4); sel2 = selection()
        check("a second click places the caret instead (no select-all again)", sel2 is not None and sel2[0] == 0, sel2)
        press(K["esc"])
    press(K["t"], CMD, settle=0); type_text("swift tutorial"); press(K["ret"]); time.sleep(4); t = tabs()
    check("typing right after Cmd+T (no pause) loses no letters: plain words search Google", "google.com/search?q=swift%20tutorial" in t[2]["url"], t[2]["url"])
    press(K["t"], CMD, settle=0); type_text("example.org"); press(K["ret"]); time.sleep(4); t = tabs()
    check("...and a domain typed with no pause after Cmd+T loads in full", "example.org" in t[3]["url"], t[3]["url"])
    press(K["w"], CMD)                                          # back to the 3-tab layout the rest of the test expects

    # --- close / reopen / tab switching
    press(K["w"], CMD); t = tabs(); check("Cmd+W closes the tab", len(t) == 2, len(t))
    press(K["t"], CMD | SHIFT); time.sleep(2); t = tabs(); check("Shift+Cmd+T reopens it", len(t) == 3 and "google.com/search" in t[2]["url"], [x["url"] for x in t])
    press(K["one"], CMD); t = tabs(); check("Cmd+1 selects the first tab", sel(t) == 0, sel(t))
    press(K["two"], CMD); t = tabs(); check("Cmd+2 selects the second tab", sel(t) == 1, sel(t))
    press(K["tab"], CTRL); t = tabs(); check("Ctrl+Tab goes to the next tab", sel(t) == 2, sel(t))
    press(K["lb"], CMD | SHIFT); t = tabs(); check("Shift+Cmd+[ goes to the previous tab", sel(t) == 1, sel(t))

    # --- address bar: Escape reverts what you typed
    press(K["l"], CMD); time.sleep(0.5); role, ph, _ = focused()
    check("Cmd+L focuses the address field", role == "AXTextField" and ph == "Search or enter address", (role, ph))
    type_text("zzz-not-sent"); press(K["esc"]); time.sleep(0.5); role2, ph2, val = focused()
    check("Escape leaves the address field without navigating", not (role2 == "AXTextField" and ph2 == "Search or enter address"), (role2, ph2))
    field = find("example.com", ("AXTextField",), sidebar=True)
    check("...and the typed text is discarded", field is not None and "zzz" not in str(attr(app, "AXFocusedUIElement")), field)

    # --- pin, zoom, find, sidebar
    press(K["p"], CMD | SHIFT); t = tabs(); check("Shift+Cmd+P pins the tab (it moves to the front)", t[0]["pinned"] and "example.com" in t[0]["url"], [(x["pinned"], x["url"]) for x in t])
    press(K["p"], CMD | SHIFT); t = tabs(); check("Shift+Cmd+P again unpins it", not any(x["pinned"] for x in t))
    s0 = sel(t)
    press(K["equals"], CMD); t = tabs(); check("Cmd+= zooms in", abs(next(x for x in t if x["sel"])["zoom"] - 1.1) < 0.02, next(x for x in t if x["sel"])["zoom"])
    press(K["zero"], CMD); t = tabs(); check("Cmd+0 resets the zoom", abs(next(x for x in t if x["sel"])["zoom"] - 1.0) < 0.02)
    if os.environ.get("UX_DEBUG"): print("   debug: before Cmd+F focus:", focused()[:2], "| tabs:", [(x["sel"], x["url"][-20:]) for x in tabs()], flush=True)
    press(K["f"], CMD); time.sleep(0.6); role, ph, _ = focused()
    if os.environ.get("UX_DEBUG"): print("   debug: after Cmd+F focus:", (role, ph), flush=True)
    check("Cmd+F opens find with its field focused", role == "AXTextField" and ph == "Find in page", (role, ph))
    type_text("example"); press(K["esc"]); time.sleep(0.6); role, ph, _ = focused()
    check("Escape closes the find bar", ph != "Find in page", (role, ph))
    press(K["s"], CMD); time.sleep(0.8)
    check("Cmd+S hides the sidebar", find("Drag a tab here", ("AXStaticText", "AXGroup", "AXImage"), sidebar=True) is None)
    press(K["s"], CMD); time.sleep(0.8)
    check("Cmd+S shows it again", find("Drag a tab here", ("AXStaticText", "AXGroup", "AXImage"), sidebar=True) is not None)

    # --- links that open new tabs
    press(K["two"], CMD); time.sleep(0.5); n0 = len(tabs())            # tab 2 is the page with the links (unpinning moved the example tab to the front)
    link = find("Open B", ("AXLink", "AXStaticText")); check("the page's link is visible to accessibility", link is not None)
    if os.environ.get("UX_DEBUG") and link is None:
        def dump(e, d=0):
            f = frame(e); label = " ".join(str(attr(e, n)) for n in ("AXTitle", "AXValue", "AXDescription") if attr(e, n))
            if d > 6 and attr(e, "AXRole") in ("AXLink", "AXStaticText", "AXWebArea"): print("   ", "  " * min(d, 10), attr(e, "AXRole"), repr(label[:40]), f and [round(x) for x in f], flush=True)
            if d < 22:
                for c in (attr(e, "AXChildren") or []): dump(c, d + 1)
        print("   debug: tabs now", [(x["sel"], x["url"]) for x in tabs()], flush=True)
        for w in attr(app, "AXWindows") or []: dump(w)
    if link:
        click(center(link)); time.sleep(2); t = tabs()
        check("clicking a target=_blank link opens a new tab and selects it", len(t) == n0 + 1 and "b.html" in next(x for x in t if x["sel"])["url"], [(x["sel"], x["url"][-12:]) for x in t])
        press(K["two"], CMD); time.sleep(0.5); n1 = len(tabs()); link = find("Open B", ("AXLink", "AXStaticText"))
        click(center(link), CMD); time.sleep(2); t = tabs()
        check("Cmd-clicking a link opens it in the background", len(t) == n1 + 1 and sel(t) == 1, (len(t), n1, sel(t)))
finally:
    print(f"\nux test: {passed} passed, {failed} failed")
    subprocess.run(["pkill", "-f", "Debug/Feather.app"]); srv.terminate()
sys.exit(1 if failed else 0)
