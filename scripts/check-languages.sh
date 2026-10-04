#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Run after scripts/build-app.sh. Layout and language preferences are isolated.
launchpod_check_dir="$(mktemp -d "$PWD/.build/language-checks.XXXXXX")"
for launchpod_language in en ko; do
  dist/Launchpod.app/Contents/MacOS/Launchpod \
    -MacAppLibrary.language "$launchpod_language" \
    --data-dir "$launchpod_check_dir/data" --language-checks "$launchpod_check_dir/$launchpod_language"
done
echo "Language screenshots: $launchpod_check_dir"
