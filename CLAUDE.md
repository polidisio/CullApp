# CullApp — Project Context

## What it is
CullApp is a macOS app that uninstalls applications cleanly by finding and trashing all associated files (app bundle + support directories, caches, preferences, logs, etc.).

## Option B Scope (Implemented)

Full-featured uninstaller with privileged helper for root-level file operations.

### Features
- **Drag & Drop Zone** — drop `.app` bundles onto the window to queue them for analysis
- **File Scanner** — traverses the filesystem to find all files belonging to a dropped app (app bundle, `~/Library/`, `/Library/`, `/Applications/` subdirectories)
- **Trash Operation** — moves all found files to Trash; uses a privileged helper (SMJobBless) for files owned by root
- **Progress UI** — shows scan progress and per-file deletion status

### Architecture

```
MainApp (CullApp.app)
  ├── AppDelegate / DropZoneView (SwiftUI)
  ├── FileScanner  (uses AuthorizationServices for user files)
  └── XPC Client  ←——→ PrivilegedHelper (root)
                        ├── SMJobBless (installs into /Library/PrivilegedHelperTools/)
                        ├── XPC Service (com.cullapp.CullApp.PrivilegedHelper)
                        └── File mover: moves root-owned files to Trash
```

### Components

| Component | Language | Target | Notes |
|-----------|----------|--------|-------|
| `CullApp` (main app) | Swift | `com.cullapp.CullApp` | Code signed, sandboxed |
| `PrivilegedHelper` | Swift | `com.cullapp.CullApp.PrivilegedHelper` | SMJobBless, non-sandboxed |

### Security Model
- Main app requests authorization via `AuthorizationServices` for user-space files
- Root-owned files handled by `PrivilegedHelper` via XPC
- Helper installed via `SMJobBless` — requires `launchd.plist` + `Info.plist` + code signature in helper bundle
- Helper verifies calling app's code signature before acting
- All XPC communications use `NSXPCConnection` with `MachServiceName`

### SMJobBless Installation Flow
1. App calls `SMJobBless("kSMBlessPrivilegedHelper", ...)` on first run requiring root access
2. macOS verifies helper's `launchd.plist` embedded in the helper bundle matches the one in the app's Resources
3. Helper is installed to `/Library/PrivilegedHelperTools/com.cullapp.CullApp.PrivilegedHelper`
4. Helper runs as a LaunchDaemon under `root:wheel`

### XPC Protocol
```swift
@objc protocol PrivilegedHelperProtocol {
    func trashFiles(_ paths: [String], withReply reply: @escaping (Bool, String?) -> Void)
    func getVersion(withReply reply: @escaping (String) -> Void)
}
```

## macOS-specific Considerations
- **App Sandbox**: Enabled for main app; helper is NOT sandboxed
- **Hardened Runtime**: Enabled for both targets
- **Entitlements**: `com.apple.security.temporary-exception.mach-lookup.global-name` for XPC
- **Code Signing**: Both targets must be signed; helper's signature is verified at install time
- **Code Signature Hardened Runtime**: Both require `com.apple.developer.security.application-groups`

## Key Files
- `project.yml` — XcodeGen configuration
- `Sources/App/` — main application source
- `Sources/PrivilegedHelper/` — privileged helper source
- `Sources/Shared/` — XPC protocol definitions
- `Resources/` — app Info.plist, entitlements, helper plist

## Build & Run
```bash
xcodegen generate
xcodebuild -project CullApp.xcodeproj -scheme CullApp -configuration Debug build
```
