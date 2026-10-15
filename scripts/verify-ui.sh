#!/bin/bash
set -euo pipefail
relay_project_dir="$(cd "$(dirname "$0")/.." && pwd)"
relay_qa_dir="$relay_project_dir/build/ui-verification"
relay_sdk="$(xcrun --sdk macosx --show-sdk-path)"
relay_arch="$(uname -m)"
mkdir -p "$relay_qa_dir"

"$relay_project_dir/scripts/build.sh"
relay_media="$relay_qa_dir/synthetic-$(uuidgen).mp4"
"$relay_project_dir/build/Build/Products/Release/Relay.app/Contents/MacOS/Relay" --smoke-test "$relay_media"

relay_ui_sources=(
  "$relay_project_dir/Relay/CaptureModels.swift"
  "$relay_project_dir/Relay/RecordingWriter.swift"
  "$relay_project_dir/Relay/CaptureController.swift"
  "$relay_project_dir/Relay/LibraryStore.swift"
  "$relay_project_dir/Relay/Overlays.swift"
  "$relay_project_dir/Relay/StudioView.swift"
)
for relay_test in PlaybackQA OverlayQA; do
  xcrun swiftc -swift-version 5 -target "$relay_arch-apple-macosx15.0" -sdk "$relay_sdk" \
    "${relay_ui_sources[@]}" "$relay_project_dir/Tests/$relay_test.swift" -o "$relay_qa_dir/$relay_test"
done
"$relay_qa_dir/PlaybackQA" "$relay_media" "$relay_qa_dir"
"$relay_qa_dir/OverlayQA" "$relay_qa_dir"
