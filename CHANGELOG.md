# Changelog

## 0.1.8-alpha
- **Fixed:** the tab's right-click menu left out *Mute Tab* and *Picture in Picture* (and kept an out-of-date group list) because it was not rebuilt when the tab started playing sound.
- **Split view**: right-click a tab ▸ *Open Side by Side with Current Tab*. Click a page to make it active; picking another tab or *Exit Split View* ends it. Both halves stay loaded; not saved across restarts; always 50/50.
- **Bookmarks and History window** (⌥⌘B / ⌘Y): search, edit, reorder, delete, bookmark folders; history by day with clear last hour / today / all.
- **Secure connections only** (on by default; Settings ▸ Privacy): `http://` pages open as `https://`, with a warning and an explicit "open without encryption" choice when there is no secure version. Local and port addresses are left alone.
- **Site permissions**: Feather now asks before a site uses the camera or microphone, remembers answers if you tick the box, and Settings lists and undoes them. Location stays with macOS.
- Slow pages: tabs kept only because a page was loading or slow to answer are tried again a few times, instead of staying loaded.
## 0.1.7-alpha
- **Tab groups, more.** Folding a group now **unloads its tabs** (the selected tab and any tab with typed-in text, sound, camera/microphone use or a pending security key stay). Drag a whole group to reorder it, use the **+** on a group header (or right-click ▸ New Tab in Group) for a new tab inside it, and drop a tab or group on the New Tab row to put it at the very top. **Settings ▸ Tab groups** can fold groups you haven't used for 30 minutes to 4 hours (off by default).
- **Search Tabs** (⇧⌘A): find an open tab, a bookmark or a page from history by typing part of its name or address. (It is not ⌘K, which many websites use.)
- **Sound.** Tabs that play sound show a speaker; click it to mute. Right-click ▸ Picture in Picture, or Navigate ▸ Picture in Picture. Only `<audio>`/`<video>` elements are detected, not Web Audio. Picture in Picture is not tested with a real video yet.
- **Downloads list**: a button beside the gear (or ⌥⌘L) shows this session's downloads with open, show in Finder, cancel, remove and clear.
- **Ad and tracker blocking** (on by default; **Settings ▸ Content blocking**): requests a page makes to about 60 well-known advertising and tracking companies are blocked by WebKit. Right-click a tab to turn it off for one site. It is not a full ad blocker (ads served from a site's own domain, such as YouTube's, are not touched), and it never blocks a site's own requests.
- Internal: the self-test waits for unloading to finish instead of a fixed delay, and prints which tabs were live when a cap check fails.
## 0.1.6-alpha
- **Tab groups.** Right-click a tab > Add to Group > New Group (or Navigate > Add Tab to New Group). Groups have a name and a color, sit together in the sidebar, fold away by clicking their header, and are saved with your session. Drop a tab on a header to add it; links opened from a grouped tab stay in the group; pinning a tab takes it out. Not yet: dragging a whole group, or putting a tab before a group that is first in the list by dragging.
- Fixed: a tab that was playing audio kept playing for a while after it was closed (or unloaded). Media is now paused and the page emptied before the web view is released.
- Security keys: every refused request, and every key plugged in or removed, is now written to the system log (Console, subsystem `dev.feather`, category `webauthn`), so a failed sign-in can be traced.

## 0.1.5-alpha
- The start page now shows up to **20** bookmarks (it showed 12), in rows of five, and scrolls when the window is too short to show them all. The Bookmarks menu always listed every bookmark.

## 0.1.4-alpha
- The automatic update check no longer depends on a timer alone (macOS slows timers of background apps): it also runs when you switch back to Feather, and logs why a check ran or was skipped. This is the first version that can be reached by a real automatic update from 0.1.3.

## 0.1.3-alpha
- **Updates inside the app.** Feather checks GitHub for a newer release about once a day (switch off in Settings), shows a banner, and installs it with one click: it saves your tabs, swaps itself, and reopens. Updates are signed by the project owner and checked for size and SHA-256; downgrades are refused. This is the first version with the updater, so it has to be installed by hand once; later versions can update themselves.

## 0.1.2-alpha
- **USB security keys (YubiKey and other FIDO2 keys)** now work for sign-in and registration, including PIN entry. WebKit does not offer this to third-party browsers, so Feather talks to the key itself. Not supported: iCloud passkeys, Touch ID, NFC/Bluetooth keys (these need an Apple entitlement).
- Site icons are kept across relaunches (small local cache, refreshed weekly, cleared with Clear History).

## 0.1.1-alpha
- Fixed blurry Google Sheets and Docs (`window.outerWidth/outerHeight` was 0 in `WKWebView`).
- Background tabs now get a real viewport.

## 0.1.0-alpha
- First public alpha: sidebar and pinned tabs, memory-conscious tab lifecycle, crash-safe sessions, bookmarks, history, downloads, find, zoom, printing.
