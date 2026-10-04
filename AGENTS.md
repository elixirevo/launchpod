# Launchpod

- The app is an AppKit launcher with a SwiftUI settings window, built with SwiftPM and packaged by `scripts/build-app.sh`.
- Minimum deployment target is macOS 13, Apple Silicon. Keep Package.swift, Info.plist, packaging and Homebrew requirements aligned.
- Before connecting or updating MacAppEssentials, read `../../tools/library/docs/agent-integration.md`, `docs/settings-configuration.md`, and `docs/integration.md` (all relative to that library checkout).
- General contains shared settings. App-specific settings belong in the second, Features (기능) page. Gesture/hot-corner triggers use shortcutsContent on the common shortcuts page. Shortcuts and permissions use the library’s dedicated built-in pages; do not recreate their recorder or permission alerts.
- Terms and privacy policy are app-owned English/Korean resources under `Sources/Launchpod/Resources/Legal`. Present them as read-only sheets in Settings > Help & Support through `supportContent`; do not add document-specific settings pages. If published URLs become available, use `SupportLegalLinks` on the same support model/page.
- Reading/copying/saving legal documents in Settings does not record consent. Do not add placeholder identities, addresses or unverified privacy claims.
- Preserve existing preference keys and layout data. Common language settings use MacAppCore and apply after restart; migrate the legacy `appLanguage` before using `AppLocalizer.current`.
- Build the complete app with `scripts/build-app.sh`; verify settings with `scripts/check-languages.sh` and core behavior with `scripts/check.sh`. GUI checks require an isolated `--data-dir`.

- Sentry integration follows `../../tools/library/docs/sentry-setup.md` and `docs/service-integrations.md`. Use the shared developer profile/setup tool for project/DSN configuration; never print or bundle the management token. Keep the app-lifetime service, bundled public configuration and General consent UI connected. Reporting defaults off and changes apply on restart; checks/preview runs never initialize the SDK. Do not trigger real crashes or telemetry in automated checks.

- Onboarding uses `MacAppOnboarding` and `../../tools/library/docs/onboarding-integration.md`. Use the versioned TermsAgreementModel shared by AppStartup and onboarding. Save onboarding completion only on Finish; save agreement only on the explicit Agree action. Preserve both records when restoring preferences. Keep app-specific flow version separate from release/legal versions. Do not restore automatic startup permission alerts. Verify with `scripts/check-onboarding.sh`; interactive `--preview-onboarding` requires an isolated `--data-dir` and uses fake permissions/no telemetry.

- MacAppEssentials 0.4.0: read `../../tools/library/docs/terms-agreement-integration.md`. Never infer acceptance from an old onboarding record. Keep the launcher/catalog, global input, updater and diagnostics SDK stopped until required terms are accepted and optional setup finishes/is deferred. Existing completed users get the standalone terms window. Resource/read/write failures fail closed; quitting never records acceptance. Keep the prior legal documents in docs/legal/archive and bump the independent terms version for changed terms.

- MacAppEssentials 0.5.0: connect SupportSettingsModel.showOnboarding to the retained onboarding host’s showForReview(). Never clear completion or consent for review, or attach feature startup callbacks to the review window. Keep onboarding and terms versions unchanged for presentation-only updates.

- Follow the package’s Features-tab convention: title Features/기능, symbol `display`, color RGB(0.30, 0.68, 0.94). Retain the existing custom `launchpod` page ID and its second position.
