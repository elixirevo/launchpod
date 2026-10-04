#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
launchpod_check_dir="$(mktemp -d "$PWD/.build/onboarding-checks.XXXXXX")"
for launchpod_language in en ko; do
  dist/Launchpod.app/Contents/MacOS/Launchpod -MacAppLibrary.language "$launchpod_language" \
    --data-dir "$launchpod_check_dir/data" --onboarding-checks "$launchpod_check_dir/$launchpod_language"
done
echo "Onboarding screenshots: $launchpod_check_dir"
