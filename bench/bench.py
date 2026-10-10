#!/usr/bin/env python3
"""Repeatable memory/CPU benchmark for Feather and Safari. See BENCHMARKING.md.

  bench/bench.py --browser feather --runs 3
  bench/bench.py --browser safari  --runs 3        # reopens/modifies Safari's session; read BENCHMARKING.md first
  bench/bench.py --summarize bench/results/<file>.json

Memory = `footprint` phys_footprint (the number Activity Monitor shows as "Memory"), summed per group:
  app process, WebContent processes, Networking, GPU, other helpers.
Helpers are attributed by PID diff: any WebKit/Safari process that did not exist before the browser launched.
That is only valid if nothing else on the Mac starts WebKit processes during the run.
CPU = (sum of CPU-seconds used by all attributed processes over a window) / window, in % of one core.
"""
import argparse, datetime, json, os, platform, re, statistics, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FEATHER_APP = ROOT / "build/Build/Products/Release/Feather.app"
SITES = [  # ordinary, mostly static, stable pages; identical for both browsers
    "https://www.google.com/search?q=feather",
    "https://en.wikipedia.org/wiki/Feather",
    "https://news.ycombinator.com",
    "https://www.apple.com",
    "https://github.com/apple/swift",
    "https://www.bbc.com/news",
    "https://en.wikipedia.org/wiki/Web_browser",
    "https://developer.mozilla.org/en-US/docs/Web/JavaScript",
    "https://www.nasa.gov",
    "https://www.python.org",
]
# name, #urls, lifecycle mode (feather), settle seconds
SCENARIOS = [
    ("1 launched, no site", 0, "off", 10),
    ("2 Google Search", 1, "off", 20),
    ("3 five tabs", 5, "off", 40),
    ("4 ten tabs", 10, "off", 60),          # followed by 5: same launch, left alone
    ("6 ten tabs, Memory Saver", 10, "saver", 60),
]

def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw).stdout

def ps_table():
    rows = {}
    for line in sh(["ps", "-axo", "pid=,rss=,time=,command="]).splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4:
            pid, rss, cpu, cmd = parts
            secs = 0.0
            for p in cpu.split(":"):
                secs = secs * 60 + float(p)
            rows[int(pid)] = (int(rss), secs, cmd)
    return rows

HELPER = re.compile(r"WebKit|Safari")

def helper_pids():
    return {p for p, (_, _, c) in ps_table().items() if HELPER.search(c)}

def kind(cmd):
    for k in ("WebContent", "Networking", "GPU"):
        if k in cmd:
            return k
    return "Other"

def footprints(pids):
    """pid -> MB (phys_footprint). Processes that vanished mid-run are skipped."""
    if not pids:
        return {}
    out = sh(["footprint"] + [a for p in sorted(pids) for a in ("-p", str(p))])
    res = {}
    for m in re.finditer(r"\[(\d+)\]: \S+\s+Footprint: ([\d.]+) (B|KB|MB|GB)", out):
        mult = {"B": 1 / 2**20, "KB": 1 / 1024, "MB": 1, "GB": 1024}[m.group(3)]
        res[int(m.group(1))] = float(m.group(2)) * mult
    return res

class Browser:
    """Subclasses launch a browser with N URLs and quit it. `app_pid` + PID-diffed helpers = browser-attributed processes."""
    name = ""
    def attributed(self):
        t = ps_table()
        pids = {p for p in helper_pids() if p not in self.baseline and p in t}
        pids.add(self.app_pid)
        return {p: t[p][2] for p in pids if p in t}

    def memory(self):
        procs = self.attributed()
        fp = footprints(set(procs))
        g = {"app": 0.0, "WebContent": 0.0, "Networking": 0.0, "GPU": 0.0, "Other": 0.0}
        n = {"WebContent": 0}
        for pid, cmd in procs.items():
            mb = fp.get(pid, 0.0)
            if pid == self.app_pid:
                g["app"] += mb
            else:
                g[kind(cmd)] += mb
                if kind(cmd) == "WebContent":
                    n["WebContent"] += 1
        g["total"] = sum(g.values())
        g["n_webcontent"] = n["WebContent"]
        g["n_procs"] = len(procs)
        free = re.search(r"free percentage: (\d+)%", sh(["memory_pressure"]))
        g["system_free_pct"] = int(free.group(1)) if free else None
        return {k: (round(v, 1) if isinstance(v, float) else v) for k, v in g.items()}

    def cpu(self, seconds):
        t0 = {p: ps_table().get(p, (0, 0, ""))[1] for p in self.attributed()}
        time.sleep(seconds)
        t1 = ps_table()
        used = sum(t1[p][1] - c0 for p, c0 in t0.items() if p in t1)
        return round(used / seconds * 100, 2)

class Feather(Browser):
    name = "Feather"
    def __init__(self, mode):
        self.mode = mode
    def launch(self, urls):
        # An already-running Feather (e.g. the user's real session) is left alone: we identify our own instance by PID diff.
        self.preexisting = set(sh(["pgrep", "-x", "Feather"]).split())
        self.baseline = helper_pids()
        # Feather is sandboxed: it can write its stdout here (not into the project directory).
        self.log = Path(f"/private/tmp/feather-bench/feather-{os.getpid()}-{int(time.time())}.log")
        self.log.parent.mkdir(parents=True, exist_ok=True)
        self.log.write_text("")
        subprocess.run(["open", "-n", "--stdout", str(self.log), "--stderr", str(self.log), str(FEATHER_APP), "--args",
                        "--fresh", "--bench", "--load-all", f"--lifecycle={self.mode}", *[f"--open={u}" for u in urls]], check=True)
        for _ in range(50):
            new = [p for p in sh(["pgrep", "-x", "Feather"]).split() if p not in self.preexisting]
            if new:
                self.app_pid = int(new[0]); return
            time.sleep(0.2)
        sys.exit("Feather did not start")
    def signal(self, sig):
        subprocess.run(["kill", f"-{sig}", str(self.app_pid)])
    def live_views(self):
        self.signal("USR2"); time.sleep(1)
        m = re.findall(r"LIVE (\d+)/(\d+)", self.log.read_text())
        return {"live": int(m[-1][0]), "tabs": int(m[-1][1])} if m else None
    def restore_times(self, count=3):
        times = []
        for _ in range(count):
            before = len(re.findall(r"RESTORE_MS", self.log.read_text()))
            self.signal("USR1")
            for _ in range(40):
                time.sleep(0.5)
                found = re.findall(r"RESTORE_MS (\d+)", self.log.read_text())
                if len(found) > before:
                    times.append(int(found[-1])); break
            time.sleep(3)
        return times
    def quit(self):
        subprocess.run(["kill", str(self.app_pid)])
        for _ in range(30):
            if self.app_pid not in ps_table(): break
            time.sleep(0.2)
        time.sleep(3)

class Safari(Browser):
    name = "Safari"
    def osa(self, script):
        r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
        if r.returncode:
            sys.exit(f"osascript failed (Automation permission for Safari?): {r.stderr.strip()}")
        return r.stdout.strip()
    def launch(self, urls):
        if sh(["pgrep", "-x", "Safari"]).strip():
            sys.exit("Safari is running. Quit it first; this benchmark needs a clean Safari (it will not touch an open session).")
        self.baseline = helper_pids()
        subprocess.run(["open", "-a", "Safari"], check=True)
        for _ in range(50):
            pid = sh(["pgrep", "-x", "Safari"]).split()
            if pid:
                self.app_pid = int(pid[0]); break
            time.sleep(0.2)
        else:
            sys.exit("Safari did not start")
        time.sleep(4)
        existing = int(self.osa('tell application "Safari" to count of windows') or 0)
        if existing:
            self.osa('tell application "Safari" to quit')
            sys.exit(f"Safari restored {existing} existing window(s); aborting so your tabs aren't mixed into the measurement.")
        if not urls:
            self.osa('tell application "Safari" to make new document')
            return
        self.osa(f'tell application "Safari" to make new document with properties {{URL:"{urls[0]}"}}')
        for u in urls[1:]:
            self.osa(f'tell application "Safari" to tell front window to set current tab to (make new tab with properties {{URL:"{u}"}})')
    def quit(self):
        self.osa('tell application "Safari" to close every window')
        self.osa('tell application "Safari" to quit')
        for _ in range(50):
            if not sh(["pgrep", "-x", "Safari"]).strip(): break
            time.sleep(0.2)
        time.sleep(3)

def run_once(make_browser, browser_name, quick):
    results = []
    scenarios = [s for s in SCENARIOS if not (browser_name == "safari" and s[2] != "off")]
    for name, n, mode, settle in scenarios:
        b = make_browser(mode)
        idle_window = 5 if quick else 30
        b.launch(SITES[:n])
        time.sleep(3 if quick else settle)
        row = {"scenario": name, "mem": b.memory(), "cpu_idle_pct": b.cpu(idle_window)}
        print(f"  {name:28s} total {row['mem']['total']:8.1f} MB  app {row['mem']['app']:6.1f}  web {row['mem']['WebContent']:7.1f}"
              f" ({row['mem']['n_webcontent']} procs)  cpu {row['cpu_idle_pct']}%", flush=True)
        results.append(row)
        if name.startswith("4"):
            wait = 10 if quick else 300
            time.sleep(wait)
            row5 = {"scenario": "5 ten tabs, idle 5 min", "mem": b.memory(), "cpu_idle_pct": b.cpu(idle_window)}
            print(f"  {row5['scenario']:28s} total {row5['mem']['total']:8.1f} MB  app {row5['mem']['app']:6.1f}  web {row5['mem']['WebContent']:7.1f}"
                  f" ({row5['mem']['n_webcontent']} procs)  cpu {row5['cpu_idle_pct']}%", flush=True)
            results.append(row5)
        if isinstance(b, Feather) and mode != "off":
            row["live_views"] = b.live_views()
            row["restore_ms"] = b.restore_times(1 if quick else 3)
            print(f"    live web views {row['live_views']}, restore ms {row['restore_ms']}", flush=True)
        b.quit()
    return results

def env_info():
    return {"date": datetime.datetime.now().isoformat(timespec="seconds"), "macos": platform.mac_ver()[0],
            "chip": sh(["sysctl", "-n", "machdep.cpu.brand_string"]).strip(),
            "ram_gb": int(sh(["sysctl", "-n", "hw.memsize"])) // 2**30,
            "power": sh(["pmset", "-g", "batt"]).splitlines()[0].strip(),
            "sites": SITES}

def summarize(path):
    data = json.loads(Path(path).read_text())
    by = {}
    for run in data["runs"]:
        for row in run:
            by.setdefault(row["scenario"], []).append(row)
    def med(vals):
        vals = [v for v in vals if v is not None]
        if not vals: return "n/a"
        lo, hi = min(vals), max(vals)
        return f"{statistics.median(vals):.0f}" + (f" ({lo:.0f}–{hi:.0f})" if len(vals) > 1 else "")
    lines = [f"**{data['browser']}** · {data['env']['chip']}, {data['env']['ram_gb']} GB, macOS {data['env']['macos']} · {data['env']['date']} · "
             f"{len(data['runs'])} run(s), median (min–max) · {data['env']['power']}", "",
             "| Scenario | App MB | WebContent MB | Network+GPU+other MB | **Total MB** | WebContent procs | Idle CPU % (all procs) | Restore ms |",
             "|---|---|---|---|---|---|---|---|"]
    for name in sorted(by):
        rows = by[name]
        m = lambda k: [r["mem"][k] for r in rows]
        rest = [r["mem"]["Networking"] + r["mem"]["GPU"] + r["mem"]["Other"] for r in rows]
        restore = [t for r in rows for t in r.get("restore_ms", [])]
        lines.append(f"| {name} | {med(m('app'))} | {med(m('WebContent'))} | {med(rest)} | **{med(m('total'))}** | "
                     f"{med(m('n_webcontent'))} | {med([r['cpu_idle_pct'] for r in rows])} | {med(restore) if restore else '—'} |")
    return "\n".join(lines)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--browser", choices=["feather", "safari"])
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--quick", action="store_true", help="short timings; only to check the harness works, NOT for results")
    ap.add_argument("--summarize")
    a = ap.parse_args()
    if a.summarize:
        print(summarize(a.summarize)); return
    if not a.browser:
        ap.error("--browser or --summarize required")
    make = (lambda mode: Feather(mode)) if a.browser == "feather" else (lambda mode: Safari())
    out = ROOT / f"bench/results/{a.browser}-{datetime.datetime.now():%Y%m%d-%H%M%S}{'-quick' if a.quick else ''}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    data = {"browser": a.browser, "env": env_info(), "runs": []}
    for i in range(a.runs):
        print(f"run {i + 1}/{a.runs}", flush=True)
        data["runs"].append(run_once(make, a.browser, a.quick))
        out.write_text(json.dumps(data, indent=1))
    print(f"\nraw results: {out}\n\n{summarize(out)}")

if __name__ == "__main__":
    main()
