#!/bin/bash
set -euo pipefail

major="${1:-}"
if [[ "$major" != "18" && "$major" != "26" ]]; then
  echo "Usage: bash Scripts/test-ios.sh 18|26" >&2
  exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p TestResults
run_dir="$(mktemp -d "$root/TestResults/iOS${major}.XXXXXX")"
xcrun simctl list devices available --json > "$run_dir/devices.json"
udid="$(python3 - "$major" "$run_dir/devices.json" <<'PY'
import json
import sys

major, filename = sys.argv[1:]
with open(filename, encoding="utf-8") as source:
    inventory = json.load(source)
candidates = []
for runtime, devices in inventory["devices"].items():
    marker = ".SimRuntime.iOS-"
    if marker not in runtime:
        continue
    version = tuple(int(part) for part in runtime.split(marker)[1].split("-"))
    if str(version[0]) != major:
        continue
    for device in devices:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            candidates.append((version, device["state"] == "Booted", device["name"], device["udid"]))
if not candidates:
    raise SystemExit(f"No available iPhone simulator for iOS {major}. Install its runtime in Xcode first.")
print(sorted(candidates, reverse=True)[0][3])
PY
)"

echo "Testing HTTPKit on iOS $major, simulator $udid"
xcodebuild -version
xcodebuild test \
  -scheme HTTPKit-Package \
  -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$root/.build/xcode-ios${major}" \
  -resultBundlePath "$run_dir/Results.xcresult" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee "$run_dir/xcodebuild.log"
echo "Results: $run_dir/Results.xcresult"
