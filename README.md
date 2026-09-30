# Launchpod 🚀

![Platform](https://img.shields.io/badge/Platform-macOS-lightgrey.svg)
![Swift](https://img.shields.io/badge/Swift-5.7%2B-orange.svg)
![Architecture](https://img.shields.io/badge/Architecture-Apple_Silicon-blue.svg)

<img src="./icon.png" alt="Launchpod Icon" width="160" />

**Launchpod** is a native macOS app launcher that brings the familiar Launchpad grid, search, pages, and folders to an independent Swift and AppKit app. It's designed to keep your applications easy to find and organize, with a focus on Apple Silicon Macs running macOS Tahoe 26.

*Version 1.1.0. Requires macOS 12.0 or later and Apple Silicon (arm64).*

## ✨ Features

* **Familiar App Grid:** Browse applications across pages with a customizable grid and a blurred desktop wallpaper background.
* **Instant Search:** Start typing to find applications by name, including apps inside folders.
* **Drag-and-Drop Organization:** Rearrange apps, move them between pages, and create or rename folders with drag previews and animated placement.
* **Smooth Page Navigation:** Switch pages with keyboard shortcuts, page dots, background dragging, or trackpad and Magic Mouse scrolling.
* **Trackpad Gestures:** Pinch with four or five fingers to open Launchpod and spread to close it. Gesture preferences are configurable in Settings.
* **Dock & Menu Bar Access:** Open Launchpod from its Dock shortcut, menu bar icon, or a customizable global keyboard shortcut. Drag top-level apps directly to the Dock.
* **Hot Corners:** Choose any of the four screen corners in Settings to open Launchpod by moving the pointer there. Each corner can be enabled independently, on every display.
* **Layout Migration:** Import a supported legacy Launchpad layout, or export and import JSON layouts between Macs.
* **Undo & Redo:** Undo and redo layout changes while organizing your apps.
* **App Management:** Open apps, reveal them in Finder, hide them, or move eligible apps to the Trash after confirmation. Removed apps are cleared from the catalog on the next scan.
* **Personalization:** Choose an app icon, adjust the grid, and switch between English and Korean. English is the default language.
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

In **Settings… → Hot corners**, select the corners you want to use. All corners are off by default. To avoid two actions running together, set those same corners to **“–”** in **System Settings → Desktop & Dock → Hot Corners**. Launchpod must remain running; it does not change macOS hot corner settings. Move away from a corner before using it again. Hot corners do not activate during a mouse drag.

*Dragging an app to an invalid position or pressing `Esc` during a drag returns it to its original slot. Undo restores layout changes, but does not recover application files moved to the Trash.*

While collecting apps, keep `Cmd` held to switch pages with the arrow keys, page dots, scrolling, or by pausing at a screen edge. `Cmd`-click a folder to collect apps inside it; move outside the folder to return to the main grid. Release over a folder to add the whole stack, or pause over an app until it highlights to create a new folder. `Esc` or releasing outside the grid cancels the collection. Apps are placed in pickup order, and one Undo restores the entire move.

Launchpod runs as a menu bar app and hides the menu bar while the launcher is open. On launch or reopen, it adds its Dock shortcut if missing, restarting the Dock once when needed. The shortcut stays after quitting, without a running indicator, and is restored on the next launch if removed.

## 🚀 Installation & Build

Download the signed and notarized DMG from [GitHub Releases](https://github.com/elixirevo/launchpod/releases/latest), open it, and drag Launchpod to Applications.

Or install using Homebrew:

```bash
brew install --cask elixirevo/tap/launchpod
```

To build from source, Launchpod uses a build script and Swift Package Manager. No Xcode project setup is required.

### Prerequisites

* An Apple Silicon Mac (arm64)
* macOS 12.0 or later
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
swift build --arch arm64
swift run --arch arm64 CoreChecks
```

Use `build-app.sh` to create the complete app bundle with compiled icons and the Sparkle framework.

## 🔒 Permissions

**Accessibility** permission is required for trackpad gestures. Launchpod prompts for it at startup when gestures are enabled and permission is missing. Enable Launchpod in **System Settings → Privacy & Security → Accessibility**, or open that pane from Settings inside the app.

Layouts are stored locally at `~/Library/Application Support/Launchpod/layout.json`, with the previous valid layout saved as `layout.previous.json`. Shortcut and grid preferences are stored in UserDefaults. Importing a legacy layout does not modify the original Launchpad database.

## 📦 Import & Export Layouts

To move an existing Launchpad layout to a new Mac:

1. Run Launchpod on an Apple Silicon Mac that still has the original Launchpad.
2. Open **Settings… → Import This Mac’s Layout…**, review the result, and apply it.
3. Use **Export…** to save the layout as JSON.
4. On the destination Mac, use **Import…** to load that JSON file.

Legacy database import currently supports **Launchpad database schema 13** only. You can also select a saved database snapshot. Prefer the in-app export workflow over copying a live `db` file alone, since a live database may depend on its write-ahead log (WAL).

Layouts do not include application files. Launchpod matches installed apps by path and bundle ID on the destination Mac. Missing apps remain dimmed to preserve their positions, and ambiguous bundle IDs are not matched arbitrarily.

On the first successful scan, Launchpod groups installed system utilities into a Tools folder once. Existing folders and hidden apps are preserved, and subsequent user changes are not automatically reorganized.

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

`--hot-corner-settings-checks /path/to/results` (with a separate `--data-dir`) checks corner selection, persistence, monitor lifecycle, and English/Korean settings layouts. It captures both ends of the scrollable settings window without changing system hot corners or posting mouse input. The core checks also cover corner entry, repeat suppression, dragging, and display coordinates.

`--outside-click-checks /path/to/results` (with a separate `--data-dir`) verifies dismissal without key focus, focus retention, reopening, and event-monitor teardown using in-memory outside-click events.

`--editing-page-checks /path/to/results` (with a separate `--data-dir`) checks long-press editing, reused app and folder animations after paging away and back, and animation cleanup on exit. Run again with `--reduce-motion` to verify that preference.

`--app-collection-checks /path/to/results` (with a separate `--data-dir`) checks Command-click collection, pointer following, page and folder moves, grouping, cancellation, and batch undo/redo. It uses an isolated fixture and never launches apps. Run again with `--reduce-motion` to check reduced animations.

See [App icon resources](Resources/README.md) for the Icon Composer assets and how they are bundled.
