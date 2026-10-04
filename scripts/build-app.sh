#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$#" != 0 ]]; then
  echo "Usage: $0 (builds for Apple Silicon only)" >&2
  exit 2
fi
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun swift package resolve
launchpod_sparkle=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
launchpod_sdk="$(xcrun --sdk macosx --show-sdk-path)"
launchpod_sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
launchpod_build_args=(--arch arm64 -c release --sdk "$launchpod_sdk"
  -Xlinker -platform_version -Xlinker macos -Xlinker 13.0 -Xlinker "$launchpod_sdk_version")
xcrun swift build --product Launchpod "${launchpod_build_args[@]}"
launchpod_dir="$(xcrun swift build --show-bin-path "${launchpod_build_args[@]}")"
launchpod_build_info="$(xcrun vtool -show-build "$launchpod_dir/Launchpod")"
python3 - "$launchpod_sdk_version" "$launchpod_build_info" <<'CHECK_VERSIONS'
import re, sys
canonical = lambda version: tuple(int(part) for part in version.split('.') if part)[:2]
values = dict(re.findall(r'^\s*(minos|sdk)\s+(\S+)', sys.argv[2], re.M))
assert canonical(values['minos']) == canonical('13.0'), values
assert canonical(values['sdk']) == canonical(sys.argv[1]), values
print('Verified Mach-O minimum macOS 13.0, SDK ' + values['sdk'])
CHECK_VERSIONS
mkdir -p dist/Launchpod.app/Contents/MacOS dist/Launchpod.app/Contents/Resources .build/tools
cp Resources/Info.plist dist/Launchpod.app/Contents/Info.plist
python3 scripts/configure-updates.py dist/Launchpod.app/Contents/Info.plist
ditto Resources/Licenses dist/Launchpod.app/Contents/Resources/Licenses
# ditto preserves the framework version symlinks and helper permissions.
rm -rf dist/Launchpod.app/Contents/Frameworks/Sparkle.framework
mkdir -p dist/Launchpod.app/Contents/Frameworks
ditto "$launchpod_sparkle/Sparkle.framework" dist/Launchpod.app/Contents/Frameworks/Sparkle.framework
test -d "$launchpod_dir/Sentry.framework"
rm -rf dist/Launchpod.app/Contents/Frameworks/Sentry.framework
# The selected Sentry product is static. Copy only its resources as Xcode's
# remove-static-executable embedding does; its code is already in Launchpod.
launchpod_sentry_resources="dist/Launchpod.app/Contents/Frameworks/Sentry.framework"
mkdir -p "$launchpod_sentry_resources/Versions/A"
ditto "$launchpod_dir/Sentry.framework/Versions/A/Resources" "$launchpod_sentry_resources/Versions/A/Resources"
ln -s A "$launchpod_sentry_resources/Versions/Current"
ln -s Versions/Current/Resources "$launchpod_sentry_resources/Resources"
test -f dist/Launchpod.app/Contents/Frameworks/Sentry.framework/Resources/PrivacyInfo.xcprivacy
# Keep the exact release symbols outside the distributed app for Sentry symbolication.
rm -rf dist/Launchpod.app.dSYM
ditto "$launchpod_dir/Launchpod.dSYM" dist/Launchpod.app.dSYM
cp "$launchpod_dir/Launchpod" dist/Launchpod.app/Contents/MacOS/Launchpod
for launchpod_bundle in MacAppEssentials_MacAppSettings MacAppEssentials_MacAppOnboarding Launchpod_Launchpod; do
  test -d "$launchpod_dir/$launchpod_bundle.bundle"
  ditto "$launchpod_dir/$launchpod_bundle.bundle" "dist/Launchpod.app/Contents/Resources/$launchpod_bundle.bundle"
done
python3 scripts/thin-arm64.py dist/Launchpod.app/Contents/Frameworks
# Icon Composer assets require full Xcode. Keep this override local to actool.
launchpod_icon_developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ "$launchpod_icon_developer" == /Library/Developer/CommandLineTools && -d /Applications/Xcode.app/Contents/Developer ]]; then
  launchpod_icon_developer=/Applications/Xcode.app/Contents/Developer
fi
mkdir -p .build/app-icon
DEVELOPER_DIR="$launchpod_icon_developer" xcrun actool "$PWD/Resources/launchpod.icon" \
  --compile "$PWD/.build/app-icon" --output-format human-readable-text \
  --platform macosx --minimum-deployment-target 13.0 --app-icon launchpod \
  --output-partial-info-plist "$PWD/.build/app-icon/Info.plist"
cp .build/app-icon/Assets.car dist/Launchpod.app/Contents/Resources/Assets.car
cp .build/app-icon/launchpod.icns dist/Launchpod.app/Contents/Resources/Launchpod.icns
# Compile the supplied alternate Icon Composer documents as static ICNS
# resources for the existing picker and Finder custom-icon integration.
for launchpod_icon_pair in launchpad:OriginalLaunchpad apps:MacOSApps; do
  launchpod_icon_source="${launchpod_icon_pair%%:*}"
  launchpod_icon_resource="${launchpod_icon_pair#*:}"
  launchpod_icon_output="$PWD/.build/app-icon/$launchpod_icon_source"
  mkdir -p "$launchpod_icon_output"
  DEVELOPER_DIR="$launchpod_icon_developer" xcrun actool "$PWD/Resources/$launchpod_icon_source.icon" \
    --compile "$launchpod_icon_output" --output-format human-readable-text \
    --platform macosx --minimum-deployment-target 13.0 --app-icon "$launchpod_icon_source" \
    --output-partial-info-plist "$launchpod_icon_output/Info.plist"
  cp "$launchpod_icon_output/$launchpod_icon_source.icns" \
    "dist/Launchpod.app/Contents/Resources/$launchpod_icon_resource.icns"
done
launchpod_identity="${LAUNCHPOD_SIGN_IDENTITY:--}"
launchpod_sign_options=(--force --sign "$launchpod_identity")
if [[ "$launchpod_identity" != "-" ]]; then
  launchpod_sign_options+=(--options runtime --timestamp)
fi
launchpod_framework="dist/Launchpod.app/Contents/Frameworks/Sparkle.framework"
# Sign inside out; --deep is used only for verification, never for signing.
for launchpod_component in \
  "$launchpod_framework/Versions/B/XPCServices/Downloader.xpc" \
  "$launchpod_framework/Versions/B/XPCServices/Installer.xpc" \
  "$launchpod_framework/Versions/B/Autoupdate" \
  "$launchpod_framework/Versions/B/Updater.app" \
  "$launchpod_framework" \
  "dist/Launchpod.app/Contents/Frameworks/Sentry.framework"; do
  codesign "${launchpod_sign_options[@]}" "$launchpod_component"
done
codesign "${launchpod_sign_options[@]}" \
  --identifier app.launchpod.Launchpod dist/Launchpod.app
codesign --verify --deep --strict dist/Launchpod.app
# Updating files inside an existing bundle does not invalidate Finder's icon.
# Mark the bundle itself as changed, then refresh its Launch Services record.
touch dist/Launchpod.app
launchpod_lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ -x "$launchpod_lsregister" ]]; then
  "$launchpod_lsregister" -f "$PWD/dist/Launchpod.app"
fi
ditto -c -k --keepParent dist/Launchpod.app dist/Launchpod.zip
echo "Built: dist/Launchpod.app and dist/Launchpod.zip"
