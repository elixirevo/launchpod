#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$#" != 0 ]]; then
  echo "Usage: $0 (builds for Apple Silicon only)" >&2
  exit 2
fi
swift package resolve
launchpod_sparkle=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
launchpod_sdk="$(xcrun --sdk macosx --show-sdk-path)"
launchpod_dir=".build/manual/arm64"
mkdir -p "$launchpod_dir"
echo "Compiling Launchpod (arm64)…"
xcrun swiftc -O -sdk "$launchpod_sdk" -target arm64-apple-macosx12.0 \
  -I Sources/CSQLite -whole-module-optimization -emit-module -emit-object \
  -module-name LaunchpodCore Sources/LaunchpodCore/*.swift \
  -emit-module-path "$launchpod_dir/LaunchpodCore.swiftmodule" -o "$launchpod_dir/LaunchpodCore.o"
xcrun swiftc -O -sdk "$launchpod_sdk" -target arm64-apple-macosx12.0 \
  -I Sources/CSQLite -I "$launchpod_dir" Sources/Launchpod/*.swift \
  -F "$launchpod_sparkle" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "$launchpod_dir/LaunchpodCore.o" -o "$launchpod_dir/Launchpod"
mkdir -p dist/Launchpod.app/Contents/MacOS dist/Launchpod.app/Contents/Resources .build/tools
cp Resources/Info.plist dist/Launchpod.app/Contents/Info.plist
python3 scripts/configure-updates.py dist/Launchpod.app/Contents/Info.plist
# ditto preserves the framework version symlinks and helper permissions.
rm -rf dist/Launchpod.app/Contents/Frameworks/Sparkle.framework
mkdir -p dist/Launchpod.app/Contents/Frameworks
ditto "$launchpod_sparkle/Sparkle.framework" dist/Launchpod.app/Contents/Frameworks/Sparkle.framework
cp "$launchpod_dir/Launchpod" dist/Launchpod.app/Contents/MacOS/Launchpod
python3 scripts/thin-arm64.py dist/Launchpod.app/Contents/Frameworks
# Icon Composer assets require full Xcode. Keep this override local to actool.
launchpod_icon_developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ "$launchpod_icon_developer" == /Library/Developer/CommandLineTools && -d /Applications/Xcode.app/Contents/Developer ]]; then
  launchpod_icon_developer=/Applications/Xcode.app/Contents/Developer
fi
mkdir -p .build/app-icon
DEVELOPER_DIR="$launchpod_icon_developer" xcrun actool Resources/launchpod.icon \
  --compile .build/app-icon --output-format human-readable-text \
  --platform macosx --minimum-deployment-target 12.0 --app-icon launchpod \
  --output-partial-info-plist .build/app-icon/Info.plist
cp .build/app-icon/Assets.car dist/Launchpod.app/Contents/Resources/Assets.car
cp .build/app-icon/launchpod.icns dist/Launchpod.app/Contents/Resources/Launchpod.icns
# Compile the supplied alternate Icon Composer documents as static ICNS
# resources for the existing picker and Finder custom-icon integration.
for launchpod_icon_pair in launchpad:OriginalLaunchpad apps:MacOSApps; do
  launchpod_icon_source="${launchpod_icon_pair%%:*}"
  launchpod_icon_resource="${launchpod_icon_pair#*:}"
  launchpod_icon_output=".build/app-icon/$launchpod_icon_source"
  mkdir -p "$launchpod_icon_output"
  DEVELOPER_DIR="$launchpod_icon_developer" xcrun actool "Resources/$launchpod_icon_source.icon" \
    --compile "$launchpod_icon_output" --output-format human-readable-text \
    --platform macosx --minimum-deployment-target 12.0 --app-icon "$launchpod_icon_source" \
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
  "$launchpod_framework"; do
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
