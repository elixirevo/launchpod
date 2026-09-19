# Releasing Launchpod

The release pipeline in `scripts/deploy` is adapted from the shared
`mac-apps/tools/deploy` pipeline, with configurable Apple Silicon-only output.
The shared tools and other apps are not modified. `deploy.json` selects arm64;
embedded Sparkle executables are also thinned to arm64 before signing.

## Requirements

- macOS, full Xcode (including Icon Composer support), Python 3.9+, Git, GitHub CLI, and Homebrew.
- Developer ID Application certificate and private key in Keychain.
- An authenticated `gh` account with push access to `elixirevo/launchpod` and `elixirevo/homebrew-tap`.
- The Homebrew tap checkout at `../../tools/homebrew-tap`, or a custom `tap_path` in the deployment config.
- The existing `menubox` notarytool Keychain profile for the same Apple developer account. Override with `NOTARY_PROFILE` when using another profile; its name does not constrain the app being notarized.
- Sparkle keychain account `launchpod`. The public key is checked into `Resources/Info.plist`; the private key stays in Keychain. Preserve this key for future updates.

`SIGN_IDENTITY`, `NOTARY_PROFILE`, and `SPARKLE_KEY_ACCOUNT` can override the config.
Do not commit private keys, passwords, or exported signing credentials.

## Prepare and publish

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in `Resources/Info.plist`.
2. Write `docs/releases/<version>.md` and update public documentation as needed.
3. Run the checks and prepare the signed artifacts:

   ```sh
   python3 -m unittest discover -s scripts/deploy/tests -v
   bash scripts/check.sh
   bash scripts/check-updates.sh
   python3 scripts/deploy/release.py . plan
   python3 scripts/deploy/release.py . prepare
   ```

4. Review and commit the release source changes, then publish:

   ```sh
   python3 scripts/deploy/release.py . publish
   ```

Preparation builds the app, signs all nested components with hardened runtime,
notarizes and staples the app and DMG, signs the Sparkle appcast and update,
and validates the mounted DMG. Publication pushes the source and version tag,
checks uploaded bytes before making the GitHub Release public, and audits,
commits, and pushes the generated cask to the tap.

Artifacts and resumable receipts are under `dist/deploy/<version>/`. The DMG,
`appcast.xml`, and `SHA256SUMS.txt` are uploaded. The appcast points to the
versioned DMG and is served through GitHub's latest-release download URL.
Source/configuration changes invalidate preparation. Existing releases are
never overwritten. Retry a failed stage by its name (for example `homebrew`).

The default `scripts/build-app.sh` is an ad-hoc signed development build.
Use the deployment pipeline for distributable, notarized builds.
