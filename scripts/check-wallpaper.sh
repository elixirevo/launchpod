#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
launchpod_sdk="$(xcrun --sdk macosx --show-sdk-path)"
launchpod_dir=".build/wallpaper-checks/arm64"
mkdir -p "$launchpod_dir"
xcrun swiftc -O -sdk "$launchpod_sdk" -target arm64-apple-macosx12.0 Sources/Launchpod/WallpaperRenderer.swift tools/wallpaper-checks/main.swift -o "$launchpod_dir/WallpaperChecks"
"$launchpod_dir/WallpaperChecks" "$@"
