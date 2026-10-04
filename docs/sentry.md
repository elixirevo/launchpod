# Sentry maintenance

Launchpod uses the local `MacAppDiagnosticsSentry` integration, currently pinned to Sentry Cocoa 9.30.0. `AppDiagnostics` loads the public app-owned `SentryConfiguration.json` from the SwiftPM resource bundle and retains one service for the process lifetime. App identifier, version and build come from the executable app's Info.plist. Public configuration is prepared before onboarding, but the SDK starts only after required terms acceptance and optional setup completion/deferral. The reporting preference is captured at process launch, so opting in during onboarding still requires restart. Initialization/configuration errors leave the launcher usable and display an unavailable message in General.

Consent is stored as `MacAppLibrary.crashReportingEnabled`, defaults to false, and is shared between onboarding and the library's `DiagnosticsSettingsSection` in General. Finishing onboarding does not change this choice. Changes apply on the next launch. No SDK initialization occurs in an opted-out launch or in a `--data-dir` / `--preview-output` run. Do not add separate Sentry initialization, tracking, attachments or personal data to the SDK.

The Sentry `launchpod` project and public DSN were provisioned through the library setup tool. The SDK only sends fatal events with exception data under the library's crash-only policy. See the bundled Privacy Policy for processing and cache behavior; consent withdrawal requires restart, and older queued reports may be sent if consent is restored.

To inspect/reconfigure the connection, use `../../tools/library/scripts/sentry-setup.py doctor` and `provision` as described in that library's `docs/sentry-setup.md`. Management credentials are read internally from the developer keychain or CI's `SENTRY_AUTH_TOKEN`; do not print them or add them to app resources.

`build-app.sh` links Sentry statically, embeds and signs its resource-only framework with the original privacy manifest, includes its licenses, and preserves the matching release symbols in `dist/Launchpod.app.dSYM`. Archive that dSYM with every release. With Sentry CLI installed, use the upload helper. It verifies the app/dSYM UUIDs and bundled app identifier before reading the developer profile or credentials. Without `--apply` it only prints a plan:

```sh
python3 scripts/upload-sentry-symbols.py
python3 scripts/upload-sentry-symbols.py --apply
```

The helper reads the same developer keychain as the setup tool; in CI supply `SENTRY_AUTH_TOKEN` as a secret, with permissions for debug-symbol upload. It uploads only the selected dSYM, without source bundles. Use `--app` and `--dsym` for release-pipeline output paths. Project setup credentials and symbol-upload permissions are separate concerns. Do not upload unrelated symbols or run crash tests against production automatically.

Validation: build the app, run `scripts/check-service-settings.sh` and `scripts/check-languages.sh`. The service checks use isolated preferences and fake shortcut/permission boundaries; they load the real bundled public configuration but never send events or install a global shortcut. The shared module's own tests cover the SDK option policy and startup consent gate. Actual cloud crash reception and server-side symbolication require a separate development-project test (without a debugger), crash/relaunch, and verification in Sentry; project creation and symbol upload do not verify actual crash reception. The current local build’s matching dSYM was uploaded successfully on 2026-10-05.

Static SDK resource packaging follows [Apple’s privacy manifest placement](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk). The original SDK manifest describes its available capabilities; the app restricts actual runtime collection to the policy above.
