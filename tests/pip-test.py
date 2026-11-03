#!/usr/bin/env python3
"""Picture in Picture, end to end: serves a small test video from two origins (so one page can embed a video from "another site"),
starts a Debug Feather with --pip-check, and requires a real floating window to appear for each case.

Needs ffmpeg (`brew install ffmpeg`) and a logged-in macOS GUI session; it takes over the front window and the mouse for about a minute (it clicks the floating window's buttons, so the terminal needs Accessibility permission, as for the other UI tests) and leaves your
real Feather alone (throwaway profile). Optional: PIP_REMOTE_URL=<https address of a video file> (default: an MDN sample); PIP_APP=<path to another build, e.g. a Release build compiled with
SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG so it contains the check>.

    python3 tests/pip-test.py
"""
import http.server, os, re, socketserver, subprocess, sys, tempfile, threading, time
import Quartz

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.environ.get("PIP_APP") or os.path.join(ROOT, "build/Build/Products/Debug/Feather.app")
REMOTE = os.environ.get("PIP_REMOTE_URL", "https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4")
P1, P2 = int(os.environ.get("FEATHER_TEST_PORT", "8777")), int(os.environ.get("FEATHER_TEST_PORT2", "8778"))

def serve(directory, port):
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **k): super().__init__(*a, directory=directory, **k)
        def log_message(self, *a): pass
    server = socketserver.ThreadingTCPServer(("127.0.0.1", port), Handler)
    server.allow_reuse_address = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server

def post(kind, x, y):
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, Quartz.CGEventCreateMouseEvent(None, kind, (x, y), Quartz.kCGMouseButtonLeft))

def click_button(button, fx, fy, w, h, screen_h):
    """Moves over the floating window (its buttons only appear on hover), then clicks the close (top left) or return-to-tab (top right) button.
    (fx, fy) is the window's lower-left corner in AppKit coordinates; mouse events use a top-left origin."""
    left, top = fx, screen_h - fy - h
    for dx, dy in [(w * 0.3, h * 0.6), (w * 0.5, h * 0.55), (w * 0.55, h * 0.5)]:
        post(Quartz.kCGEventMouseMoved, left + dx, top + dy); time.sleep(0.3)
    time.sleep(0.8)
    bx = left + (26 if button == "close" else w - 26)
    by = top + 26
    post(Quartz.kCGEventMouseMoved, bx, by); time.sleep(0.5)
    post(Quartz.kCGEventLeftMouseDown, bx, by); time.sleep(0.1)
    post(Quartz.kCGEventLeftMouseUp, bx, by)

def main():
    if subprocess.run(["which", "ffmpeg"], capture_output=True).returncode != 0:
        sys.exit("ffmpeg is needed to make the test video: brew install ffmpeg")
    if not os.path.isdir(APP):
        sys.exit("Build the Debug app first (see docs/DEVELOPMENT.md)")
    if subprocess.run(["pgrep", "-f", "build.*/Feather.app/Contents/MacOS/Feather"], capture_output=True).returncode == 0:
        sys.exit("A Debug Feather is already running; quit it first")
    tmp = tempfile.mkdtemp(prefix="feather-pip-")
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=320x180:rate=30", "-f", "lavfi", "-i", "sine=frequency=440",
                    "-t", "60", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart", os.path.join(tmp, "test.mp4")], check=True)
    page = '<!doctype html><body style="background:#222"><video src="test.mp4" controls playsinline loop width="320" height="180"></video></body>'
    open(os.path.join(tmp, "index.html"), "w").write(page)
    open(os.path.join(tmp, "inner.html"), "w").write(page)
    open(os.path.join(tmp, "outer.html"), "w").write(f'<!doctype html><body style="background:#222"><iframe src="http://localhost:{P2}/inner.html" width="340" height="200"></iframe></body>')
    servers = [serve(tmp, P1), serve(tmp, P2)]       # 127.0.0.1:P1 and localhost:P2 are different origins
    log = os.path.join(tmp, "out.log")
    try:
        subprocess.run(["open", "-n", "--stdout", log, "--stderr", log, APP, "--args", "--fresh", "--pip-check",
                        "--pip-clicks", f"--pip-main=http://127.0.0.1:{P1}/index.html", f"--pip-frame=http://127.0.0.1:{P1}/outer.html", f"--pip-remote={REMOTE}"], check=True)
        deadline = time.time() + 200
        clicked = set()
        while time.time() < deadline:
            time.sleep(0.5)
            text = open(log).read() if os.path.exists(log) else ""
            for m in re.finditer(r"\[pip\] CLICK (\w+) ([\d.]+) ([\d.]+) ([\d.]+) ([\d.]+) ([\d.]+)", text):
                if m.start() not in clicked:
                    clicked.add(m.start())
                    click_button(m.group(1), *[float(v) for v in m.groups()[1:]])
            if "ALL PASSED" in text or "FAILED" in text: break
        text = open(log).read() if os.path.exists(log) else ""
        print("\n".join(l for l in text.splitlines() if "[pip]" in l))
        ok = "ALL PASSED" in text
        print("PiP test:", "PASSED" if ok else "FAILED")
        sys.exit(0 if ok else 1)
    finally:
        subprocess.run(["pkill", "-f", "Feather.app.*--pip-check"])
        for s in servers: s.shutdown()

main()
