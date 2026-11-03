#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp/}changxing-timer-tests.XXXXXX")"
trap 'find "$test_dir" -depth -delete' EXIT
xcrun clang -g -fsanitize=address -fobjc-arc -fblocks -std=gnu17 -framework Cocoa \
  -I "$repo_dir/Packages/KYACommon/Sources/KYACommon/include" \
  -I "$repo_dir/Packages/KYAApplicationSupport/Sources/KYAApplicationSupport/include" \
  -I "$repo_dir/Packages/KYASleepWakeTimer/Sources/KYASleepWakeTimer/include" \
  "$repo_dir/Packages/KYAApplicationSupport/Sources/KYAApplicationSupport/NSUserDefaults+KYAKeys.m" \
  "$repo_dir/Packages/KYASleepWakeTimer/Sources/KYASleepWakeTimer/KYASleepWakeTimer.m" \
  "$repo_dir/Packages/KYASleepWakeTimer/Tests/Integration/timer-tests.m" \
  -o "$test_dir/timer-tests"
"$test_dir/timer-tests"
