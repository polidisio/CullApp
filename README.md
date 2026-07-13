# CullApp

> A clean, native macOS uninstaller — completely removes apps and every file they leave behind.

CullApp is a Mac App Store-compatible uninstaller that detects and removes application leftovers using smart bundle-identifier matching. Built with SwiftUI, SMJobBless privileged helper, and modern macOS frameworks.

## Features

- **Drag & Drop** — drop any `.app` bundle onto the window (with live hover highlighting) to analyze and uninstall; drop multiple apps at once, remove individual apps before scanning
- **Smart Detection** — finds all related files by app name and bundle identifier (preferences, caches, logs, containers, saved state, launch agents/daemons)
- **Delete Confirmation** — every removal requires an explicit confirmation showing item count and reclaimed disk space before anything moves to the Trash
- **Privileged Helper** — SMJobBless-powered helper removes root-owned files cleanly, requested on-demand only when root-owned leftovers are found
- **Trash, not Delete** — files go to Trash via `FileManager.trashItem`/the helper (reversible)
- **Progress UI** — live scan/delete progress with per-file status and total size
- **Native macOS** — SwiftUI, Swift 5.9, no Electron

## Icons

The UI icons (app package, scan, folder, file, trash, warning, success) are vector assets adapted from
[Reicon](https://github.com/dqev/reicon) (MIT License), bundled as template SVGs in
`Resources/Assets.xcassets` so they tint with the system accent color.

## Architecture

```
CullApp.app (sandboxed)
  ├── SwiftUI Drop Zone
  ├── FileScanner (bundle-identifier matching)
  └── XPC Client ←→ CullAppHelper (root)
                        └── removes privileged files → Trash
```

## Requirements

- macOS 14.0+ (Sonoma or later)
- Xcode 15+

## Build & Run

```bash
cd CullApp
xcodegen generate
open CullApp.xcodeproj
# Select CullApp scheme, press ⌘R
```

Or from CLI:

```bash
xcodebuild -project CullApp.xcodeproj -scheme CullApp \
  -configuration Debug build
```

## Security Model

- User-domain files are moved to Trash via `NSWorkspace.shared.moveToTrash()`
- Root-owned files are removed by **CullAppHelper** — a privileged helper installed via SMJobBless
- The helper communicates over XPC and is code-signed with a dedicated certificate
- All deletion operations require explicit user confirmation before proceeding

## About SMJobBless

CullApp uses Apple's SMJobBless standard to install a privileged helper tool. This is the same mechanism used by popular Mac App Store apps to perform operations that require administrator privileges. The helper:

- Is installed to `/Library/PrivilegedHelperTools/`
- Is launched on-demand via XPC by the main app
- Signs with a certificate anchored at Apple's system roots
- Requires no password prompts after initial installation

## License

MIT

## Author

Jose Audisio — [polidisio](https://github.com/polidisio)
