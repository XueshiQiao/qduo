#!/usr/bin/env bash
# Build main as Release, signed with the team's Apple Development certificate, into
# build/promo-rel. Used only for recording; nothing is installed.
set -euo pipefail
cd "$(dirname "$0")/../../.."
xcodebuild -project QDuo.xcodeproj -scheme QDuo -configuration Release -derivedDataPath build/promo-rel \
  -destination 'platform=macOS' -allowProvisioningUpdates build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
