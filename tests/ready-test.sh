#!/bin/bash
# Daily-use readiness checks (Debug build, throwaway profile "readytest"; real data untouched):
# downloads, cookie import, links opened from other apps (running + cold start), zoom persistence.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Build/Products/Debug/Feather.app"
PROFILE_DIR="$HOME/Library/Containers/dev.feather.Feather/Data/tmp/FeatherProfile-readytest"
LOG=/private/tmp/feather-ready-test.log
PORT=${FEATHER_TEST_PORT:-8765}
# Safety: these tests kill Feather processes. Refuse to run if a real (non-test) session is open.
for p in $(pgrep -x Feather); do
  ps -o command= -p "$p" | grep -qE -- '--(profile|fresh|selftest)' || { echo "A real Feather session is running (pid $p). Quit it first; this test would kill it."; exit 1; }
done
# A previous suite's Feather and web server may still be shutting down: wait for them (a leftover made three checks fail once).
for _ in $(seq 1 20); do pgrep -x Feather >/dev/null || break; sleep 1; done
sleep 3
pass=0; fail=0
check() { if [ "$2" = "ok" ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1  ($3)"; fail=$((fail+1)); fi; }
cleanup() { pkill -x Feather 2>/dev/null; [ -n "${SRV:-}" ] && kill $SRV 2>/dev/null; [ -n "${DLFILE:-}" ] && rm -f "$DLFILE"; }
trap cleanup EXIT
pkill -x Feather 2>/dev/null; sleep 1
rm -rf "$PROFILE_DIR"; defaults delete dev.feather.profile.readytest 2>/dev/null; mkdir -p "$PROFILE_DIR"
(cd "$ROOT/tests/restore" && python3 -m http.server $PORT --bind 127.0.0.1 >/dev/null 2>&1) & SRV=$!
sleep 1
dump() { : > "$LOG"; kill -USR2 "$(pgrep -x Feather)"; sleep 1.5; grep "^TAB" "$LOG"; }
start() { : > "$LOG"; open -n --stdout "$LOG" --stderr "$LOG" "$APP" "${@:1}"; for i in $(seq 1 30); do pgrep -x Feather >/dev/null && break; sleep 0.5; done; }

echo "== Cookie import (one-shot file, deleted after use)"
python3 - <<PY
import json, time
json.dump([{"domain":"localhost","name":"feather_test","value":"ok123","path":"/","expires":time.time()+3600,"secure":False,"httpOnly":False,"sameSite":1}],
          open("$PROFILE_DIR/cookies-import.json","w"))
PY
start --args --profile=readytest --bench --open=http://localhost:$PORT/cookie.html
sleep 8
T=$(dump); echo "$T" | sed 's/^/    /'
echo "$T" | grep -q "cookies=feather_test=ok123" && r=ok || r=no
check "imported cookie is sent to the site (document.cookie)" $r "title did not contain the cookie"
[ ! -e "$PROFILE_DIR/cookies-import.json" ] && r=ok || r=no
check "cookie file deleted after import" $r "file still present"

echo "== Download"
ls ~/Downloads > /tmp/feather-dl-before.txt
: > "$LOG"
# open the zip in a new tab: an unviewable type must become a download, not a blank/failed tab
open -a "$APP" "http://localhost:$PORT/sample.zip"
sleep 6
DLFILE=$(grep "^DOWNLOAD_FINISHED" "$LOG" | tail -1 | awk '{print $2}')
[ -n "$DLFILE" ] && [ -f "$DLFILE" ] && r=ok || r=no
check "file link downloads to ~/Downloads" $r "log: $(grep -i download "$LOG" | head -2)"
[ -n "$DLFILE" ] && unzip -p "$DLFILE" hello.txt 2>/dev/null | grep -q "Feather download test" && r=ok || r=no
check "downloaded file is intact" $r ""

echo "== Link opened from another app (app already running)"
before=$(dump | wc -l | tr -d ' ')
open -a "$APP" "http://localhost:$PORT/index.html"; sleep 4
T=$(dump)
echo "$T" | grep -q "index.html\|pushed" && r=ok || r=no
check "URL from outside opens in a tab" $r "$(echo "$T" | cut -c1-80 | tr '\n' ';')"

echo "== Cold start by opening a link (window must still appear)"
pkill -x Feather; sleep 2
start -a "$APP" "http://localhost:$PORT/a.html" --args --profile=readytest --bench
sleep 8
T=$(dump)
echo "$T" | grep -q "b.html\|a.html" && r=ok || r=no
check "app launched by a link loads it" $r "$(echo "$T" | cut -c1-80 | tr '\n' ';')"
W=$(/usr/bin/swift -e 'import CoreGraphics; for w in (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String:Any]]) where (w["kCGWindowOwnerName"] as? String)=="Feather" { let b=w["kCGWindowBounds"] as! [String:Any]; if (b["Width"] as! Double) > 600 { print("window") } }' 2>/dev/null | head -1)
[ "$W" = "window" ] && r=ok || r=no
check "main window exists after launching via a link" $r "no large Feather window found"

echo; echo "readiness test: $pass passed, $fail failed"; [ "$fail" = 0 ]
