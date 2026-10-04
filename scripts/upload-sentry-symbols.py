#!/usr/bin/env python3
"""Upload only this app's matching dSYM; never print or bundle management credentials."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def uuids(path):
    result = subprocess.run(["/usr/bin/xcrun", "dwarfdump", "--uuid", str(path)],
                            check=True, capture_output=True, text=True)
    values = set(re.findall(r"UUID: ([0-9A-F-]+) \(([^)]+)\)", result.stdout))
    if not values:
        raise ValueError("No debug UUID found")
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "dist/Launchpod.app")
    parser.add_argument("--dsym", type=Path, default=ROOT / "dist/Launchpod.app.dSYM")
    parser.add_argument("--apply", action="store_true", help="Upload the verified symbols to the configured Sentry project")
    args = parser.parse_args()
    info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
    config_paths = list((args.app / "Contents/Resources/Launchpod_Launchpod.bundle").rglob("SentryConfiguration.json"))
    if len(config_paths) != 1:
        raise ValueError("Expected one bundled Sentry configuration")
    config = json.loads(config_paths[0].read_text())
    if info["CFBundleIdentifier"] != config["appIdentifier"]:
        raise ValueError("App and Sentry configuration identifiers differ")
    binary = args.app / "Contents/MacOS" / info["CFBundleExecutable"]
    identifiers = uuids(binary)
    if identifiers != uuids(args.dsym):
        raise ValueError("The dSYM does not match the app executable")
    print("Verified matching app/dSYM UUIDs: " + ", ".join(v[0] for v in sorted(identifiers)), flush=True)
    if not args.apply:
        print("Plan: upload only this dSYM to project " + config["project"] + ". Use --apply to upload.")
        return
    cli = shutil.which("sentry-cli")
    if not cli:
        raise ValueError("Install Sentry CLI in the release environment before uploading")
    # Reuse the library's validated developer profile and credential loader.
    spec = importlib.util.spec_from_file_location("sentry_setup", ROOT / "../../tools/library/scripts/sentry-setup.py")
    setup = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(setup)
    try:
        profile = setup.validate_profile(setup.read_json(setup.PROFILE))
    except setup.SetupError as error:
        raise ValueError(str(error)) from None
    if profile["organization"] != config["organization"]:
        raise ValueError("Developer profile organization differs from the bundled app configuration")
    organization = setup.slug(config["organization"])
    project = setup.slug(config["project"])
    try:
        token = setup.token_from_keychain(profile["keychainService"], profile["keychainAccount"])
    except setup.SetupError as error:
        raise ValueError(str(error)) from None
    env = dict(os.environ, SENTRY_AUTH_TOKEN=token, SENTRY_LOG_LEVEL="error")
    result = subprocess.run([cli, "--url", profile["apiBase"].removesuffix("api/0/"),
        "debug-files", "upload", "--org", organization, "--project", project,
        "--type", "dsym", "--no-sources", "--no-zips", "--wait-for", "45", str(args.dsym)],
        env=env, capture_output=True, text=True)
    if result.returncode:
        # Do not forward CLI output that could contain credentials from local configuration.
        raise ValueError("Sentry symbol upload failed. Check project access and debug-file upload permissions in the release environment.")
    print("Sentry accepted and processed the matching Launchpod dSYM. No crash event was sent.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
