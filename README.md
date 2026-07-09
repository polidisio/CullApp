# CullApp

> A clean, native macOS uninstaller — completely removes apps and every file they leave behind.

CullApp is a Mac App Store-compatible uninstaller that detects and removes application leftovers using smart bundle-identifier matching. Built with SwiftUI, SMJobBless privileged helper, and modern macOS frameworks.

## Features

- **Drag & Drop** — drop any `.app` bundle onto the window to analyze and uninstall
- **Smart Detection** — finds all related files by bundle identifier (preferences, caches, logs, containers)
- **Privileged Helper** — SMJobBless-powered helper removes root-owned files cleanly
- **Trash, not Delete** — user-domain files go to Trash (reversible)
- **Progress UI** — live scan progress with per-file status
- **Native macOS** — SwiftUI, @Observable, Swift 5.9, no Electron

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
