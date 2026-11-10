#!/bin/bash
# Re-renders the README images into docs/images: the app icon, and the main window, drop view and
# Settings in light and dark mode. Uses made-up sample notes; your Keychain and notes folder aren't read.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build docs/images
swift scripts/make-icon.swift build/icon-1024.png
sips -z 256 256 build/icon-1024.png --out docs/images/icon.png >/dev/null

swift build --product VoiceNoteTranscriber
"$(swift build --show-bin-path)/VoiceNoteTranscriber" --render-snapshots docs/images
