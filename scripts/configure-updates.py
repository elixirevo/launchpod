#!/usr/bin/env python3
"""Inject public Sparkle configuration into the build, never signing secrets."""
import base64
import os
import plistlib
import sys
from urllib.parse import urlsplit


def configure(info, env):
    feed = env.get("LAUNCHPOD_UPDATE_FEED_URL", info.get("SUFeedURL", ""))
    key = env.get("LAUNCHPOD_UPDATE_PUBLIC_KEY", info.get("SUPublicEDKey", ""))
    if not feed and not key:
        info.pop("SUFeedURL", None)
        info.pop("SUPublicEDKey", None)
        return False
    url = urlsplit(feed)
    if url.scheme != "https" or not url.hostname or url.username or url.password:
        raise ValueError("LAUNCHPOD_UPDATE_FEED_URL must be an HTTPS URL without credentials")
    if len(base64.b64decode(key, validate=True)) != 32:
        raise ValueError("LAUNCHPOD_UPDATE_PUBLIC_KEY must be a base64-encoded 32-byte Ed25519 public key")
    info["SUFeedURL"] = feed
    info["SUPublicEDKey"] = key
    return True


if __name__ == "__main__":
    path = sys.argv[1]
    with open(path, "rb") as source:
        info = plistlib.load(source)
    try:
        enabled = configure(info, os.environ)
    except (ValueError, TypeError) as error:
        sys.exit(f"Invalid Sparkle configuration: {error}")
    with open(path, "wb") as destination:
        plistlib.dump(info, destination, sort_keys=False)
    print("Sparkle: configured" if enabled else "Sparkle: disabled (no feed/public key configured)")
