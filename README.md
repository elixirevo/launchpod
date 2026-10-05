# Launchpod 🚀

![Platform](https://img.shields.io/badge/Platform-macOS-lightgrey.svg)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)
![Architecture](https://img.shields.io/badge/Architecture-Apple_Silicon-blue.svg)

<img src="./icon.png" alt="Launchpod Icon" width="160" />

**Launchpod** is a native macOS app launcher that brings the familiar Launchpad grid, search, pages, and folders to an independent Swift and AppKit app. It's designed to keep your applications easy to find and organize, with a focus on Apple Silicon Macs running macOS Tahoe 26.

*Version 1.3.1. Requires macOS 13.0 or later and Apple Silicon (arm64).*

## ✨ Features

* **Familiar App Grid:** Browse applications across pages with a customizable grid and a blurred desktop wallpaper background.
* **Instant Search:** Start typing to find applications by name, including apps inside folders.
* **Drag-and-Drop Organization:** Rearrange apps, move them between pages, and create or rename folders with drag previews and animated placement.
* **Move Multiple Apps:** In editing mode, hold `Cmd` and click apps to collect them at the pointer. Release `Cmd` to place them together on a page or in a folder.
* **Smooth Page Navigation:** Switch pages with keyboard shortcuts, page dots, background dragging, or trackpad and Magic Mouse scrolling.
* **Trackpad Gestures:** Pinch with four or five fingers to open Launchpod and spread to close it. Gesture preferences are configurable in Settings.
* **Dock & Menu Bar Access:** Open Launchpod from its Dock shortcut, menu bar icon, or a customizable global keyboard shortcut. Drag top-level apps directly to the Dock.
* **Hot Corners:** Choose any of the four screen corners in Settings to open Launchpod by moving the pointer there. Each corner can be enabled independently, on every display.
* **Layout Migration:** Import a supported legacy Launchpad layout, or export and import JSON layouts between Macs.
* **Undo & Redo:** Undo and redo layout changes while organizing your apps.
* **App Management:** Open apps, reveal them in Finder, hide them, or move eligible apps to the Trash after confirmation. Removed apps are cleared from the catalog on the next scan.
* **Personalization:** Choose an app icon, adjust the grid, and switch between English and Korean. Existing language choices are preserved; language changes apply on the next launch.
* **Native Implementation:** Built with Swift and AppKit, with cached app icons and SQLite support for legacy layout imports.

## ⌨️ Shortcuts & Controls

| Shortcut / Control | Action |
| --- | --- |
| `Control + Option + L` | Open or close Launchpod |
| Dock shortcut / menu bar icon | Open or close Launchpod |
| Type an app name | Search applications, including those inside folders |
| Arrow keys / `Return` | Select / launch an app |
| `Cmd + Left Arrow` / `Cmd + Right Arrow` | Switch pages |
| Scroll / click a page dot / drag an empty area horizontally | Switch pages |
| `Esc` | Exit editing, close a folder, clear search, or close the launcher, in that order |
| Click an empty area | Close the folder or launcher |
| Click the desktop on another display | Close the launcher, even when it does not have focus |
| Long-press an icon / hold `Option` | Enter organization mode / show delete buttons for eligible apps |
| Hold `Cmd` and click apps while editing | Collect apps into a stack at the pointer; release `Cmd` to place them together |
| Drag an icon | Rearrange apps; drop in a valid position to save the change |
| Drag an icon to a page edge | Move it to another page |
| Hold an app over another app, then drop | Create a folder and enter its name |
| Hold an app over a folder | Preview the folder, then open it automatically |
| Drop an app into a folder / drag it outside | Add it to / remove it from the folder |
| Click a folder title | Rename the folder |
| Right-click an app | Open app actions |
| `Cmd + Z` / `Shift + Cmd + Z` | Undo / redo layout changes |
| `Cmd + ,` | Open Settings |

*Right-click the menu bar icon and choose **Settings…** to change the global shortcut, grid, language, icon, and gesture preferences.*

In **Settings… → Keyboard Shortcuts → Hot corners**, select the corners you want to use. All corners are off by default. To avoid two actions running together, set those same corners to **“–”** in **System Settings → Desktop & Dock → Hot Corners**. Launchpod must remain running; it does not change macOS hot corner settings. Move away from a corner before using it again. Hot corners do not activate during a mouse drag.

*Dragging an app to an invalid position or pressing `Esc` during a drag returns it to its original slot. Undo restores layout changes, but does not recover application files moved to the Trash.*

While collecting apps, keep `Cmd` held to switch pages with the arrow keys, page dots, scrolling, or by pausing at a screen edge. `Cmd`-click a folder to collect apps inside it; move outside the folder to return to the main grid. Release over a folder to add the whole stack, or pause over an app until it highlights to create a new folder. Releasing over the page dots places the apps at the end of the selected page. `Esc` or releasing outside a valid drop area cancels the collection. Apps are placed in pickup order, and one Undo restores the entire move.

Launchpod runs as a menu bar app and hides the menu bar while the launcher is open. After required agreement and setup, on launch or reopen it adds its Dock shortcut if missing, restarting the Dock once when needed. The shortcut stays after quitting, without a running indicator, and is restored on the next launch if removed.

## 🚀 Installation & Build

Download the signed and notarized DMG from [GitHub Releases](https://github.com/elixirevo/launchpod/releases/latest), open it, and drag Launchpod to Applications.

Or install using Homebrew:

```bash
brew install --cask elixirevo/tap/launchpod
```

To build from source, Launchpod uses a build script and Swift Package Manager. No Xcode project setup is required.

### Prerequisites

* An Apple Silicon Mac (arm64)
* macOS 13.0 or later
* Full Xcode with support for Icon Composer (`.icon`) assets; Command Line Tools alone are not sufficient
* Python 3, used by the build configuration script
* An internet connection for SwiftPM to download Sparkle 2.10.0 on the first build

### Build Steps

1. Open a terminal in the project directory containing `README.md` and `Package.swift`. From the parent workspace, run:

   ```bash
   cd launchpod
   ```

2. Build and package the app:

   ```bash
   ./scripts/build-app.sh
   ```

3. The build produces `dist/Launchpod.app` and `dist/Launchpod.zip`. Launch the app:

   ```bash
   open dist/Launchpod.app
   ```

4. Copy `Launchpod.app` to your Applications folder. To transfer it to another Apple Silicon Mac, copy `Launchpod.zip`, unzip it, and move the app to Applications.

The default build uses ad-hoc signing and is not Developer ID signed or notarized. macOS Gatekeeper may restrict it when transferred to another Mac. Intel and universal builds are not supported.

For development, you can also build the SwiftPM executable and run the core checks:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --arch arm64
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run --arch arm64 CoreChecks
```

Use `build-app.sh` to create the complete app bundle with compiled icons, Sparkle, Sentry (including its privacy manifest) and SwiftPM resource bundles. The local MacAppEssentials dependency must be checked out at `../../tools/library` relative to this repository.

Launchpod scans `/Applications`, `/System/Applications`, `/System/Library/CoreServices/Applications` and `~/Applications`, plus user-added locations. This includes system utilities such as Keychain Access. App bundles also expose tools from `Contents/Applications` and `Contents/Developer/Applications`, including Xcode’s Icon Composer and other development tools. Other bundle internals, login helpers and background-only services remain excluded.

Normal startup leaves Launchpod running in the menu bar without opening the launcher. Click its icon, use the shortcut, or choose Open Launchpod to show it. Required first-run setup and changed terms still appear when needed.

Settings uses MacAppEssentials with **General** first and **Features** second. General contains language, launch at login, optional crash reporting, language reset and feature settings reset; the second page contains grid, icon, layout import/export and app-library controls. Gesture and hot-corner controls use the common Keyboard Shortcuts page. **Keyboard Shortcuts** and **Permissions** use the library’s dedicated pages. Existing shortcut preferences are retained; recording suspends the global shortcut, failed changes retain the previous value, and Clear disables it across launches. **Help & Support** includes offline English/Korean Terms of Use and Privacy Policy, plus contact at `elixirevo@gmail.com`. Reading or saving documents does not record consent. See [legal document maintenance](docs/legal/README.md).

General → Restore Defaults → Features restores the 7 × 5 grid, Launchpod icon, default search locations and visible apps, after confirmation. App order and folders are kept; grid changes may redistribute items across pages. Shortcut/gesture settings, login registration, reporting consent and agreement records are not reset.

Sentry crash reporting is **off by default** and changes in **General → Diagnostics** take effect after restarting. Only fatal crashes and unhandled exceptions are reported through `MacAppDiagnosticsSentry`; usage/session/performance tracking, network-error capture, logs and replay are disabled. Preview and isolated check runs never initialize Sentry. The public `SentryConfiguration.json` belongs to this app; management tokens stay in the developer keychain or CI secrets. See [Sentry maintenance](docs/sentry.md).

## First-run setup

The library’s `MacAppOnboarding` presents six steps: welcome, opening Launchpod, organizing apps, versioned Terms of Use agreement, Accessibility permission, and optional crash reports. It shares the permission and reporting models with Settings. Reading terms does not record agreement. The terms checkbox and explicit Agree action save a separate local receipt; completing setup never grants OS permissions or enables crash reporting.

Only **Finish** saves `Launchpod.onboarding.completedVersion` (flow version 1). Before terms agreement, closing or choosing Quit exits without enabling app features. After agreement, **Set Up Later** or closing the window leaves the app running in the menu bar without marking setup complete. The next launch or Finder/Dock reopen shows unfinished setup again; reopening in the same process keeps its current step. Existing users without a completion record see setup once as well. Existing completion records are preserved and never treated as terms acceptance; those users get only the required terms window when agreement is missing or the terms version changes. Layouts, shortcuts, consent and other preferences are preserved. Completed setup is not shown automatically unless the onboarding version changes. Settings → Help & Support → Getting Started → Show Introduction… reopens it from the first page without resetting completion or terms acceptance.

Run `scripts/check-onboarding.sh` after building to test versioned terms migration, startup gating, completion, deferral, persistence failures and the six pages in English/Korean and light/dark appearance. An interactive preview is available without live permission requests, telemetry or completion writes:

```sh
dist/Launchpod.app/Contents/MacOS/Launchpod --data-dir /tmp/launchpod-onboarding-preview --preview-onboarding
```

The organizing guide includes English/Korean screenshots of the actual launcher with a demo layout of system apps. To regenerate them after UI changes, build first and run the following for each language (`en`/`ko`). The capture uses an isolated layout and a neutral backdrop; it does not include personal apps or the desktop picture.

```sh
dist/Launchpod.app/Contents/MacOS/Launchpod -MacAppLibrary.language ko -columns 3 -rows 3 \
  --windowed --data-dir "$(mktemp -d)" \
  --onboarding-artwork "$PWD/Sources/Launchpod/Resources/Onboarding/organize.ko.png"
```

Rebuild after generating the screenshots to bundle the updated images.

## 🔒 Permissions

**Accessibility** permission is required for trackpad gestures. First-run setup explains it, and a request runs only after you choose the permission action. Skipping setup does not trigger another startup permission prompt. Enable Launchpod in **System Settings → Privacy & Security → Accessibility**, or open that pane from **Settings → Permissions** using the shared permission explanation.

Layouts are stored locally at `~/Library/Application Support/Launchpod/layout.json`, with the previous valid layout saved as `layout.previous.json`. Shortcut and grid preferences are stored in UserDefaults. Importing a legacy layout does not modify the original Launchpad database.

## 📦 Import & Export Layouts

To move an existing Launchpad layout to a new Mac:

1. Run Launchpod on an Apple Silicon Mac that still has the original Launchpad.
2. Open **Settings… → Features → Import This Mac’s Layout…**, review the result, and apply it.
3. Use **Export…** to save the layout as JSON.
4. On the destination Mac, use **Import…** to load that JSON file.

Legacy database import currently supports **Launchpad database schema 13** only. You can also select a saved database snapshot. Prefer the in-app export workflow over copying a live `db` file alone, since a live database may depend on its write-ahead log (WAL).

Layouts do not include application files. Launchpod matches installed apps by path and bundle ID on the destination Mac. Missing apps remain dimmed to preserve their positions, and ambiguous bundle IDs are not matched arbitrarily.

On the first successful scan of a new layout, macOS apps appear first with the Tools folder on page one. User-installed apps start on a separate page after the system apps. Each group retains the catalog’s alphabetical order. If a smaller grid cannot fit all system apps, they continue on the following pages before installed apps. Rescans, existing layouts, imports and settings resets preserve the user’s arrangement.

Use **Settings → Features → Layout → Reset Layout…** to rebuild the default arrangement after confirmation. This removes custom folders and restores macOS apps, Tools and installed-app pages using the current grid size. Hidden and unavailable apps are preserved, and other settings remain unchanged. **Edit → Undo** restores the previous arrangement. General’s feature-settings reset continues to preserve app order and folders.

Launchpod groups only utilities bundled with macOS into the default Tools folder: Apple apps in `/System/Applications/Utilities` and `/System/Library/CoreServices/Applications`, including Keychain Access. Separately installed utilities, Xcode, Icon Composer and Simulator remain outside it, regardless of their category. Newly discovered macOS utilities join the folder; manual moves, custom folders and hidden apps are preserved. Layouts saved with the earlier broad grouping policy have non-system apps moved out of the tracked automatic Tools folder once.

## 🔄 Updates

Sparkle provides **Check for Updates…** and **Automatically Check for Updates** in the menu bar context menu. Automatic checks follow Sparkle's consent flow and do not force automatic installation.

Official builds use the signed [Sparkle appcast](https://github.com/elixirevo/launchpod/releases/latest/download/appcast.xml) and public key in `Resources/Info.plist`. Both the feed and update downloads are verified. Source builds inherit this configuration; set both `LAUNCHPOD_UPDATE_FEED_URL` and `LAUNCHPOD_UPDATE_PUBLIC_KEY` to empty strings to disable update checks for local development.

See [Releasing Launchpod](docs/releasing.md) for Developer ID signing, notarization, Sparkle, GitHub Releases, and Homebrew publication.

## 🛠 Contributing & Verification

Contributions are welcome! Create a feature branch, make your changes, run the relevant checks, and submit a pull request with a description of the change and how you verified it.

Run these checks from the project directory:

```bash
scripts/check.sh                       # Core models, persistence, and imports
scripts/check.sh --legacy              # Also read the local legacy Launchpad database
scripts/check-catalog.sh               # App discovery, search, and persistence
scripts/check-icons.sh                 # Startup icon preparation and PNG cache behavior
scripts/check-updates.sh               # Sparkle configuration and update menus
scripts/check-wallpaper.sh --desktop   # Wallpaper selection, sizing, and blur
scripts/check-wallpaper.sh --desktop --expect-picture
```

The `--legacy` check requires a Mac with the original Launchpad. The final wallpaper check verifies that a picture wallpaper is not replaced with a gray fallback.

UI checks require a graphical login session. They use a temporary layout and do not launch or delete real applications:

```bash
launchpod_test_dir="$(mktemp -d /tmp/launchpod-ui.XXXXXX)"
dist/Launchpod.app/Contents/MacOS/Launchpod --windowed \
  --data-dir "$launchpod_test_dir/state" --ui-checks "$launchpod_test_dir/images"
```

Add `--reduce-motion` to check reduced animations without changing system preferences. `--preview-output /path/to/preview.png` saves a preview of the app and exits. Always use a separate `--data-dir` with test options.

`--hot-corner-settings-checks /path/to/results` (with a separate `--data-dir`) checks corner selection, persistence, monitor lifecycle, and English/Korean settings layouts. It captures the Launchpod settings page without changing system hot corners or posting mouse input. Run `scripts/check-languages.sh` for English/Korean, light/dark minimum-size settings and legal-document checks. The core checks also cover corner entry, repeat suppression, dragging, and display coordinates.

`--outside-click-checks /path/to/results` (with a separate `--data-dir`) verifies dismissal without key focus, focus retention, reopening, and event-monitor teardown using in-memory outside-click events.

`--editing-page-checks /path/to/results` (with a separate `--data-dir`) checks long-press editing, reused app and folder animations after paging away and back, and animation cleanup on exit. Run again with `--reduce-motion` to verify that preference.

`--app-collection-checks /path/to/results` (with a separate `--data-dir`) checks Command-click collection, pointer following, page and folder moves, grouping, cancellation, and batch undo/redo. It uses an isolated fixture and never launches apps. Run again with `--reduce-motion` to check reduced animations.

See [App icon resources](Resources/README.md) for the Icon Composer assets and how they are bundled.

## MacAppEssentials 0.5.1 integration

The local dependency at `../../tools/library` uses `v0.5.1` (`b3e36a4`), including the Features-tab and login-item fixes. The login-item first-registration fix means a main-app `notFound` status leaves the toggle available, and registration errors are shown after an explicit user attempt. It adds the shared Help & Support onboarding review action, alongside versioned terms acceptance, bundled support documents and `shortcutsContent`. The second Features tab uses the package example’s sky-blue monitor icon and retains the existing `launchpod` page ID. Grid/icon/layout controls remain there; gestures and hot corners are on Keyboard Shortcuts above the shared recorder. Terms/privacy remain read-only under Help & Support.

Version 0.5.1 improves the shared window presenter used by settings, onboarding and terms: it restores minimized windows, raises the requested window before activation, and restores focus when activation completes. Only the latest request is retained briefly; closing, minimizing, choosing another window or deactivating cancels it. Launchpod keeps its accessory policy and existing window levels. No app preference, layout, onboarding completion or terms-acceptance migration is needed. The local path dependencies do not create a MacAppEssentials entry in `Package.resolved`; use the documented checkout when reproducing this build.

The app-lifetime onboarding host handles `showForReview()` from Help & Support. Repeated clicks focus the existing review window; closing and reopening starts a fresh review. Review completion does not overwrite saved completion or rerun app startup callbacks.

`AppStartup` owns the agreement shared by first-run onboarding and the standalone terms-update window. The launcher/catalog, Dock registration, global shortcuts/gestures, Sparkle and Sentry SDK start only after the required agreement is stored and optional setup is finished or deferred. Sentry still uses the reporting preference captured at process launch; enabling it during setup applies on restart. Terms version 1.3 is independent of onboarding version 1 and app releases. The local receipt stores document ID/version/language/hash/time under `Launchpod.terms.acceptance` and is preserved by ordinary settings reset. Read failures, missing documents and failed writes keep features blocked.

For an isolated, memory-only preview of the upgrade path, use `--data-dir /tmp/launchpod-terms-preview --preview-terms`. Use `--preview-onboarding` for the first-run path. Neither preview initializes reporting or stores real agreement receipts. Previous legal text is archived in `docs/legal/archive/1.2`.

MacAppEssentials 0.5.1 is GPL-3.0-only. Its license and scope notices are bundled under `Contents/Resources/Licenses`; external SDK licenses remain separate. This dependency update does not assign a new license to unrelated app-owned files.
