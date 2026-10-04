#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
launchpod_check_dir="$(mktemp -d "$PWD/.build/settings-behavior-checks.XXXXXX")"
dist/Launchpod.app/Contents/MacOS/Launchpod --data-dir "$launchpod_check_dir/data" \
  --settings-behavior-checks "$launchpod_check_dir/results"
echo "Settings behavior checks: $launchpod_check_dir"
