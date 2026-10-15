#!/bin/bash
set -euo pipefail
relay_project_dir="$(cd "$(dirname "$0")/.." && pwd)"
xcodebuild -project "$relay_project_dir/Relay.xcodeproj" \
  -scheme Relay -configuration Release \
  -derivedDataPath "$relay_project_dir/build" \
  ONLY_ACTIVE_ARCH=YES build
printf '\nBuilt app: %s\n' "$relay_project_dir/build/Build/Products/Release/Relay.app"
