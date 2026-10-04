#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
launchpod_check_dir="$(mktemp -d "$PWD/.build/service-settings-checks.XXXXXX")"
dist/Launchpod.app/Contents/MacOS/Launchpod --data-dir "$launchpod_check_dir/data" \
  --service-settings-checks "$launchpod_check_dir/services"
dist/Launchpod.app/Contents/MacOS/Launchpod --data-dir "$launchpod_check_dir/data" \
  --startup-permission-checks "$launchpod_check_dir/permissions"
echo "Service settings checks: $launchpod_check_dir"
