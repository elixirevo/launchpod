#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/dock-shortcut-checks
xcrun swiftc Sources/Launchpod/DockShortcut.swift tools/dock-shortcut-checks/main.swift \
  -o .build/dock-shortcut-checks/DockShortcutChecks
.build/dock-shortcut-checks/DockShortcutChecks
