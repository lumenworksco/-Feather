#!/usr/bin/env python3
"""Favicons persist across a relaunch (Debug build, throwaway profile; sends no input, so it is safe to run any time).
Opens two pages on different hosts (localhost, 127.0.0.1) with different icons, quits, relaunches WITHOUT loading them,
and checks that the tab that was never loaded this time still shows its icon.
  tests/favicon-test.py
"""
import os, re, shutil, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "build/Build/Products/Debug/Feather.app"
DIR = Path.home() / "Library/Containers/dev.feather.Feather/Data/tmp/FeatherProfile-favtest"
passed = failed = 0
def check(name, ok, detail=""):
    global passed, failed
    passed, failed = (passed + 1, failed) if ok else (passed, failed + 1)
    print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else f"   ({detail})"), flush=True)

def pids(): return set(subprocess.run(["pgrep", "-f", "Debug/Feather.app/Contents/MacOS/Feather"], capture_output=True, text=True).stdout.split())
def launch(*args):
    log = f"/private/tmp/feather-fav-{time.time_ns()}.log"; open(log, "w").close(); before = pids()
    subprocess.run(["open", "-n", "--stdout", log, "--stderr", log, str(APP), "--args", "--profile=favtest", "--bench", *args])
    pid = None
    for _ in range(60):
        new = pids() - before
        if new: pid = int(sorted(new)[0]); break
        time.sleep(0.25)
    for _ in range(60):
        if "SESSION source=" in open(log, errors="replace").read(): break
        time.sleep(0.2)
    return pid, log
def dump(pid, log):
    subprocess.run(["kill", "-USR2", str(pid)]); time.sleep(1.5)
    out = []
    for line in open(log, errors="replace").read().splitlines():
        m = re.match(r"TAB (\d+) (\w+) \S+ back=\S+ (\S+) \|.*icon=(\w+)", line)
        if m: out.append((m[3], m[2], m[4] == "true"))
    return out

shutil.rmtree(DIR, ignore_errors=True)
subprocess.run(["pkill", "-9", "-f", "Debug/Feather.app/Contents/MacOS/Feather"]); time.sleep(1)
PORT = int(os.environ.get("FEATHER_TEST_PORT", 8765))
srv = subprocess.Popen(["python3", "-m", "http.server", str(PORT), "--bind", "0.0.0.0"], cwd=ROOT / "tests/restore", stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)
try:
    A, B = f"http://localhost:{PORT}/icon-a.html", f"http://127.0.0.1:{PORT}/icon-b.html"
    print("== first run: load both pages so their icons get fetched and saved")
    pid, log = launch("--load-all", f"--open={A}", f"--open={B}"); time.sleep(8)
    first = dump(pid, log)
    check("both pages loaded and show their icons", len(first) == 2 and all(i for _, _, i in first), first)
    subprocess.run(["kill", "-9", str(pid)]); time.sleep(1)
    files = sorted((DIR / "Favicons").glob("*.png")) if (DIR / "Favicons").exists() else []
    check("an icon file was saved for each site", [f.name for f in files] == ["127.0.0.1.png", "localhost.png"], [f.name for f in files])
    sizes = [f.stat().st_size for f in files]
    print(f"   sizes on disk: {sizes} bytes ({sum(sizes)} total for {len(sizes)} sites)")

    print("== second run: relaunch WITHOUT loading anything; only the selected tab loads")
    pid, log = launch(); time.sleep(5)
    second = dump(pid, log)
    unloaded = [t for t in second if t[1] == "unloaded"]
    check("one tab is unloaded (never loaded in this run)", len(unloaded) == 1, second)
    check("...and it still shows its site icon, straight after the relaunch", len(unloaded) == 1 and unloaded[0][2], second)
    check("every restored tab has an icon", all(i for _, _, i in second), second)
    subprocess.run(["kill", "-9", str(pid)])
finally:
    srv.terminate(); subprocess.run(["pkill", "-9", "-f", "Debug/Feather.app/Contents/MacOS/Feather"]); shutil.rmtree(DIR, ignore_errors=True)
print(f"\nfavicon test: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
