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

## Tab groups (`TabGroups.swift`)
A `Tab` has an optional `groupID`; `TabStore.groups` holds each group's name, color and folded state. Members are kept next to each other in `tabs` (`enforceGroupOrder()` after restore, `move` and `addToGroup` for edits); pinned tabs are never in a group; a group with no tabs is removed. The session file gets optional `groups` and per-tab `group` fields, **without a version bump**, so an older build still reads the file (it just ignores groups). Closed tabs remember their group so Reopen Closed Tab can bring it back.

Moving groups: `moveGroup` puts a group before a tab, or before the group that tab is in (a group is never split, never into the pinned area); `moveToTop` and the New Tab row handle "above the first group". Folding (`collapse`) unloads members through `LifecycleManager.unload`, which applies the same vetoes as automatic unloading. Idle groups fold from one one-shot timer (`scheduleGroupFold`, floor 30 s), recomputed in `tabsChanged()`; `Settings.groupFoldMinutes` = 0 turns it off.

## Sound (`MediaBridge.swift`)
WebKit has no public API for "this tab is playing audio" or for muting a web view, so a script in an **isolated content world** (the page cannot see or fake it) watches `<audio>`/`<video>` in every frame and posts to a reply-handler. State is kept per frame (an idle embed cannot hide the main page's sound) and reset on main-frame commit; a new document asks the native side whether its tab is muted, so muting survives navigation. Mute sets `muted` on the elements (and re-mutes pages that unmute themselves). Blind spots: media never added to the page, shadow DOM, Web Audio.

Picture in picture: WebKit's `_allowsPictureInPictureMediaPlayback` preference is **off by default for WKWebView on macOS** (`video.webkitSupportsPresentationMode('picture-in-picture')` is false and `requestPictureInPicture()` rejects with NotSupportedError, however the call is made). There is no public API for it on macOS, so `TabStore.enablePictureInPicture` calls the private setter after launch, through its method implementation (key-value coding does not find an underscore-prefixed setter and throws; setting it inside the store's initializer keeps the window from appearing). It is guarded with `responds(to:)`. This is private API: if it disappears, PiP is off again, nothing else breaks.

## Content blocking (`ContentBlocker.swift`)
One compiled `WKContentRuleList` on the shared `WKUserContentController`: a block rule per domain (`load-type: third-party`, so a site's own resources are never touched), then one `ignore-previous-rules` rule per excepted site. `ignore-previous-rules` only reaches back within the same list, so block rules and exceptions are compiled together and the list is swapped when the exceptions change. Lists are cached by a hash of their JSON; stale ones are removed. Launch waits at most 1.5 s for the rules, so the first page is covered. The self-test proves block, exception and removal on a page that was already open.

## Split view (`SplitView.swift`)
`TabStore.split` is a pair of tab ids. It shows only while the selected tab is one of them; selecting any other tab, or closing either half, clears it. `SplitFocus` is a mouse-down monitor that makes the clicked pane's tab the selected one (the click itself still goes to the page). `LifecycleManager` never unloads a split member. Not persisted.

## Bookmarks and History window (`UI/Library.swift`)
A separate `Window("Bookmarks and History", id: "library")` (its title must never be "Feather": tests and focus code look windows up by that title). Data operations live on `Bookmarks` (folders are just an optional `folder` name on each bookmark; reordering is per folder) and `History` (`clear(since:)`, `remove(ids:)`, `HistoryGrouping` for the day sections), all covered by the self-test. Debug options for screenshots: `--open-library=bookmarks|history` with `--snapshot-library=name.png`, and `--open-split` for the first two tabs.

## HTTPS-only (`HTTPSOnly.swift`) and permissions (`SitePermissions.swift`)
`HTTPSOnly.upgraded` decides what to upgrade (main-frame navigations only; local names, IPs, single-word hosts and explicit ports are exempt). The tab cancels the http navigation and loads the https one; if that fails with a "no secure version" error, or the site bounces straight back to http, `Tab.insecureOffer` is set and the error page offers the plain page (`continueInsecurely`, remembered per site until quit). Camera and microphone prompts are taken over from WebKit (`requestMediaCapturePermissionFor`), so answers can be stored (`permissions.json`) and listed; WebKit gives no hook for location.

## Search Tabs (`QuickSearch.swift`, `UI/QuickSwitcher.swift`)
`QuickSearch.results` is a pure function (self-tested): every word must match title or address; tabs, then bookmarks, then history; a page already open is not offered twice. The panel's text field is an `NSTextField` (not SwiftUI focus) so arrows, Return and Escape reach it. The shortcut is ⇧⌘A because a menu shortcut on ⌘K would take it away from websites that use it.

## Persistence (`SessionStore.swift`, `Storage.swift`)
- Files in the profile folder: `session.json`, `session.prev.json`, `SessionBackups/session-<UTC time>-t<tabs>-p<pinned>.json` (time and counts are in the name, so the menu never opens files), `SessionQuarantine/` (newest 10 damaged copies), `profile.lock` (`flock`, released by the OS if the process dies).
- Write path (`DurableFile`): temp file, `F_FULLFSYNC`, read back and compare, `rename`, directory fsync. The session is validated (re-parsed) *before* writing. The previous copy is written from memory first, so at every instant one complete session file exists. A save is only remembered as done after it really succeeded, so failures retry. Encoding uses sorted keys so "unchanged" can be detected (idle means zero writes).
- Load path: primary, then previous, then backups newest-first. `SessionParser` reads field by field (a bad `state` drops only the state; a tab with no usable address is the only thing dropped whole). Any file that can't be read, is partial, or is from a newer version is copied to quarantine first. Files without a `version` field (all existing user files) are read as version 1.
- Backups: at launch (before the first write), every `--snapshot-interval` seconds (default 600) while things change, at quit, and when the tab count drops sharply relative to the fullest session of the last 2 minutes. Retention (`BackupRetention`): everything from the last 2 h, hourly for 24 h, the fullest per day for 14 days, always the newest 3.
- Triggers: structural changes ~0.25 s, incidental ones (a page changing its own URL) ~1 s. Sleep, power-off, fast-user-switch (on the *workspace* notification center), app deactivation and quit flush synchronously. Page state (`interactionState`) is cached per tab and refreshed only for tabs that navigated.
- Failures show a banner and retry after 3 s, doubling up to 30 s; nothing runs while saves succeed.

## How tabs and memory work
- A `Tab` always keeps its URL, title, favicon and saved `interactionState` (back/forward list + scroll position); its `WKWebView` exists only while the tab is "live".
- `LifecycleManager` decides which inactive tabs stay live (cap per mode in `BrowserSettings`). It runs on events only (tab switch, settings change, memory-pressure notification, a tab finishing loading) plus one coarse one-shot timer for idle expiry. Anything uncertain (including a web process that doesn't answer within 2 s) means "keep the tab".
- WebKit has no supported way to freeze a page and resume its JavaScript state, so unloading means "reload from saved state when needed".
- Sessions are JSON in the app container, written about 0.6 s after the first change in a burst (not restarted by later changes, so a page that keeps changing its title can't postpone saving).

## Launch arguments (for tests and benchmarks)
`--open=URL` (repeatable) and `--open-pinned=URL` open tabs. **Never pass a bare URL**: AppKit treats it as "open this document" and SwiftUI then never creates the window.
`--fresh` uses throwaway storage; `--profile=NAME` a named throwaway profile that persists across launches; `--lifecycle=off|balanced|saver|aggressive`; `--sidebar=hidden`; `--load-all` (load every `--open` tab); `--snapshot-interval=SECONDS`; `--bench` (SIGUSR1 restores an unloaded tab and prints `RESTORE_MS`, SIGUSR2 prints every tab's state); `--selftest` (Debug only); `--snapshot=name.png` (Debug; renders the window's views into the app container's tmp folder).

## Tests
Run from the repo root after a Debug build. They drive the real app and need a logged-in macOS GUI session; the shell suites refuse to run while a real (non-test) Feather is open because they kill Feather processes.

| Command | What it covers |
|---|---|
| `open -n --stdout /private/tmp/st.log --stderr /private/tmp/st.log build/Build/Products/Debug/Feather.app --args --selftest` | lifecycle cap, restore, unsaved-input veto, memory pressure, deallocation, address-bar focus, pinning, drag/move rules, zoom, find |
| `tests/restore-test.sh` | `kill -9` and relaunch: tabs, pins, history, lazy restore, page-process kill, graceful quit |
| `tests/ready-test.sh` | downloads, cookie import, links from other apps (running and cold start) |
| `tests/persistence-test.py` | the real app against damaged files: empty, truncated, garbage, wrong schema, one bad tab, bad state blob, missing, newer version, primary and previous bad (restores a backup), everything bad (starts blank, keeps every damaged copy); an unwritable folder (banner, then the retry succeeds); a second instance (writes nothing); a sudden mass-close (backup of the fuller session); a copy of the real session. Each case asserts the right tabs came back *and* that no damaged file was destroyed |
| `tests/favicon-test.py` | favicons persist: icons are saved for two sites, the app is relaunched without loading them, and the never-loaded tab still shows its icon (sends no input) |
| `tests/ux-test.py` | **real keyboard and mouse events**: ⌘T and typing right after it (no pause), Return, searching, ⌘W/⇧⌘T, ⌘1/2, ⌃Tab, Escape, ⌘L, pin, zoom, find, ⌘S, `target=_blank` and ⌘-click links (needs Accessibility permission; types and moves the cursor) |
| `tests/drag-test.py` | real mouse drags in the sidebar (needs Accessibility permission for the terminal) |
| `tests/filmstrip.py <dir>` | not a pass/fail test: captures frames of the real window mid-animation for review |

## Known issues
- A closed `Tab` object (title/URL/icon only; its web view is always freed) is occasionally still referenced after closing. Cause not found; the self-test warns instead of failing on it.
- The test suites serve pages on port 8765 by default; set `FEATHER_TEST_PORT` if something else uses it. `tests/ready-test.sh` once failed three checks right after `tests/restore-test.sh` because that suite left its web server running (it killed the wrapper shell, not the server); both scripts now `exec` the server, and the readiness script also waits for a previous suite's processes to exit.
- A crash can lose changes from the last ~0.25 s. A power cut mid-save is untested (the write path forces data to disk, but that can only be verified by actually cutting power).
- Test input goes to whatever app is in front, so the input tests (ux, drag, persistence, filmstrip) check that the test copy is frontmost before every key or click and abort otherwise. They still need a machine nobody is using.

## Pitfalls we hit (so you don't)
- Creating a `WKWebView` inside SwiftUI's `@StateObject` initializer (before the scene exists) stops the window appearing; loading waits until launch completes.
- Lazy SwiftUI containers (`LazyVStack`) retained closed tabs; the tab list uses plain stacks.
- The address field is **one view for the whole window** (not rebuilt per tab); its text is `store.address`, updated synchronously on tab changes, and select-all only applies to untouched text. Anything asynchronous that rewrites the field makes fast typing right after ⌘T lose letters (we hit this).
- Synthetic Unicode key events are ignored by text fields; tests must type with real key codes.
- A window opens where it was last placed, so tests must find the sidebar relative to the window, not at fixed screen coordinates.
- The bundle identifier (`dev.feather.Feather`) determines the sandbox container; changing it orphans existing user data unless it is migrated.

## Security keys

Code in `Feather/Browser/SecurityKey/`: `CBOR` (RFC 8949 subset) → `CTAPHID` (64-byte USB framing) → `HIDTransport` (IOHIDManager, FIDO usage page only, needs the `com.apple.security.device.usb` entitlement) → `CTAPClient` / `CTAPDevice` (CTAP2 commands, PIN protocol v1) → `WebAuthnController` (request checks, flows, the sheet's state) ← `WebAuthnBridge` (message handler + the script that replaces `navigator.credentials.get/create` for `publicKey` requests).

* `Feather --keyprobe` (Debug): prints what a plugged-in key reports (no touch needed).
* `tests/webauthn-test.py [--uv]`: real-key register + sign-in, verified by python-fido2 (`pip install fido2` in a venv). Needs a key and two touches.
* The self-test covers the encoding vectors, USB framing and the site-identity rules.

## Updates

Code: `Shared/UpdateTrust.swift` (manifest, Ed25519 verification, version rules; compiled into both the app and the helper), `Feather/Updates/Updates.swift` (check, download, hand-off), `Feather/Updates/UpdateBanner.swift`, and `FeatherUpdater/main.swift` (the unsandboxed installer, embedded at `Contents/Library/FeatherUpdater.app`).

* The app finds the release through `api.github.com/repositories/<id>/releases/latest` (the numeric id survives a rename), downloads `update.json` + `update.json.sig`, verifies them with the public key built into the app (`UPDATE_PUBLIC_KEY` in `project.yml`, written into both Info.plists), then downloads the zip named in the manifest and checks size and SHA-256.
* The app and helper exchange files through `~/Library/Caches/dev.feather.updater/` (a sandbox exception for exactly that folder): Launch Services drops launch arguments for sandboxed callers, and macOS asks before one app reads another's container.
* The helper trusts nothing: it re-verifies the signature, size, hash, bundle id and version, waits for the app to quit, unpacks with `ditto --noqtn`, checks `codesign`, copies next to the old app, swaps, starts the new version (rolling back if it does not start) and trashes the old one.
* `--update-feed=URL` points a copy at another feed (https, or http on localhost); it cannot make Feather accept anything not signed by the build's key. `--update-auto-install` (only with a local feed) installs without a click. Test builds pass their own key with `UPDATE_PUBLIC_KEY=...` to `xcodebuild`.
* `tests/update-test.py` builds two versions with a throwaway key and runs the whole flow on a copy at `/Applications/Feather-uptest.app` with a throwaway profile (it never touches the real app). Builds are cached in `build-test/`; `--rebuild` redoes them.

### Making a release
1. One-time: `bash tools/new-update-key.sh` (stores the signing key in your Keychain, prints the public key for `UPDATE_PUBLIC_KEY`), then **back the key up** with `bash tools/export-update-key.sh` into a password manager. If the key is lost, installed copies cannot be updated automatically and must be reinstalled by hand.
2. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`, update `CHANGELOG.md`, commit and push.
3. `bash tools/release.sh` builds from a fresh clone of the pushed commit, signs the manifest, and prints the files to upload. It refuses unless the pushed commit is exactly your local HEAD (you only sign what you have seen) and it runs the signing script from your local checkout, never from the clone (code from GitHub must not reach the key).
4. `gh release create vX.Y.Z-alpha --target main --title "Feather X.Y.Z-alpha" --notes-file <notes> --latest <the four files>`.
Never put the private key in GitHub Actions secrets: that would defeat the point of signing.

## Website

`site/` is the public website (plain HTML, CSS and a little JavaScript; no frameworks, fonts or third-party requests, and a strict content-security policy). `.github/workflows/pages.yml` publishes it to GitHub Pages whenever `site/` changes on `main`.

* The download button reads the latest release from GitHub's API in the visitor's browser (version, size, date, SHA-256) and falls back to the releases page.
* The screenshots in `site/assets/` come from the current app and made-up demo sites, never real browsing: `python3 tools/site-screenshots.py` (needs the Debug build and Pillow), then `python3 tools/site-og.py` for the icons and social-preview image. Refresh them when the app's look changes.
* Check changes locally with `python3 -m http.server -d site 8000`.
