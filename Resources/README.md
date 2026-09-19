# App icon resources

The three Icon Composer documents supplied by the user on 2026-09-19 are the current icon sources. Their artwork, layer positions, colors, and effects are compiled as authored.

| Source | Settings choice | Bundled resource |
| --- | --- | --- |
| `launchpod.icon` | 기본 Launchpod | `Launchpod.icns` and the main `Assets.car` |
| `launchpad.icon` | 원래 Launchpad | `OriginalLaunchpad.icns` |
| `apps.icon` | macOS 앱(Apps) | `MacOSApps.icns` |

`scripts/build-app.sh` compiles all three documents with Xcode's `actool`. The alternate ICNS files are build outputs, rather than copies of the previously exported system icons. Their resource names and saved selection identifiers are unchanged, so existing preferences continue to select the corresponding replacement artwork.

The main icon uses Icon Composer's compiled asset catalog in Finder. Alternate selections use the compiled ICNS through the existing Finder custom-icon and Dock refresh implementation. The menu bar keeps its `square.grid.3x3.fill` system symbol.

The user-supplied sources are in this project's `Resources` directory. `../apps/LaunchOS.app/Contents/Resources` contains the older reference application's resources and is not used as an icon build input.
