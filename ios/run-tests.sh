#!/usr/bin/env bash
#
# Build and test the iOS app.
#
# Picks a simulator rather than taking one as an argument: the destination has to
# name a device that exists on this machine, and that list differs between Xcode
# versions and between a laptop and CI. ROWEL_SIM overrides when a specific
# device matters.
#
# ROWEL_DERIVED does the same for where the build and the result bundle go.
# Unset, they go where they always have — xcodebuild's own DerivedData, keyed by
# scheme name, and build/Rowel.xcresult. Set, both land under that one directory,
# which is what more than one run at a time needs: two runs of this scheme share
# a DerivedData directory by name and write the same result bundle, and the
# failures that come out of that (a test bundle vanishing mid-run, install
# failures) read as flaky infrastructure rather than as a collision. See
# AGENTS.md.

set -euo pipefail

cd "$(dirname "$0")"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is not installed. brew install xcodegen" >&2
  exit 1
fi

# The project file is generated, not committed, so a fresh clone has to make one
# before xcodebuild has anything to open.
xcodegen generate --quiet

sim="${ROWEL_SIM:-}"
if [ -z "$sim" ]; then
  # Newest available iPhone. `xcrun simctl` lists in model order within a runtime,
  # so the last available iPhone is the newest one installed.
  sim=$(xcrun simctl list devices available | grep -oE '^ +iPhone [^(]*' | sed 's/ *$//;s/^ *//' | tail -1)

  # That rule picks the same device for everyone, which is how two runs of these
  # tests came to kill each other's bundle. A device that is already booted is the
  # one visible sign of somebody else using it, so it is worth a line when the
  # choice was not made on purpose.
  if [ -n "$sim" ] && xcrun simctl list devices booted | grep -qF "    $sim ("; then
    echo "note: '$sim' is already booted — if another session is testing too, set ROWEL_SIM (see AGENTS.md)." >&2
  fi
fi
if [ -z "$sim" ]; then
  echo "No iPhone simulator is installed. Open Xcode > Settings > Components." >&2
  exit 1
fi

derived="${ROWEL_DERIVED:-}"
if [ -n "$derived" ]; then
  result="$derived/Rowel.xcresult"
  mkdir -p "$derived"
else
  result="build/Rowel.xcresult"
fi

echo "Testing on $sim"
if [ -n "$derived" ]; then
  echo "DerivedData and result bundle: $derived"
fi

# xcodebuild refuses to start if the result bundle already exists, which turns
# every second run into a failure that looks like a test failure and is not.
rm -rf "$result"

xcodebuild_args=(
  -project Rowel.xcodeproj
  -scheme Rowel
  -destination "platform=iOS Simulator,name=$sim"
  -resultBundlePath "$result"
)
if [ -n "$derived" ]; then
  xcodebuild_args+=(-derivedDataPath "$derived")
fi

# xcbeautify is nice to have and not worth a hard dependency; without it the raw
# log is still readable, just long.
if command -v xcbeautify >/dev/null 2>&1; then
  set -o pipefail
  xcodebuild "${xcodebuild_args[@]}" test | xcbeautify
else
  xcodebuild "${xcodebuild_args[@]}" test
fi
