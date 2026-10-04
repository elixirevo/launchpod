# Launchpod legal documents

The app owns the English and Korean Markdown documents in `Sources/Launchpod/Resources/Legal`. They adapt the terms (13 sections) and privacy (12 sections) templates in `../../tools/library/docs/legal`, version 1.3 dated 2026-10-05, for the current free, direct-distribution app. The support address supplied by the owner is `elixirevo@gmail.com`.

MacAppEssentials GPL-3.0-only, Sentry and Sparkle license notices are retained in `Resources/Licenses` and copied into the app bundle.

Onboarding shows versioned terms with a checkbox and explicit Agree action. AppStartup shares its TermsAgreementModel/store with the standalone update window. Only successful explicit agreement stores the local document ID/version/language/text hash/time; only Finish stores onboarding completion. Neither grants OS permissions or opts into crash reporting. Previous 1.2 documents are preserved under archive/1.2.

The documents open offline in Settings > Help & Support, can be copied or saved, and do not create acceptance records. There are no document-specific sidebar pages. They are bundled through SwiftPM and copied into the signed app by `build-app.sh`.

The implementation was checked for app discovery, layout/backup persistence, icon caching, wallpaper, gestures, Dock integration, settings, Sparkle and support links. Optional Sentry crash reporting is integrated through MacAppDiagnosticsSentry; default consent is off and changes require restart. The launchpod project uses the US region, default server-side sensitive-data filtering is enabled, and IP scrubbing is not enabled (verified 2026-10-04). Exact server retention has not been confirmed. Payments, remote user accounts and usage analytics are not present. Sparkle's optional system profile is explicitly disabled; ordinary HTTPS update requests still reach GitHub.

The operator is identified only by the verified project account and supplied email. A legal name, business address, business-registration status, support-mail retention schedule and provider-specific transfer arrangements have not been supplied. No identity, address, legal jurisdiction, fixed server-log lifetime or universal compliance claim has been invented. Confirm these operational details before public distribution if they are required for the operator's circumstances. Keep old released documents and update both languages when behavior changes.

References checked on 2026-10-04:

- [Library template guidance](../../../../tools/library/docs/legal/README.md)
- [GitHub privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement)
- [Google privacy policy](https://policies.google.com/privacy)
- [Sentry privacy policy](https://sentry.io/privacy/)
- [Sentry integration and collection contract](../../../../tools/library/docs/service-integrations.md)
- [Sparkle configuration](https://sparkle-project.org/documentation/customization/)
- [Korean Personal Information Protection Act, Article 30](https://www.law.go.kr/법령/개인정보보호법/제30조)
