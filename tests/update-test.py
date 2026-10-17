#!/usr/bin/env python3
"""End-to-end test of self-updating, against a local fake release feed and a throwaway signing key.

Builds two Releases (0.1.2 and 0.1.3) that trust the test key, runs a COPY of the old one from /Applications/Feather-uptest.app with
a throwaway profile (your real Feather and its tabs are never touched), lets it update itself, and checks: the swap, the relaunch, the
tabs, no quarantine, the profile lock, and that a tampered download or a wrongly signed release is refused.

  python3 tests/update-test.py        (takes a few minutes: two Release builds)
Needs: pip install cryptography. Refuses to run if /Applications/Feather-uptest.app already exists.
"""
import base64, json, os, plistlib, shutil, subprocess, sys, tempfile, threading, time, zipfile
from http.server import HTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization as ser

ROOT = Path(__file__).resolve().parent.parent
COPY = Path("/Applications/Feather-uptest.app")
HOME = Path.home()
PROFILE_DIR = HOME / "Library/Containers/dev.feather.Feather/Data/tmp/FeatherProfile-updtest"
EXCHANGE = HOME / "Library/Caches/dev.feather.updater"
passed = failed = 0
def check(name, ok, detail=""):
    global passed, failed
    ok = bool(ok)
    passed += ok; failed += (not ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name} {'' if ok else '(' + str(detail) + ')'}", flush=True)
def sh(*a, **k): return subprocess.run(a, capture_output=True, text=True, **k)
def pids(path): return [p for p in sh("pgrep", "-f", f"{path}/Contents/MacOS/Feather").stdout.split()]
def version(app): return plistlib.load(open(f"{app}/Contents/Info.plist", "rb"))["CFBundleShortVersionString"]
def session_urls():
    try: return [t.get("url") for t in json.load(open(PROFILE_DIR / "session.json"))["tabs"]]
    except Exception: return None
def wait(cond, secs, step=0.5):
    end = time.time() + secs
    while time.time() < end:
        if cond(): return True
        time.sleep(step)
    return False

if COPY.exists(): sys.exit(f"{COPY} already exists; remove it first.")
if os.path.isdir(EXCHANGE) and any(n.startswith(("update-", "Feather-")) for n in os.listdir(EXCHANGE)): shutil.rmtree(EXCHANGE)
# The two builds (and the throwaway key they trust) are kept in build-test/ (git-ignored) and reused; pass --rebuild to redo them.
work = ROOT / "build-test"
if "--rebuild" in sys.argv: shutil.rmtree(work, ignore_errors=True)
work.mkdir(exist_ok=True)
if not (work / "key.b64").exists():
    k = Ed25519PrivateKey.generate()
    (work / "key.b64").write_text(base64.b64encode(k.private_bytes(ser.Encoding.Raw, ser.PrivateFormat.Raw, ser.NoEncryption())).decode()); os.chmod(work / "key.b64", 0o600)
key = Ed25519PrivateKey.from_private_bytes(base64.b64decode((work / "key.b64").read_text()))
other = Ed25519PrivateKey.generate()
pub = base64.b64encode(key.public_key().public_bytes(ser.Encoding.Raw, ser.PublicFormat.Raw)).decode()

def build(tag, version_, build_):
    out = work / f"build-{tag}"
    cached = out / "Build/Products/Release/Feather.app"
    if cached.exists(): return cached
    r = sh("xcodebuild", "-project", str(ROOT / "Feather.xcodeproj"), "-scheme", "Feather", "-configuration", "Release", "-derivedDataPath", str(out), "build",
           f"MARKETING_VERSION={version_}", f"CURRENT_PROJECT_VERSION={build_}", f"UPDATE_PUBLIC_KEY={pub}")
    app = out / "Build/Products/Release/Feather.app"
    if not app.exists(): sys.exit("build failed:\n" + r.stdout[-1500:])
    return app

print("building 0.1.2 and 0.1.3 with the test key...", flush=True)
old_app, new_app = build("old", "0.1.2", 4), build("new", "0.1.3", 5)
site = work / "site"; shutil.rmtree(site, ignore_errors=True); site.mkdir()
zip_path = site / "Feather-0.1.3-alpha.zip"
sh("ditto", "-c", "-k", "--keepParent", "--norsrc", "--noextattr", "--noqtn", "--noacl", str(new_app), str(zip_path))
env = dict(os.environ, FEATHER_UPDATE_KEY_FILE=str(work / "key.b64"))
subprocess.run([sys.executable, str(ROOT / "tools/make-update.py"), str(zip_path), str(site)], env=env, check=True, capture_output=True)

class Quiet(SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
os.chdir(site)
httpd = HTTPServer(("127.0.0.1", 0), Quiet); port = httpd.server_address[1]
threading.Thread(target=httpd.serve_forever, daemon=True).start()
def write_feed(assets):
    (site / "latest.json").write_text(json.dumps({"assets": [{"name": n, "browser_download_url": f"http://127.0.0.1:{port}/{n}"} for n in assets]}))
write_feed(["update.json", "update.json.sig", zip_path.name])
FEED = f"--update-feed=http://127.0.0.1:{port}/latest.json"
(site / "index.html").write_text("<title>tab one</title>one"); (site / "two.html").write_text("<title>tab two</title>two"); (site / "three.html").write_text("<title>tab three</title>three")

def start(extra=()):
    return subprocess.run(["open", "-n", str(COPY), "--args", "--profile=updtest", *extra])
def stop():
    for p in pids(COPY): subprocess.run(["kill", "-9", p])
    time.sleep(1.5)
def log_lines(since=None):
    return sh("/usr/bin/log", "show", "--last", "45s", "--info", "--style", "compact", "--predicate", 'subsystem == "dev.feather" AND category == "updates"').stdout

try:
    shutil.rmtree(PROFILE_DIR, ignore_errors=True)
    sh("ditto", "--noqtn", str(old_app), str(COPY))
    check("test copy installed (0.1.2)", version(COPY) == "0.1.2", version(COPY))
    # Make a session with three tabs.
    tabs = [f"http://127.0.0.1:{port}/{n}" for n in ("index.html", "two.html", "three.html")]
    start([f"--open={u}" for u in tabs]); wait(lambda: session_urls() and len([u for u in session_urls() if u]) >= 3, 25)
    time.sleep(2); stop()
    before = session_urls()
    check("three tabs saved before updating", before is not None and len([u for u in before if u]) == 3, before)

    # --- Negative 1: wrongly signed release is ignored.
    shutil.copy(site / "update.json.sig", work / "good.sig")
    bad = base64.b64encode(other.sign((site / "update.json").read_bytes())).decode() + "\n"
    (site / "update.json.sig").write_text(bad)
    t0 = time.strftime("%Y-%m-%d %H:%M:%S")
    start([FEED, "--update-auto-install"]); time.sleep(14)
    check("wrongly signed release: nothing installed", version(COPY) == "0.1.2" and pids(COPY), version(COPY))
    check("wrongly signed release: app said why", "invalid signature" in log_lines(t0), log_lines(t0)[-300:])
    stop(); shutil.copy(work / "good.sig", site / "update.json.sig")

    # --- Negative 2: the zip is altered after signing (same size, different bytes).
    orig = zip_path.read_bytes(); altered = bytearray(orig); altered[len(altered) // 2] ^= 0xFF; zip_path.write_bytes(bytes(altered))
    t0 = time.strftime("%Y-%m-%d %H:%M:%S")
    start([FEED, "--update-auto-install"])
    refused = wait(lambda: "download rejected" in log_lines(), 60, step=2)      # wait for the app's own verdict, not a fixed time
    check("tampered zip: the app rejected the download (checksum differs from the signed one)", refused, log_lines()[-400:])
    check("tampered zip: nothing installed, app still the old version and running", version(COPY) == "0.1.2" and pids(COPY), version(COPY))
    check("tampered zip: nothing left behind for the installer", not any(n.endswith(".zip") for n in (os.listdir(EXCHANGE) if EXCHANGE.exists() else [])))
    stop(); zip_path.write_bytes(orig)

    # --- Negative 3 (helper alone): even if the app were fooled, the helper re-checks and refuses a tampered zip.
    EXCHANGE.mkdir(parents=True, exist_ok=True)
    shutil.copy(site / "update.json", EXCHANGE / "update.json"); shutil.copy(site / "update.json.sig", EXCHANGE / "update.json.sig"); (EXCHANGE / zip_path.name).write_bytes(bytes(altered))
    (EXCHANGE / "update-request.json").write_text(json.dumps({"manifest": "update.json", "signature": "update.json.sig", "zip": zip_path.name, "target": str(COPY), "pid": 0, "relaunchArguments": ["--profile=updtest"]}))
    subprocess.run(["open", "-n", str(old_app / "Contents/Library/FeatherUpdater.app")])
    wait(lambda: (EXCHANGE / "update-status.json").exists(), 45)           # a never-seen app can take a while to start (macOS scans it)
    status = json.load(open(EXCHANGE / "update-status.json")) if (EXCHANGE / "update-status.json").exists() else {}
    check("helper alone refuses a tampered zip and leaves the app alone", status.get("ok") is False and "damaged" in status.get("message", "") and version(COPY) == "0.1.2", status)
    shutil.rmtree(EXCHANGE, ignore_errors=True)

    # --- Checks must not depend on a timer alone: coming back to the app (after it was in the background) must start one too.
    write_feed([])                                                          # a release list with nothing in it: no update, so nothing installs
    start([FEED]); time.sleep(8)
    p0 = pids(COPY)[0]
    def front(pid): sh("osascript", "-e", f'tell application "System Events" to set frontmost of (first process whose unix id is {pid}) to true')
    sh("osascript", "-e", 'tell application "Finder" to activate'); time.sleep(2)
    front(p0); ok = wait(lambda: "automatic check (app became active)" in log_lines(), 30, step=2)
    check("coming back to the app starts an update check (not only the timer)", ok, log_lines()[-400:])
    stop(); write_feed(["update.json", "update.json.sig", zip_path.name])

    # --- The real thing.
    t0 = time.strftime("%Y-%m-%d %H:%M:%S")
    old_pids = start([FEED, "--update-auto-install"])
    ok = wait(lambda: version(COPY) == "0.1.3", 60)
    check("the app updated itself to 0.1.3", ok, version(COPY))
    ok = wait(lambda: len(pids(COPY)) > 0 and "--after-update" in sh("ps", "-o", "command=", "-p", pids(COPY)[0]).stdout, 40)
    check("the new version was started by the installer (--after-update, same profile)", ok, sh("ps", "-axo", "command").stdout[-200:])
    time.sleep(6)
    after = session_urls()
    check("the same three tabs came back", after == before, (before, after))
    q = sh("xattr", "-r", str(COPY)).stdout
    check("the installed app carries no quarantine mark", "com.apple.quarantine" not in q, q[:200])
    check("signature of the installed app is valid", sh("codesign", "--verify", "--strict", "--deep", str(COPY)).returncode == 0)
    holder = sh("lsof", "-t", str(PROFILE_DIR / "profile.lock")).stdout.split()
    check("the new instance owns the profile (not read-only)", holder and holder[0] in pids(COPY), (holder, pids(COPY)))
    check("the new version picked up the installer's note at launch (it deletes it once read)", not (EXCHANGE / "update-status.json").exists())
    log = (EXCHANGE / "updater.log").read_text() if (EXCHANGE / "updater.log").exists() else ""
    check("the installer reported success", "OK: Updated Feather from 0.1.2 to 0.1.3" in log, log[-300:])
    check("the update's download files were cleaned up", not any(n.startswith(("Feather-", "update.json")) for n in os.listdir(EXCHANGE)), os.listdir(EXCHANGE))
    check("no leftovers in /Applications (the old version is in the Trash under a visible name)", not [n for n in os.listdir("/Applications") if "replaced" in n],)
    check("hidden leftovers in /Applications were removed", not [n for n in os.listdir("/Applications") if n.startswith((".Feather-update-", ".Feather-old-"))])
    stop()
finally:
    stop(); httpd.shutdown()
    shutil.rmtree(COPY, ignore_errors=True); shutil.rmtree(PROFILE_DIR, ignore_errors=True)
print(f"update test: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
