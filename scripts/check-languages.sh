#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Run after scripts/build-app.sh. Layout and language preferences are isolated.
launchpod_check_dir="$(mktemp -d "$PWD/.build/language-checks.XXXXXX")"
dist/Launchpod.app/Contents/MacOS/Launchpod \
  --data-dir "$launchpod_check_dir/data" --language-checks "$launchpod_check_dir"
echo "Language screenshots: $launchpod_check_dir"
