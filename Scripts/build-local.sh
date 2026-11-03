#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${1:-$repo_dir/dist}"
mkdir -p "$output_dir"
xcodebuild -workspace "$repo_dir/KeepingYouAwake.xcworkspace" \
  -scheme KeepingYouAwake -configuration Release \
  -derivedDataPath "$repo_dir/build" -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  OTHER_CODE_SIGN_FLAGS=--timestamp=none build
source_app="$repo_dir/build/Build/Products/Release/KeepingYouAwake.app"
# A distinct distribution name prevents confusing this fork with upstream.
ditto "$source_app" "$output_dir/Changxing.app"
codesign --verify --deep --strict "$output_dir/Changxing.app"
ditto -c -k --sequesterRsrc --keepParent "$output_dir/Changxing.app" "$output_dir/Changxing-1.7.0-macOS.zip"
(cd "$output_dir" && shasum -a 256 Changxing-1.7.0-macOS.zip) > "$output_dir/SHA256SUMS"
