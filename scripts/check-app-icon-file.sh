#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/app-icon-file-checks
xcrun swiftc -target arm64-apple-macosx12.0 -parse-as-library -emit-module -emit-object \
  -module-name LaunchpodCore Sources/LaunchpodCore/Localization.swift \
  -emit-module-path .build/app-icon-file-checks/LaunchpodCore.swiftmodule -o .build/app-icon-file-checks/LaunchpodCore.o
xcrun swiftc -target arm64-apple-macosx12.0 -I .build/app-icon-file-checks .build/app-icon-file-checks/LaunchpodCore.o Sources/Launchpod/AppIconSettings.swift tools/app-icon-file-checks/main.swift \
  -o .build/app-icon-file-checks/FileIconChecks
.build/app-icon-file-checks/FileIconChecks "$PWD/dist/Launchpod.app"
