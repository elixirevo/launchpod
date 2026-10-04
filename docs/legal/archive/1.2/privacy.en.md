# Launchpod Privacy Policy

Document version: 1.2 · Effective date: October 4, 2026

## 1. Operator and contact

Launchpod is a free macOS app launcher and layout organizer developed and distributed by the GitHub account elixirevo. Send privacy questions and rights requests to the developer and distributor at [elixirevo@gmail.com](mailto:elixirevo@gmail.com).

This policy covers app features and support requests. You can read, copy and save the installed version in Settings > Help & Support without an internet connection. Earlier distributions retain their corresponding documents. External services' policies also apply to their independent processing.

## 2. Information and purposes

Apps and layouts: the app reads or stores installed app names, bundle identifiers, file paths and icons, added search locations, pages, folders, ordering and hidden status on your device. This provides the search, launch and organization functions you request. These lists and layouts are not uploaded to an operator server. Search text is processed in memory; no separate search history is transmitted.

Wallpaper and gestures: macOS wallpaper is displayed behind the launcher. Pointer positions for hot corners and trackpad events determine open/close actions. This processing stays on your device. The app does not send gesture input to analytics services or save an input history.

Preferences: language, shortcuts, grid, icon, gestures, hot corners, additional search paths, window state and the completed onboarding version are stored in macOS app preferences to restore your setup between launches. They remain until changed or deleted. The onboarding version is stored locally only when you press Finish and prevents repeating completed setup. It is not a terms-acceptance or crash-reporting consent record. If you enable launch at login, macOS manages the login item.

Updates: Sparkle connects to GitHub's update feed and distribution files. Receiving servers may process IP addresses, request times, requested resources and HTTP request information that may include app/framework versions. App lists, layouts and wallpaper are not attached. See section 5 for controls.

Support: email addresses, account names, messages and attachments you submit by email or GitHub Issues are used to answer your request and resolve problems. Public issues are visible to others. Support records are used for as long as needed for the request and related troubleshooting; deletion requests go to the contact email. No fixed retention period or provider backup deletion date is currently promised.

The app currently has no account registration, payments, subscriptions, advertising, cloud layout synchronization, operator usage analytics or transmission of terms-acceptance records.

## 3. Local storage and permissions

Layouts are stored at ~/Library/Application Support/Launchpod/layout.json, with the previous valid layout in layout.previous.json. App icon caches are stored at ~/Library/Caches/Launchpod/AppIcons-v1 and removed during cache cleanup or when you delete them. Preferences use UserDefaults for app.launchpod.Launchpod. Exported JSON files and selected legacy Launchpad databases remain in locations you manage.

Accessibility permission supports gesture detection. Revoke it in System Settings > Privacy & Security > Accessibility, or turn gestures off in Settings > Launchpod. Revoking permission does not delete saved layouts. Basic searching and launching do not require gesture permission.

The app may restore its Dock shortcut when launched or reopened, and apply your selected icon to the app file and Dock. These changes are local.

To delete local data, first quit the app and use Finder's Go to Folder to locate and remove the layout and cache directories above. Export layouts first if needed. Restore Defaults changes only the preferences described in its prompt; it does not delete layout files. Removing the app does not necessarily remove all preferences or exported files. Manage copies in backup or synchronization tools separately.

## 4. Crash reports

Crash reporting through Sentry is optional and off by default. Turn it on during onboarding or in Settings > General > Diagnostics to help the developer investigate crashes. The choice takes effect after quitting and reopening the app. On a launch with reporting disabled, the Sentry SDK is not initialized. App search, launching and layout management remain available without reporting.

With reporting enabled, technical crash reports can include the app version/build, macOS and SDK versions, device architecture and technical device information, crash time, exception details, thread stacks and loaded binary identifiers. Sentry also processes connection information, including the IP address, when a report is transmitted. Reports are sent over HTTPS, including after a later launch for a previous crash. They are not guaranteed to be fully anonymous: technical exception details or paths may incidentally contain personal information.

The app enables crash and unhandled-exception reporting only. It disables usage/session tracking, performance monitoring, network-error capture, breadcrumbs, logs and screen replay. It does not attach app inventories, layout files, wallpaper or gesture input. Before sending, the integration removes user, HTTP request, custom extra/tag, breadcrumb, message and server-name fields; memory-content inspection and default personal-information collection are disabled. Sentry's default server-side sensitive-data filtering is enabled for this project, but these controls cannot guarantee removal of all personal information.

To stop reporting, turn the option off and restart the app. The setting does not cancel reporting already in progress in the current process. Unsent reports may remain in the SDK's local cache and may be sent if you later opt in again; changing the toggle does not delete old reports. The SDK's event cache is configured for at most 20 queued items, which is not a fixed retention period for every SDK file. Server retention follows the project's Sentry plan and service configuration; no fixed deletion date is promised here. Request deletion of reports held by the operator at the contact email, with any identifying report details you have. The app does not collect a user account to identify every report.

Logs you attach to a request are support material. Apple's policies govern diagnostics macOS processes under its own settings.

## 5. Updates, support and external links

The feed is https://github.com/elixirevo/launchpod/releases/latest/download/appcast.xml. Downloads use GitHub Releases and its delivery servers. When enabled, Sparkle checks periodically; manual checks and downloads also make connections. Disable automatic checks in Settings > Software Update. This does not cancel a download already in progress, and local app features remain available with checking disabled.

The app is configured not to send Sparkle's optional system profile. Sparkle is the update tool; GitHub operates the receiving service. GitHub's policy governs its server-log retention and deletion; the operator does not specify a uniform retention period for those logs.

Help & Support diagnostics contain the app name, version, build, operating-system version and distribution channel. Previewing, copying or saving does not transmit them. They reach a support recipient only if you submit them. Do not put personal information, passwords or authentication keys in public issues.

External links and contact buttons open your browser or email app. Launchpod does not automatically submit requests or send email.

## 6. External services and disclosure

GitHub handles distribution files, update requests and public issues you submit. Gmail processes messages and attachments you send to elixirevo@gmail.com. Sentry (Functional Software, Inc.) processes optional crash reports on behalf of the developer for crash investigation. These providers explain retention, security and request procedures in their policies:

[GitHub Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement)
[Google Privacy Policy](https://policies.google.com/privacy)
[Sentry Privacy Policy](https://sentry.io/privacy/)

The app has no feature that sells local app lists, layouts or gesture data to advertisers. Providers' independent processing and legally required disclosures are governed by their policies and applicable law.

## 7. International processing

GitHub and Google are external services that may process information using infrastructure in the United States and other countries. Checking or downloading updates or contacting support through these services may send connection information and submitted materials to them. Their policies describe processing locations, retention and international-transfer safeguards. Local layout files are not automatically sent to these services.

This app uses a Sentry project in the United States region. When crash reporting is enabled, the technical report and connection information described in section 4 are transmitted to Sentry over HTTPS for crash investigation, including cached reports on a later consented launch. Keeping crash reporting off, or turning it off and restarting, prevents reporting from that launch onward. Sentry processing and retention are subject to its service configuration and policies.

Turning automatic checking off and not using manual checks, downloads or external support avoids connections from those features. Viewing these documents is not recorded as separate consent to an international transfer.

## 8. Retention and safeguards

Your device account and file permissions control local settings and layouts. Updates use HTTPS and signature verification. The app does not promise separate encryption of every local layout file. Keep your device account and backups secure.

Request deletion of support materials held by the operator through the contact email. If a legal obligation or another applicable reason prevents deletion, the reason will be explained. Providers control their logs and backups; copies of publicly posted issues may also be outside the operator's control.

## 9. Rights and choices

Subject to applicable law, request access, a copy, correction, deletion, restriction or withdrawal of consent through the contact email. Minimal information may be needed to verify you or an authorized representative. If a request cannot be fulfilled, the reason will be explained. You may contest the outcome at the same address.

You manage local data the operator does not hold. For data independently controlled by GitHub, Google or Sentry, you may also use their privacy-request channels. Exercising statutory rights does not result in unlawful disadvantage.

## 10. US users and advertising

US residents may have access, correction, deletion, copy and appeal rights depending on applicable state law. This policy does not assume that every state law applies identically. Requests may be sent to the contact email.

The app has no advertising trackers, targeted advertising, behavioral profiling or personal-data sale feature. It has no in-app browser tracking cookies or Global Privacy Control / Do Not Track handling. External websites follow their own policies.

## 11. Children and teenagers

The app is not designed for children and does not request age or birth date. Contact us if you believe a child's information has been inappropriately included in a support request. Appropriate action will be considered under applicable law.

## 12. Policy changes

When processing changes, the document version and effective date will be updated and changes communicated through new distributions and release information. Documents in earlier distributions are retained. Any required separate notice or consent process will be provided before new processing begins; viewing this policy or the terms is not a substitute.
