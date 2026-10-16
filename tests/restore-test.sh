#!/bin/bash
# Kill-and-relaunch test for session restore. Debug build, throwaway profile ("restoretest"); real data untouched.
#   tests/restore-test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Build/Products/Debug/Feather.app"
PROFILE_DIR="$HOME/Library/Containers/dev.feather.Feather/Data/tmp/FeatherProfile-restoretest"
LOG=/private/tmp/feather-restore-test.log
PORT=${FEATHER_TEST_PORT:-8765}
# Safety: these tests kill Feather processes. Refuse to run if a real (non-test) session is open.
for p in $(pgrep -x Feather); do
  ps -o command= -p "$p" | grep -qE -- '--(profile|fresh|selftest)' || { echo "A real Feather session is running (pid $p). Quit it first; this test would kill it."; exit 1; }
done
pass=0; fail=0
check() { if [ "$2" = "ok" ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1  ($3)"; fail=$((fail+1)); fi; }

cleanup() { pkill -x Feather 2>/dev/null; [ -n "${SRV:-}" ] && kill $SRV 2>/dev/null; }
trap cleanup EXIT
pkill -x Feather 2>/dev/null; sleep 1
rm -rf "$PROFILE_DIR"; defaults delete dev.feather.profile.restoretest 2>/dev/null

(cd "$ROOT/tests/restore" && python3 -m http.server $PORT --bind 127.0.0.1 >/dev/null 2>&1) & SRV=$!
sleep 1

launch() {   # launch <extra args...>
  : > "$LOG"
  open -n --stdout "$LOG" --stderr "$LOG" "$APP" --args --profile=restoretest --bench --lifecycle=off "$@"
  for i in $(seq 1 30); do pgrep -x Feather >/dev/null && break; sleep 0.5; done
  PID=$(pgrep -x Feather)
}
snapshot() {  # prints "TAB ..." lines (URL list + selection) from the running app
  : > "$LOG"; kill -USR2 "$PID"; sleep 1.5
  grep "^TAB" "$LOG"
}
urls() { awk '{print $6}'; }
selected_index() { awk '$4=="selected"{print $2}'; }

echo "== 1. Launch with 6 tabs (one pinned) (one is a single-page app that changes URL with pushState)"
launch --load-all --open-pinned=https://example.org --open=https://example.com --open=https://en.wikipedia.org/wiki/Feather --open=http://localhost:$PORT/index.html --open=http://localhost:$PORT/a.html --open=https://www.python.org
sleep 14
BEFORE=$(snapshot); echo "$BEFORE"
n=$(echo "$BEFORE" | wc -l | tr -d ' ')
check "6 tabs open" $([ "$n" = 6 ] && echo ok || echo no) "got $n"
echo "$BEFORE" | grep -q "pushed?step=2" && pushed=ok || pushed=no
check "pushState URL change was observed" $pushed "tab URL did not change; localhost http load may be blocked"

echo "$BEFORE" | sed -n 1p | grep -q "pinned=true" && pn=ok || pn=no
check "pinned tab is first in the tab order" $pn "$(echo "$BEFORE" | sed -n 1p | cut -c1-100)"
echo "$BEFORE" | grep -q "b.html" && nav=ok || nav=no
check "page A navigated to B (real history entry)" $nav "$(echo "$BEFORE" | sed -n 5p)"
echo "$BEFORE" | sed -n 5p | grep -q "back=true" && hist=ok || hist=no
check "that tab can go back before the crash" $hist "$(echo "$BEFORE" | sed -n 5p)"

echo "== 2. kill -9 two seconds after the last change (no graceful quit, no terminate notification)"
sleep 2
kill -9 "$PID"; sleep 2
pgrep -x Feather >/dev/null && check "app is dead" no "still running" || check "app is dead" ok ""
SESSION="$PROFILE_DIR/session.json"
check "session.json exists after crash" $([ -s "$SESSION" ] && echo ok || echo no) "$SESSION"
states=$(python3 -c "import json;d=json.load(open('$SESSION'));print(sum(1 for t in d['tabs'] if t.get('state')))" 2>/dev/null || echo 0)
check "back/forward state saved for tabs ($states of 6)" $([ "$states" -ge 5 ] && echo ok || echo no) "states=$states"

echo "== 3. Relaunch with NO --open arguments"
BASE=$(pgrep -f "com.apple.WebKit.WebContent" | sort | tr '\n' ' ')     # other apps' page processes: never touch these
launch
sleep 8
AFTER=$(snapshot); echo "$AFTER"
check "same tab URLs after crash" $([ "$(echo "$BEFORE" | urls)" = "$(echo "$AFTER" | urls)" ] && echo ok || echo no) "URL lists differ"
[ "$(echo "$AFTER" | grep -c "pinned=true")" = 1 ] && echo "$AFTER" | sed -n 1p | grep -q "pinned=true" && pn=ok || pn=no
check "pinned tab is still pinned, and still first, after kill -9" $pn "$(echo "$AFTER" | sed -n 1p | cut -c1-100)"
check "same tab selected" $([ "$(echo "$BEFORE" | selected_index)" = "$(echo "$AFTER" | selected_index)" ] && echo ok || echo no) "selection differs"
live=$(echo "$AFTER" | grep -c " live ")
check "only the selected tab is loaded after relaunch (lazy restore)" $([ "$live" = 1 ] && echo ok || echo no) "live=$live"

echo "== 3b. Back/forward history survives the crash (restored through WebKit's saved state)"
for i in 1 2 3 4 5; do kill -USR1 "$PID"; sleep 1; done      # each signal loads the next unloaded tab
sleep 6
HIST=$(snapshot); echo "$HIST"
echo "$HIST" | sed -n 5p | grep -q "back=true" && h=ok || h=no
check "tab with A->B history can still go back after relaunch" $h "$(echo "$HIST" | sed -n 5p)"
echo "$HIST" | sed -n 4p | grep -q "back=true" && h=ok || h=no
check "pushState tab keeps its history too" $h "$(echo "$HIST" | sed -n 4p)"

echo "== 4. Web content process killed (page crash / reclaimed by the system)"
: > "$LOG"
# only page processes that appeared after the relaunch AND belong to a process newer than the app (never other apps' existing ones)
for p in $(pgrep -f "com.apple.WebKit.WebContent"); do
  echo " $BASE " | grep -q " $p " && continue
  [ "$p" -gt "$PID" ] && kill -9 "$p"
done
sleep 5
grep -q "WEBCONTENT_TERMINATED" "$LOG" && check "app noticed the web process ending" ok "" || check "app noticed the web process ending" no "no callback"
AFTER2=$(snapshot)
check "selected tab came back (reloaded)" $(echo "$AFTER2" | grep -q " live selected " && echo ok || echo no) "$(echo "$AFTER2" | head -3)"

echo "== 5. Graceful quit (AppleScript quit = Cmd+Q) then relaunch"
osascript -e 'tell application "Feather" to quit' 2>/dev/null; sleep 3
pgrep -x Feather >/dev/null && check "app quit" no "still running" || check "app quit" ok ""
launch; sleep 6
AFTER3=$(snapshot)
check "same tab URLs after graceful quit" $([ "$(echo "$BEFORE" | urls)" = "$(echo "$AFTER3" | urls)" ] && echo ok || echo no) "URL lists differ"

echo; echo "restore test: $pass passed, $fail failed"; [ "$fail" = 0 ]
