#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${ARCH:?}" == arm64 ]] || { echo "Only arm64 is supported" >&2; exit 2; }
: "${APP_PATH:?}"
# The pipeline applies Developer ID signing after this adapter completes.
LAUNCHPOD_SIGN_IDENTITY=- bash scripts/build-app.sh
ditto dist/Launchpod.app "$APP_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${APP_BUILD:?}" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION:?}" "$APP_PATH/Contents/Info.plist"
