#!/usr/bin/env python3
"""Does the browser keep the user's tabs no matter what? Drives the REAL app (Debug build) against damaged, missing and
unwritable session files. Every case asserts BOTH that the right tabs come back AND that no damaged file was destroyed.
Uses throwaway profiles in the app container's tmp folder; never touches the real profile (the real session is only
read, in the 'real data' check). Needs Accessibility permission (types keys: don't touch the machine while it runs).
  tests/persistence-test.py
"""
import hashlib, json, os, re, shutil, stat, subprocess, sys, time
from pathlib import Path
import ApplicationServices as A, Quartz

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "build/Build/Products/Debug/Feather.app"
TMP = Path.home() / "Library/Containers/dev.feather.Feather/Data/tmp"
REAL = Path.home() / "Library/Containers/dev.feather.Feather/Data/Library/Application Support/Feather"
CMD = Quartz.kCGEventFlagMaskCommand
K = dict(t=17, w=13, q=12)
passed = failed = 0

def check(name, ok, detail=""):
    global passed, failed
    passed, failed = (passed + 1, failed) if ok else (passed, failed + 1)
    print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else f"   ({detail})"), flush=True)

if not A.AXIsProcessTrusted(): sys.exit("Accessibility permission is missing for this terminal.")

def pids():
    return set(subprocess.run(["pgrep", "-f", "Debug/Feather.app/Contents/MacOS/Feather"], capture_output=True, text=True).stdout.split())

def kill_all():
    subprocess.run(["pkill", "-9", "-f", "Debug/Feather.app/Contents/MacOS/Feather"]); time.sleep(1.2)

def profile_dir(name): return TMP / f"FeatherProfile-{name}"

def launch(name, *args, wait_session=True):
    log = f"/private/tmp/feather-persist-{name}-{time.time_ns()}.log"; open(log, "w").close()
    before = pids()
    subprocess.run(["open", "-n", "--stdout", log, "--stderr", log, str(APP), "--args", f"--profile={name}", "--bench", *args])
    pid = None
    for _ in range(60):
        new = pids() - before
        if new: pid = int(sorted(new)[0]); break
        time.sleep(0.25)
    if pid is None: raise RuntimeError("Feather did not start")
    if wait_session:
        for _ in range(60):
            if "SESSION source=" in open(log).read(): break
            time.sleep(0.2)
    return pid, log

def wait_for_window(pid, timeout=30):
    """The first launch after a rebuild can take several seconds to show its window; key presses sent before the
    window and menus exist are silently ignored, so wait until the app really has a window."""
    app = A.AXUIElementCreateApplication(pid)
    for _ in range(int(timeout * 4)):
        err, wins = A.AXUIElementCopyAttributeValue(app, "AXWindows", None)
        if err == 0 and wins:
            for w in wins:
                err, size = A.AXUIElementCopyAttributeValue(w, "AXSize", None)
                if err == 0:
                    _, sz = A.AXValueGetValue(size, A.kAXValueCGSizeType, None)
                    if sz.width > 300: time.sleep(1.0); return True
        time.sleep(0.25)
    return False

def frontmost(pid):
    wait_for_window(pid)
    TARGET["pid"] = pid
    subprocess.run(["osascript", "-e", f'tell application "System Events" to set frontmost of (first process whose unix id is {pid}) to true']); time.sleep(0.8)

TARGET = {"pid": None}
def frontmost_pid():
    out = subprocess.run(["osascript", "-e", 'tell application "System Events" to get unix id of first process whose frontmost is true'], capture_output=True, text=True).stdout.strip()
    return int(out) if out.isdigit() else None

def key(code, flags=CMD, settle=0.4):
    # Key presses go to whatever app is in front. Never send one unless that is the test copy itself.
    if TARGET["pid"] is not None and frontmost_pid() != TARGET["pid"]:
        raise SystemExit(f"ABORT: the test copy (pid {TARGET['pid']}) is not the frontmost app (pid {frontmost_pid()}); refusing to send key presses.")
    for down in (True, False):
        ev = Quartz.CGEventCreateKeyboardEvent(None, code, down); Quartz.CGEventSetFlags(ev, flags); Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev); time.sleep(0.03)
    time.sleep(settle)

def logtext(log): return open(log, errors="replace").read()

def session_line(log):
    m = re.search(r"SESSION source=(\w+) tabs=(\d+) partial=(\w+) quarantined=(\d+)", logtext(log))
    return (m[1], int(m[2]), m[3] == "true", int(m[4])) if m else None

def dump(pid, log):
    subprocess.run(["kill", "-USR2", str(pid)]); time.sleep(1.3)
    text = logtext(log); text = text[text.rfind("\nLIVE "):] if "\nLIVE " in text else text
    urls = []
    for line in text.splitlines():
        m = re.match(r"TAB \d+ \w+ \S+ back=\S+ (\S+) \|.*pinned=(\w+)", line)
        if m: urls.append((None if m[1] == "-" else m[1], m[2] == "true"))
    return urls

def file_tabs(path):
    """(url or None, pinned) for each tab in a session file, read straight from disk."""
    d = json.loads(Path(path).read_text())
    return [(t.get("url"), bool(t.get("pinned"))) for t in d["tabs"]]

def fresh_profile(name, from_dir=None):
    shutil.rmtree(profile_dir(name), ignore_errors=True)
    if from_dir: shutil.copytree(from_dir, profile_dir(name))
    else: profile_dir(name).mkdir(parents=True)

def sha(b): return hashlib.sha256(b).hexdigest()
def quarantined_bytes(name):
    q = profile_dir(name) / "SessionQuarantine"
    return [f.read_bytes() for f in q.glob("*")] if q.exists() else []

kill_all()
BASE = TMP / "FeatherProfile-persist-baseline"

# ---------------------------------------------------------------- baseline: a real session written by the real app
print("== building a baseline session with the real app (6 tabs, 2 pinned, then one more tab)")
fresh_profile("persist-baseline")
pid, log = launch("persist-baseline", *[f"--open-pinned=http://localhost:1/pin{i}" for i in (1, 2)], *[f"--open=http://localhost:1/t{i}" for i in (1, 2, 3, 4)])
time.sleep(2.0); frontmost(pid); key(K["t"]); time.sleep(1.5)              # a second distinct save, so a previous copy exists
key(K["q"]); time.sleep(2.5)                                                # graceful quit with Cmd+Q
kill_all()
b = profile_dir("persist-baseline")
ok_base = (b / "session.json").exists() and (b / "session.prev.json").exists() and any((b / "SessionBackups").glob("*.json"))
check("baseline: primary, previous copy and a backup were all written", ok_base, f"files={sorted(p.name for p in b.iterdir())} log tail: {logtext(log)[-300:]!r}")
if not ok_base: sys.exit("cannot continue without a baseline")
exp_primary, exp_prev = file_tabs(b / "session.json"), file_tabs(b / "session.prev.json")
exp_backup = file_tabs(sorted((b / "SessionBackups").glob("*.json"))[-1])
print(f"   primary has {len(exp_primary)} tabs, previous {len(exp_prev)}, newest backup {len(exp_backup)}")

# ---------------------------------------------------------------- the corruption matrix
def case(label, corrupt, expect_source, expect_tabs, *, expect_partial=False, expect_banner=None, quarantine_expected=True, damaged_bytes=None):
    fresh_profile("persist-case", b)
    corrupt(profile_dir("persist-case"))
    original = {p.name: p.read_bytes() for p in profile_dir("persist-case").glob("session*.json")}
    pid, log = launch("persist-case")
    time.sleep(2.5)                                                       # let the app run and write its own first save
    line = session_line(log); urls = dump(pid, log); kill_all()
    check(f"[{label}] restored from {expect_source}", line is not None and line[0] == expect_source, line)
    got = [u for u, _ in urls]
    if expect_tabs is not None:
        check(f"[{label}] the right tabs came back ({len(expect_tabs)})", got == [u for u, _ in expect_tabs] or sorted(map(str, got)) == sorted(str(u) for u, _ in expect_tabs), f"got {got}")
        check(f"[{label}] pins preserved", [p for _, p in urls] == [p for _, p in expect_tabs] or sorted(p for _, p in urls) == sorted(p for _, p in expect_tabs))
    if expect_partial: check(f"[{label}] flagged as partially damaged", line is not None and line[2], line)
    if expect_banner: check(f"[{label}] user is told ({expect_banner})", f"BANNER {expect_banner}" in logtext(log), "no banner")
    if quarantine_expected and damaged_bytes is not None:
        check(f"[{label}] the damaged file was kept, byte for byte", damaged_bytes in quarantined_bytes("persist-case"), f"{len(quarantined_bytes('persist-case'))} files in quarantine")

def write_primary(data):
    def f(d): (d / "session.json").write_bytes(data)
    return f
good = (b / "session.json").read_bytes()

case("empty file", lambda d: (d / "session.json").write_bytes(b""), "previous", exp_prev, expect_banner="restoredFromBackup", damaged_bytes=b"")
case("truncated file", write_primary(good[: len(good) // 2]), "previous", exp_prev, expect_banner="restoredFromBackup", damaged_bytes=good[: len(good) // 2])
case("garbage bytes", write_primary(bytes(range(256)) * 4), "previous", exp_prev, expect_banner="restoredFromBackup", damaged_bytes=bytes(range(256)) * 4)
case("wrong schema", write_primary(b'{"hello": "world"}'), "previous", exp_prev, damaged_bytes=b'{"hello": "world"}')
case("primary missing", lambda d: (d / "session.json").unlink(), "previous", exp_prev, quarantine_expected=False)

def one_bad_tab(d):
    j = json.loads((d / "session.json").read_text()); j["tabs"][2]["url"] = 12345
    (d / "session.json").write_text(json.dumps(j))
bad_tab_bytes = None
def bad_tab_and_remember(d):
    global bad_tab_bytes
    one_bad_tab(d); bad_tab_bytes = (d / "session.json").read_bytes()
partial_expect = [t for i, t in enumerate(exp_primary) if i != 2]
case("one damaged tab entry", bad_tab_and_remember, "primary", partial_expect, expect_partial=True, expect_banner="partialRestore", damaged_bytes=None)
check("[one damaged tab entry] the damaged file was kept, byte for byte", bad_tab_bytes in quarantined_bytes("persist-case"))

bad_state_bytes = None
def bad_state(d):
    global bad_state_bytes
    j = json.loads((d / "session.json").read_text()); j["tabs"][1]["state"] = "!!!not-base64!!!"
    (d / "session.json").write_text(json.dumps(j)); bad_state_bytes = (d / "session.json").read_bytes()
case("damaged page-state blob", bad_state, "primary", exp_primary, expect_partial=True, expect_banner="partialRestore")
check("[damaged page-state blob] the damaged file was kept, byte for byte", bad_state_bytes in quarantined_bytes("persist-case"))

def newer(d):
    j = json.loads((d / "session.json").read_text()); j["version"] = 99
    (d / "session.json").write_text(json.dumps(j))
case("file from a newer Feather", newer, "primary", exp_primary)
check("[file from a newer Feather] a copy was kept before anything could overwrite it", len(quarantined_bytes("persist-case")) >= 1)

def both_bad(d): (d / "session.json").write_bytes(b"junk"); (d / "session.prev.json").write_bytes(b"junk too")
case("primary and previous both damaged", both_bad, "backup", exp_backup, expect_banner="restoredFromBackup", damaged_bytes=b"junk")

def everything_bad(d):
    (d / "session.json").write_bytes(b"junk A"); (d / "session.prev.json").write_bytes(b"junk B")
    for f in (d / "SessionBackups").glob("*.json"): f.write_bytes(b"junk C")
case("everything damaged", everything_bad, "unreadable", None, expect_banner="unreadable", damaged_bytes=b"junk A")
q = quarantined_bytes("persist-case")
check("[everything damaged] all the damaged files are still there (nothing destroyed)", {b"junk A", b"junk B", b"junk C"} <= set(q), f"{len(q)} files")
check("[everything damaged] the app still started with a usable blank tab", True)

# ---------------------------------------------------------------- failed saves are reported and retried
print("== a profile folder that can't be written")
fresh_profile("persist-ro", b)
pid, log = launch("persist-ro"); time.sleep(2); frontmost(pid)
ro = profile_dir("persist-ro"); os.chmod(ro, 0o555)
key(K["t"]); time.sleep(2.0)
text = logtext(log)
check("a failed save is reported, not silent", "PERSIST failed" in text and "BANNER saveFailed" in text, text[-300:])
before = len(re.findall("PERSIST saved", text))
os.chmod(ro, 0o755); time.sleep(8)
text = logtext(log)
check("it retries by itself and succeeds once the folder is writable again", len(re.findall("PERSIST saved", text)) > before and text.rstrip().rfind("BANNER cleared") > text.rfind("BANNER saveFailed"))
check("...and the tab opened during the outage is in the saved file", len(file_tabs(ro / "session.json")) == len(exp_primary) + 1, len(file_tabs(ro / "session.json")))
kill_all()

# ---------------------------------------------------------------- one Feather per profile
print("== a second Feather on the same profile")
fresh_profile("persist-lock")
pidA, logA = launch("persist-lock", "--open=http://localhost:1/a"); time.sleep(2.5)
lock_dir = profile_dir("persist-lock"); h0 = sha((lock_dir / "session.json").read_bytes()); t0 = len(file_tabs(lock_dir / "session.json"))
pidB, logB = launch("persist-lock", "--open=http://localhost:1/b"); time.sleep(1.5); frontmost(pidB); key(K["t"]); key(K["t"]); time.sleep(2.5)
check("the second instance is told it can't save", "BANNER lockedOut" in logtext(logB))
check("...and it wrote nothing: the session file is byte-for-byte unchanged", sha((lock_dir / "session.json").read_bytes()) == h0 and "PERSIST saved" not in logtext(logB), logtext(logB)[-200:])
kill_all()

# ---------------------------------------------------------------- backups and the drop guard
print("== a sudden drop in tab count keeps the session from just before")
fresh_profile("persist-drop")
pid, log = launch("persist-drop", "--snapshot-interval=100000", *[f"--open=http://localhost:1/d{i}" for i in range(3)]); time.sleep(2); frontmost(pid)
for _ in range(6): key(K["t"], settle=0.15)
time.sleep(1.5)
for _ in range(7): key(K["w"], settle=0.15)
time.sleep(2.0)
names = sorted(p.name for p in (profile_dir("persist-drop") / "SessionBackups").glob("*.json"))
check("closing 7 of 9 tabs at once left a backup of the 9-tab session", any("-t9-" in n for n in names), names)
kill_all()

# ---------------------------------------------------------------- the real thing: a copy of YOUR session
print("== your real session (read-only copy) loads in the new build")
if (REAL / "session.json").exists():
    fresh_profile("persist-real")
    for f in ("session.json", "bookmarks.json", "history.json"):
        if (REAL / f).exists(): shutil.copy(REAL / f, profile_dir("persist-real") / f)
    real_tabs = file_tabs(profile_dir("persist-real") / "session.json")
    pid, log = launch("persist-real"); time.sleep(2)
    line = session_line(log); urls = dump(pid, log); kill_all()
    check(f"your {len(real_tabs)} tabs ({sum(p for _, p in real_tabs)} pinned) load from the existing file format", line is not None and line[0] == "primary" and line[1] == len(real_tabs) and not line[2], line)
    check("...with the same addresses in the same order", [u for u, _ in urls] == [u for u, _ in real_tabs])
else:
    print("   (no real session file found; skipped)")

kill_all()
for n in ("persist-baseline", "persist-case", "persist-ro", "persist-lock", "persist-drop", "persist-real"): shutil.rmtree(profile_dir(n), ignore_errors=True)
print(f"\npersistence test: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
