#!/bin/bash
set -euo pipefail
relay_project_dir="$(cd "$(dirname "$0")/.." && pwd)"
relay_qa_dir="$relay_project_dir/build/verification"
relay_sdk="$(xcrun --sdk macosx --show-sdk-path)"
relay_arch="$(uname -m)"
mkdir -p "$relay_qa_dir"

xcrun swiftc -swift-version 5 -target "$relay_arch-apple-macosx15.0" -sdk "$relay_sdk" \
  "$relay_project_dir/Relay/CaptureModels.swift" \
  "$relay_project_dir/Relay/RecordingWriter.swift" \
  "$relay_project_dir/Tests/WriterQA.swift" -o "$relay_qa_dir/WriterQA"
"$relay_qa_dir/WriterQA" "$relay_qa_dir"

xcrun swiftc -swift-version 5 -target "$relay_arch-apple-macosx15.0" -sdk "$relay_sdk" \
  "$relay_project_dir/Relay/CaptureModels.swift" \
  "$relay_project_dir/Relay/RecordingWriter.swift" \
  "$relay_project_dir/Relay/CaptureController.swift" \
  "$relay_project_dir/Tests/CompositionQA.swift" -o "$relay_qa_dir/CompositionQA"
"$relay_qa_dir/CompositionQA" "$relay_qa_dir"

xcrun swiftc -swift-version 5 -target "$relay_arch-apple-macosx15.0" -sdk "$relay_sdk" \
  "$relay_project_dir/Relay/LibraryStore.swift" \
  "$relay_project_dir/Tests/LibrarySmoke.swift" -o "$relay_qa_dir/LibrarySmoke"
"$relay_qa_dir/LibrarySmoke"
