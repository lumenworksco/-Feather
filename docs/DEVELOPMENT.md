# Development notes

## Layout
```
project.yml                XcodeGen spec (the .xcodeproj and Info.plist are generated, not committed)
Feather/Browser/           Tab, TabStore, LifecycleManager, BrowserSettings, History, Bookmarks, Favicons,
                           Downloads, CookieImport, Storage, AddressResolver, Diagnostics (DEBUG self-test)
Feather/UI/                BrowserWindow, Sidebar, StartPage, SettingsView, Commands, WebViewContainer, Theme, Brand
tests/                     shell and Python test suites
bench/                     memory/CPU benchmark harness (see ../BENCHMARKING.md)
```

## How tabs and memory work
- A `Tab` always keeps its URL, title, favicon and saved `interactionState` (back/forward list + scroll position); its `WKWebView` exists only while the tab is "live".
- `LifecycleManager` decides which inactive tabs stay live (cap per mode in `BrowserSettings`). It runs on events only (tab switch, settings change, memory-pressure notification, a tab finishing loading) plus one coarse one-shot timer for idle expiry. Anything uncertain (including a web process that doesn't answer within 2 s) means "keep the tab".
- WebKit has no supported way to freeze a page and resume its JavaScript state, so unloading means "reload from saved state when needed".
- Sessions are JSON in the app container, written about 0.6 s after the first change in a burst (not restarted by later changes, so a page that keeps changing its title can't postpone saving).

## Launch arguments (for tests and benchmarks)
`--open=URL` (repeatable) and `--open-pinned=URL` open tabs. **Never pass a bare URL**: AppKit treats it as "open this document" and SwiftUI then never creates the window.
`--fresh` uses throwaway storage; `--profile=NAME` a named throwaway profile that persists across launches; `--lifecycle=off|balanced|saver|aggressive`; `--sidebar=hidden`; `--load-all` (load every `--open` tab); `--bench` (SIGUSR1 restores an unloaded tab and prints `RESTORE_MS`, SIGUSR2 prints every tab's state); `--selftest` (Debug only); `--snapshot=name.png` (Debug; renders the window's views into the app container's tmp folder).

## Tests
Run from the repo root after a Debug build. They drive the real app and need a logged-in macOS GUI session; the shell suites refuse to run while a real (non-test) Feather is open because they kill Feather processes.

| Command | What it covers |
|---|---|
| `open -n --stdout /private/tmp/st.log --stderr /private/tmp/st.log build/Build/Products/Debug/Feather.app --args --selftest` | lifecycle cap, restore, unsaved-input veto, memory pressure, deallocation, address-bar focus, pinning, drag/move rules, zoom, find |
| `tests/restore-test.sh` | `kill -9` and relaunch: tabs, pins, history, lazy restore, page-process kill, graceful quit |
| `tests/ready-test.sh` | downloads, cookie import, links from other apps (running and cold start) |
| `tests/drag-test.py` | real mouse drags in the sidebar (needs Accessibility permission for the terminal) |
| `tests/filmstrip.py <dir>` | not a pass/fail test: captures frames of the real window mid-animation for review |

## Known issues
- A closed `Tab` object (title/URL/icon only; its web view is always freed) is occasionally still referenced after closing. Cause not found; the self-test warns instead of failing on it.
- `tests/ready-test.sh` once failed three checks when run immediately after `tests/restore-test.sh` and passed on every rerun; not explained.
- A crash can lose changes from the last ~0.6 s.

## Pitfalls we hit (so you don't)
- Creating a `WKWebView` inside SwiftUI's `@StateObject` initializer (before the scene exists) stops the window appearing; loading waits until launch completes.
- Lazy SwiftUI containers (`LazyVStack`) retained closed tabs; the tab list uses plain stacks.
- SwiftUI's `FocusState` races with views rebuilt per tab; address-bar focus goes through AppKit (`AddressFocus`) and requires the *same* field to hold focus for 150 ms.
- The bundle identifier (`dev.feather.Feather`) determines the sandbox container; changing it orphans existing user data unless it is migrated.
