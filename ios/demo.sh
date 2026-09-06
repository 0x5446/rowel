#!/usr/bin/env bash
#
# Record the launch demo: an agent stopped on a permission request, and a
# person unblocking it from a phone.
#
# The "phone" is the simulator, which `simctl` records directly — no camera and
# no physical device, so a take is repeatable. Nothing here is staged: the
# approval is a real one, provoked by running the session under a `read-only`
# sandbox so the agent's first write is refused and it has to ask.
#
# `--mac` also records the harness's own window, through
# `Tools/RecordWindow.swift`. That is a window capture, not a screen capture,
# and the distinction is the whole reason it exists: an earlier attempt cropped
# a rectangle of the display, and a rectangle holds whatever is in front of it
# — two takes came back containing windows belonging to whoever ran the script,
# one of them a private conversation. ScreenCaptureKit captures the window's
# own contents, so nothing that happens to be on top can get in.
#
# It is off by default because it is not yet worth much: the harness's web UI
# has no per-session URL, so the window cannot be pointed at the conversation
# being approved without driving the browser, and a Mac half showing the home
# screen adds nothing the phone does not already say.
#
# Usage:
#   ios/demo.sh              set up an approval, record the phone
#   ios/demo.sh --mac        record the harness window as well
#   ios/demo.sh --arm        set up the approval and stop, to record by hand
#
# Output: marketing/video/raw/phone.mov, ready for the Remotion edit.
#
# Requires the screenshot harness (ios/screenshots.sh) to be up: this borrows
# its dsh, its Bridle and its sample repository rather than standing up a
# second one.

set -euo pipefail

cd "$(dirname "$0")"
root="$(cd .. && pwd)"
home="${ROWEL_SHOTS_HOME:-$HOME/rowel-shots}"
port="${ROWEL_SHOTS_PORT:-3082}"
device="${ROWEL_SHOTS_DEVICE:-iPhone 17 Pro Max}"
# Under /Users/Shared, not under anybody's home. The path is *visible in the
# product*: the session list, the conversation header and the transcript all
# print the working directory, so a fixture under $HOME publishes the
# operator's username in every screenshot and every frame of the demo video —
# which it did, six times over, on the store listing.
sample="/Users/Shared/code/checkout-api"
out="$root/marketing/video/raw"


if [ -t 1 ]; then bold=$(printf '\033[1m'); off=$(printf '\033[0m'); else bold=''; off=''; fi
say() { printf '%s==>%s %s\n' "$bold" "$off" "$*"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }

curl -s -o /dev/null -m 2 "http://127.0.0.1:$port/" \
  || fail "no harness on :$port — run ios/screenshots.sh first."

# Recorders are started in the background, and `set -e` can end this script
# between starting one and stopping it — a failed build, a simulator that will
# not boot. What is left behind then is a process quietly filming an idle
# screen until somebody notices, so the exit path collects them whatever the
# reason for leaving.
recorders=()
cleanup() {
  local pid
  for pid in "${recorders[@]:-}"; do
    [ -n "$pid" ] && kill -INT "$pid" 2>/dev/null
  done
}
trap cleanup EXIT INT TERM

rpc() {
  printf '{"type":"client-request","rpcId":"d%s","method":"%s","payload":%s}' \
    "$RANDOM" "$1" "$2" \
    | curl -s -m 90 -X POST "http://127.0.0.1:$port/api/$1" \
        -H 'content-type: application/json' --data-binary @-
}

zone() {
  local link
  link=$(readlink /etc/localtime 2>/dev/null)
  case "$link" in
    */zoneinfo/*) printf '%s' "${link#*/zoneinfo/}" ;;
    *) printf 'UTC' ;;
  esac
}

# --- An agent that is actually stuck -----------------------------------------

# Provoked by the sandbox, not by a prompt asking it to pause.
#
# Asking an agent to "stop and ask" produces a sentence; a permission request
# is a different thing — the run is suspended and the harness is holding the
# tool call. Only the second one is what the app is for, and the only reliable
# way to cause it is to deny the write: under `read-only` the first attempt is
# refused, and escalating needs consent.
arm() {
  say "arming an approval"
  # Take the file away first. The last take answered Allow, so the file it
  # asked to create exists — and an agent asked to create something that is
  # already there reads it and reports, which needs no permission and produces
  # no card. The approval has to be provoked by real work, so the work has to
  # be real.
  rm -f "$sample/CHANGELOG.md"
  python3 - "$port" "$(zone)" "$sample" <<'PY'
import json, sys, time, urllib.request

port, zone, sample = sys.argv[1], sys.argv[2], sys.argv[3]

def call(method, payload):
    body = json.dumps({"type": "client-request", "rpcId": "arm",
                       "method": method, "payload": payload}).encode()
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/api/{method}", data=body,
        headers={"content-type": "application/json"})
    with urllib.request.urlopen(request, timeout=90) as answer:
        return json.load(answer)

def preset(value):
    described = call("settings.describe", {})
    namespaces = described["result"]["value"]["namespaces"]
    revision = next((n.get("revision") for n in namespaces if n.get("ns") == "permission"), None)
    call("settings.update", {"ns": "permission", "patch": {"defaultPreset": value},
                             "expectedRevision": revision})

# Retire any earlier take, so the list shows one of these and not four.
for session in call("session.list", {})["result"]["value"]["items"]:
    if session.get("projections", {}).get("values", {}).get("title") == "Ship the currency fix":
        call("workspace.archiveSession", {"sessionId": session["sessionId"]})

# The preset is read when the session is created, so it has to be set first and
# put back afterwards — it is machine-wide, and leaving a harness read-only
# would be a confusing thing to find later.
preset("read-only")
try:
    session = call("session.create", {"cwd": sample})["result"]["value"]["sessionId"]
    answer = call("session.prompt", {
        "sessionId": session, "mode": "queue", "clientTimeZone": zone,
        "content": [{"type": "text", "text":
            'Add a CHANGELOG.md to this repository with one entry: '
            '"Add CAD and AUD support". Write the file.'}],
    })
    if not answer["result"].get("value", {}).get("accepted"):
        raise SystemExit(f"the harness refused the prompt: {json.dumps(answer)[:300]}")
    time.sleep(1.5)
    call("session.rename", {"sessionId": session, "title": "Ship the currency fix"})
finally:
    preset("workspace-write")

# Wait for the agent to actually reach the question. Recording before it does
# would capture a spinner and call it a demo.
for _ in range(60):
    time.sleep(2)
    page = call("session.history", {"sessionId": session, "maxMessages": 8})
    events = page["result"]["value"]["events"]
    if any(e.get("event", {}).get("type") == "approval/asked" for e in events):
        print("approval pending")
        break
else:
    raise SystemExit("the agent never asked for permission")
PY
}

# --- Both screens ------------------------------------------------------------

record() {
  local udid
  udid=$(xcrun simctl list devices available | grep -m1 "$device (" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
  [ -n "$udid" ] || fail "no simulator called '$device'."
  xcrun simctl boot "$udid" 2>/dev/null || true
  open -a Simulator
  # Regenerate first. The project file is not committed, so a driver added
  # since the last generate is not in the scheme — and `-only-testing` against
  # a test that does not exist fails in a way that still leaves two recordings
  # on disk, of a home screen.
  xcodegen generate --spec project.yml >/dev/null
  # A test runner left over from before the rename sits on the home screen and
  # ends up in the shot.
  xcrun simctl uninstall "$udid" ai.novabox.reins.uitests.xctrunner 2>/dev/null || true
  mkdir -p "$out"
  rm -f "$out/phone.mov" "$out/mac.mov"

  # A window of its own for the harness, when the Mac half was asked for.
  # Sized here because a window capture records the window at its own size, so
  # a small window makes a small recording. Where it sits does not matter —
  # that is the point of capturing a window rather than a rectangle.
  if [ "$want_mac" = 1 ]; then
    # Close any harness windows left by an earlier take first. The recorder
    # refuses when more than one window matches — correctly, since picking one
    # of several is how you film the wrong thing — so leaving them around makes
    # the second run of the day fail on the first.
    osascript -e "tell application \"Google Chrome\" to close (every window whose title contains \"DeepSeek Harness\")" \
      >/dev/null 2>&1 || true
    osascript -e "tell application \"Google Chrome\" to make new window" \
      -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"http://127.0.0.1:$port/\"" \
      -e "tell application \"Google Chrome\" to set bounds of front window to {0, 60, 1200, 860}" \
      >/dev/null 2>&1 || true
    sleep 4
  fi

  # Compile before the camera rolls. `xcodebuild test` builds first, and a
  # build after a source change takes minutes — all of it recorded, and all of
  # it a still simulator. Worse, the app then has to launch, pair and load a
  # list inside a patience window that was spent waiting for the compiler: one
  # take failed outright that way and produced 176 seconds of footage with 115
  # seconds of nothing at the front.
  say "building"
  xcodebuild build-for-testing -project Rowel.xcodeproj -scheme RowelUI \
    -destination "id=$udid" -derivedDataPath build/demo >/dev/null 2>&1 \
    || fail "the test bundle would not build"

  say "recording"
  rm -f "$out/beats.json"
  # The phone on the home screen, so the notification has somewhere to land.
  xcrun simctl terminate "$udid" ai.novabox.rowel >/dev/null 2>&1 || true
  xcrun simctl io "$udid" recordVideo --codec h264 --force "$out/phone.mov" &
  local phone_pid=$!
  recorders+=("$phone_pid")
  local mac_pid=""
  if [ "$want_mac" = 1 ]; then
    swift Tools/RecordWindow.swift --app "Google Chrome" --title "DeepSeek Harness" \
      --seconds 60 --out "$out/mac.mov" &
    mac_pid=$!
    recorders+=("$mac_pid")
  fi
  # When the footage starts, so the driver's marks can be turned into offsets
  # into it. Without this the edit has to find the beats by eye, which means
  # re-timing every caption after every take — and the point of driving this
  # from a script is that a take is cheap.
  local started
  started=$(python3 -c 'import time; print(time.time())')
  sleep 2

  # The first beat: how a person finds out at all.
  #
  # The payload is the one `relay-worker/src/apns.ts` sends, word for word —
  # the relay's push is content-free by design, so there is nothing here that a
  # real one would say differently. Delivered locally because a simulator has
  # no APNs token; the notification itself is iOS drawing a real notification.
  local notified=""
  cat > "$out/wake.json" <<JSON
{
  "aps": {
    "alert": { "title": "Rowel", "body": "Your agent is waiting on you. · MacBook Pro" },
    "sound": "default",
    "interruption-level": "time-sensitive"
  }
}
JSON
  if xcrun simctl push "$udid" ai.novabox.rowel "$out/wake.json" >/dev/null 2>&1; then
    notified=$(python3 -c 'import time; print(time.time())')
    say "notification delivered"
    sleep 4
  else
    say "the simulator would not take the notification — the shot starts at the list"
  fi

  local link
  link=$(ROWEL_HOME="$home/rowel-home" node "$root/bridle/lib/cli.js" pair --link 2>/dev/null \
    | sed -n 's/^link: *//p')
  [ -n "$link" ] || fail "could not mint a pairing invitation"

  # `pipefail` so a build that never ran the test is not reported as success
  # by the grep at the end of the pipe. That is how the first take produced
  # eighteen seconds of a home screen and said nothing was wrong.
  set +e
  set -o pipefail
  TEST_RUNNER_ROWEL_PAIR_LINK="$link" TEST_RUNNER_ROWEL_SHOTS_OUT="$out" \
    xcodebuild test-without-building \
    -project Rowel.xcodeproj -scheme RowelUI -destination "id=$udid" \
    -derivedDataPath build/demo \
    -only-testing:RowelUITests/Demo 2>&1 | grep -E "Test Case|error:"
  local status=$?
  set +o pipefail
  set -e

  # SIGINT rather than SIGTERM: both writers finalise the container on
  # interrupt and truncate on terminate, and a truncated .mov is unplayable
  # rather than short.
  kill -INT "$phone_pid" 2>/dev/null || true
  wait "$phone_pid" 2>/dev/null || true
  # Waited on rather than killed. A window recording is finalised when the
  # writer closes the file; end the process before that and what is left is a
  # megabyte of frames with no index — `moov atom not found`, which reads like
  # a corrupt file rather than an interrupted one. The extra seconds are tail
  # the edit trims anyway.
  if [ -n "$mac_pid" ]; then
    say "waiting for the window recording to close its file"
    wait "$mac_pid" 2>/dev/null || true
  fi

  [ -s "$out/phone.mov" ] || fail "the simulator recording is empty"
  if [ -s "$out/beats.json" ]; then
    python3 "$root/marketing/video/beats.py" "$out/beats.json" "$started" "$notified"
    say "beats (seconds into phone.mov):"
    sed 's/^/    /' "$out/beats.json"
  fi
  say "raw footage in marketing/video/raw"
  for f in "$out"/*.mov; do
    [ -e "$f" ] || continue
    printf '    %-10s %s  %ss\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)" \
      "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null | cut -d. -f1)"
  done
  return $status
}

want_mac=0
case "${1:-}" in
  --arm) arm; exit 0 ;;
  --mac) want_mac=1 ;;
esac
arm
record
