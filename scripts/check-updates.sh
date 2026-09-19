#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift package resolve
launchpod_sparkle="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
mkdir -p .build/checks/updater
xcrun swiftc -target arm64-apple-macosx12.0 -parse-as-library -emit-module -emit-object \
  -module-name LaunchpodCore Sources/LaunchpodCore/Localization.swift \
  -emit-module-path .build/checks/updater/LaunchpodCore.swiftmodule -o .build/checks/updater/LaunchpodCore.o
xcrun swiftc -I .build/checks/updater .build/checks/updater/LaunchpodCore.o -target arm64-apple-macosx12.0 -F "$launchpod_sparkle" -framework Sparkle \
  -Xlinker -rpath -Xlinker "$launchpod_sparkle" \
  Sources/Launchpod/UpdateController.swift tools/updater-checks/main.swift \
  -o .build/checks/updater/checks
.build/checks/updater/checks
python3 - <<'PY'
import base64
import importlib.util
spec = importlib.util.spec_from_file_location("configure_updates", "scripts/configure-updates.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
key = base64.b64encode(bytes(range(32))).decode()
assert not module.configure({}, {})
info = {}
assert module.configure(info, {"LAUNCHPOD_UPDATE_FEED_URL": "https://example.com/appcast.xml", "LAUNCHPOD_UPDATE_PUBLIC_KEY": key})
assert info["SUPublicEDKey"] == key
assert module.configure(info, {})  # A checked-in public configuration is supported.
for env in [
    {"LAUNCHPOD_UPDATE_FEED_URL": "https://example.com/appcast.xml"},
    {"LAUNCHPOD_UPDATE_PUBLIC_KEY": key},
    {"LAUNCHPOD_UPDATE_FEED_URL": "http://example.com", "LAUNCHPOD_UPDATE_PUBLIC_KEY": key},
    {"LAUNCHPOD_UPDATE_FEED_URL": "https://example.com", "LAUNCHPOD_UPDATE_PUBLIC_KEY": "invalid"},
]:
    try:
        module.configure({}, env)
    except ValueError:
        pass
    else:
        raise AssertionError("Invalid release configuration was accepted")
print("PASS: build configuration injection and incomplete/invalid configuration rejection")
PY
