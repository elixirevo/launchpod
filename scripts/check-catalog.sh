#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
launchpod_sdk="$(xcrun --sdk macosx --show-sdk-path)"
launchpod_dir=".build/catalog-checks/arm64"
mkdir -p "$launchpod_dir"
xcrun swiftc -sdk "$launchpod_sdk" -target arm64-apple-macosx12.0 \
  -I Sources/CSQLite -whole-module-optimization -emit-module -emit-object \
  -module-name LaunchpodCore Sources/LaunchpodCore/*.swift \
  -emit-module-path "$launchpod_dir/LaunchpodCore.swiftmodule" -o "$launchpod_dir/LaunchpodCore.o"
xcrun swiftc -sdk "$launchpod_sdk" -target arm64-apple-macosx12.0 \
  -I Sources/CSQLite -I "$launchpod_dir" tools/catalog-checks/main.swift \
  Sources/Launchpod/Catalog.swift "$launchpod_dir/LaunchpodCore.o" -o "$launchpod_dir/CatalogChecks"
"$launchpod_dir/CatalogChecks" "$@"
