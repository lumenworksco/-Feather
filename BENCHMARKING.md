# Benchmarking Feather vs Safari

Goal: a memory/CPU baseline that is repeatable and honest. **No results have been recorded yet**, so Feather makes no claim of using less memory than Safari or any other browser. When the benchmark is run, `python3 bench/bench.py --summarize <file>` prints the table from the raw JSON in `bench/results/`; nothing in it is typed by hand.

## 1. Scenarios

| # | Scenario | Feather | Safari |
|---|---|---|---|
| 1 | Launched, no site loaded | `--lifecycle=off`, blank tab | new empty window (Start Page) |
| 2 | Google Search loaded | 1 tab | 1 tab |
| 3 | Five tabs | first 5 URLs below | same |
| 4 | Ten tabs | all 10 URLs | same |
| 5 | Ten tabs, left alone for 5 min | same launch as 4, no interaction | same |
| 6 | Inactive tabs unloaded by Feather's logic | 10 tabs, `--lifecycle=saver` (≤3 live), then restore timing | n/a (Safari's discarding isn't scriptable or observable) |

Scenarios 1–5 use `--lifecycle=off` so Feather's own unloading is **disabled**: that isolates what the engine and app cost, and makes 6 the only place where Feather's memory logic is credited.

The 10 pages (see `SITES` in `bench/bench.py`): Google search, two Wikipedia articles, Hacker News, apple.com, a GitHub repo, BBC News, MDN, nasa.gov, python.org. They are live sites, so content changes between runs; that's why each scenario is run several times and reported as median (min–max).

## 2. What is measured

For every process attributed to the browser, `footprint -p <pid>` reports **phys_footprint**. That is the same quantity Activity Monitor shows in its **Memory** column (spot-check one process in both tools before trusting this on your machine). Summed in groups:

* **App**: the Feather / Safari process itself (UI, bookmarks, tab bookkeeping).
* **WebContent**: one process per page/site; usually the largest group by far.
* **Networking + GPU + other**: shared WebKit helpers.
* **Total**: everything above. **This is the number to compare, never "App" alone.**

Also recorded: number of WebContent processes, system "free memory %" at the time (a noise indicator), idle CPU, and restore time.

**Idle CPU** = CPU-seconds consumed by all attributed processes over 30 s ÷ 30 s, in percent of one core, taken after pages have settled and with the browser in the background of nothing else. Settling time is fixed per scenario (10–60 s); if a page is still animating or loading ads, idle CPU will be higher, which is real but noisy.

**Restore time** (Feather only) = time from selecting an unloaded tab until its `didFinish`. It **includes network time** and so varies with the site and cache; it's reported per sample, not as a guarantee.

### How helper processes are attributed
WebKit helpers are launched by `launchd` (parent PID 1) and `launchctl procinfo` needs root, so ownership can't be read directly. The harness snapshots all `WebKit`/`Safari` PIDs *before* launching the browser and attributes every new one to it. **This is only valid if nothing else starts WebKit processes during the run**: quit Mail, Messages, Notes, other WebKit-based apps, and don't browse in the meantime. Electron/Chromium-based apps don't use WebKit helpers and are not counted, but they do compete for RAM, which changes system pressure.

## 3. Procedure

Preparation (both browsers, every time):
1. Same Mac, on AC power, display on, no screen saver, window visible (an occluded window is throttled by WebKit and misrepresents an active page).
2. Quit WebKit-using apps. Note what else is running; record it with the results.
3. Build Feather in **Release** (Debug adds a debug dylib and inflates the app number):
   `xcodebuild -project Feather.xcodeproj -scheme Feather -configuration Release -derivedDataPath build build`
4. Safari must **not** be running. The harness refuses to start otherwise, and aborts if Safari restores windows (so your tabs never end up in the measurement). **Safari's last-session state will be replaced by the test run**, so this is best done when you don't mind that.
5. First use of Safari automation triggers a macOS Automation permission prompt for your terminal.

Run:
```
python3 bench/bench.py --browser feather --runs 3     # ~12 min per run
python3 bench/bench.py --browser safari  --runs 3
python3 bench/bench.py --summarize bench/results/<file>.json
```
`--quick` exists to check the harness itself; its numbers are meaningless (pages haven't settled).

Manual cross-check (do this at least once; it catches attribution mistakes):
```
footprint -p $(pgrep -x Feather)
ps -axo pid,rss,%cpu,command | grep -E 'Feather|WebKit\.(WebContent|Networking|GPU)'
```
and compare with Activity Monitor (below).

## 4. Interpreting results

### Activity Monitor
* Use the **Memory** tab, *View ▸ All Processes*, filter by "WebKit" or the browser name. WebKit helpers appear as separate rows, **not** under the browser's row; the browser's own row is only the "App" column of the table. If you only read that row you will wildly under-count (the app process is a small fraction of the total once pages are open).
* Column **Memory** ≈ phys_footprint (what the harness sums). **Real Mem** is resident size: it can include shared pages that are counted again in other processes, so don't sum it across processes and expect a clean total. **Compressed Mem** shows pages macOS has compressed instead of evicting: memory that looks "freed" may have only been compressed.
* Bottom **Memory Pressure** graph (green/yellow/red) matters more than "Memory Used". macOS deliberately fills RAM with reclaimable cache; low "free" isn't a problem by itself. A browser that triggers yellow/red pressure, swapping, or compression is the real cost on an 8 GB machine.
* Activity Monitor numbers are instantaneous; take several readings after the system has been idle, as the harness does.

### Instruments
* **Allocations / VM Tracker** on the *Feather app process*: shows what Feather's own code retains (tab objects, favicons, history). Good for finding leaks in the app (the lifecycle self-test already checks that closed `Tab`/`WKWebView` objects deallocate).
* Page memory lives in the WebContent processes, which are system XPC services. Attaching Instruments to them may be restricted by SIP/entitlements; if it is, use `footprint -p <pid>` and `vmmap --summary <pid>` for those instead, rather than concluding a page is "free".
* **Time Profiler / CPU**: profile Feather's app process for UI-thread cost; web page CPU is in WebContent and mostly reflects the page itself.
* Never compare an Instruments "Allocations" total against Activity Monitor's total; they measure different things.

### Reading the table
* Compare **Total** column to Total column. Do not compare Feather's *App* to Safari's *App*.
* Differences smaller than the min–max spread are noise. With only a handful of runs on live websites, treat anything under roughly 10–15% as unproven.
* Scenario 6 vs 4 shows what Feather's unloading saves *and* what it costs (restore time, lost JS state). A saving is only valuable if the restore time and lost state are acceptable.
* Scenario 5 vs 4 shows whether letting tabs sit idle changes anything on its own (WebKit/macOS may trim memory by itself).

## 5. Known limits of this benchmark
* Live sites and A/B ordering effects; 3 runs is a baseline, not a statistical study.
* Safari tab-discarding behavior isn't observable here, so scenario 6 has no Safari equivalent.
* One machine, one macOS version, 8 GB RAM; results under memory pressure differ from a 32 GB Mac.
* Safari is launched via AppleScript, Feather via command-line URLs; tab-opening order and timing differ slightly.
* Fixed settle times: a very slow site could still be loading at measurement time (visible as elevated idle CPU).
