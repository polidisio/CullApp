# Code Review Report: CullApp
Generated: 2026-10-26T00:23:48.430957

I've read all 14 source/config files (working tree is empty — files are staged for deletion, so I reviewed `HEAD` content). Here's the report.

# Code Review — CullApp

## 1. CRITICAL

### C1. Root helper deletes *any* path it is handed — no allowlist, no canonicalization
**`Sources/PrivilegedHelper/HelperDelegate.swift:44-60`**
```swift
for path in paths { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), ...) }
```
The helper runs as root and performs zero validation on `paths`. A path traversal (`/Library/Caches/../../etc/passwd`) resolves to an arbitrary target; a client bug can trash `/System`, `/etc`, or the user's home. Nothing limits the blast radius.
**Fix:** in the helper, `resolvingSymlinksInPath()` each path, then require it to sit under an explicit prefix allowlist (`/Library/Application Support/`, `/Library/Caches/`, `/Library/Preferences/`, `/Library/LaunchAgents/`, `/Library/LaunchDaemons/`, `/Library/Logs/`). Reject everything else — especially `/System`, `/usr`, `/bin`, `/sbin`, `/etc`, `/var`, `/private/var`, `/dev`, and the helper's own bundle. Reject symlinks pointing outside the allowlist. Fail closed (reject the whole batch) rather than per-item.

### C2. XPC continuation is never resumed on failure → the UI deadlocks permanently
**`Sources/App/PrivilegedHelperClient.swift:39-53`**
```swift
guard let helper = conn.remoteObjectProxyWithErrorHandler({ error in print("XPC error: \(error)") }) ...
return await withCheckedContinuation { continuation in helper.trashFiles(paths) { ... continuation.resume(...) } }
```
If the helper is absent, the service isn't registered yet, or the helper dies mid-call, the reply block never fires and the error handler only prints. `withCheckedContinuation` never resumes → `ContentView.deleteFiles` awaits forever → `isDeleting` stays `true` → every button in the app stays disabled with no recovery path. This is reachable on the *normal* path, since `installHelperIfNeeded()` ignores its own failure (C4 below).
**Fix:** use `withCheckedThrowingContinuation`; resume from the error handler, from `interruptionHandler`/`invalidationHandler`, and from a timeout race (`withThrowingTaskGroup` vs. `Task.sleep`). Guarantee exactly-once resume with an atomic flag.

### C3. Caller identity verified by PID, not by audit token → PID-reuse spoofing
**`Sources/PrivilegedHelper/HelperDelegate.swift:6-17`**
```swift
let attributes = [kSecGuestAttributePid: connection.processIdentifier] as CFDictionary
```
`processIdentifier` is not a stable identity — the PID can be recycled after the original client exits, and the check is not bound to the XPC connection at all. The XPC connection already carries a signed `auditToken`; use it.
**Fix:** `var token = newConnection.auditToken; let attributes = [kSecGuestAttributeAudit: Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)]` and verify the audit token against the requirement.

### C4. Sandboxed app cannot scan or delete anything outside its container
**`Sources/App/FileScanner.swift:25-39`, `Resources/CullApp.entitlements`**
`ENABLE_APP_SANDBOX: YES` (`project.yml:33`) combined with:
- `FileManager.default.homeDirectoryForCurrentUser` → inside a sandbox this is the app's *container* (`~/Library/Containers/com.cullapp.CullApp/Data`), not the real home, so every `~/Library/...` search root points somewhere empty.
- No `com.apple.security.files.user-selected.read-only` entitlement → the dropped `.app` may be readable via the drop grant, but `Bundle(url:)`/`NSWorkspace.icon(forFile:)` are not guaranteed to work.
- No `temporary-exception.files.absolute-path.read-write` → `trashItem` on `~/Library/Caches/com.foo.bar` always fails, and the failure is swallowed (H2).

Net effect: the app as shipped finds nothing and deletes nothing, but reports success.
**Fix:** resolve the real home explicitly (`confstr(_CS_DARWIN_USER_DIR)` or `NSHomeDirectoryForUser(NSUserName())`), add the temporary-exception entitlements for the scanned `~/Library/*` roots, and verify the drop path resolves to a real bundle (`Bundle(url:)?.bundleIdentifier != nil`, `Contents/MacOS` exists).

### C5. `SMJobBless` failure is ignored; the flow proceeds into a doomed XPC call
**`Sources/App/PrivilegedHelperClient.swift:12-35`, `Sources/App/ContentView.swift:224-236`**
`installHelperIfNeeded()` returns `Void`, prints errors, and the caller unconditionally proceeds to `trashFiles(...)`. On failure the sequence is exactly the C2 deadlock.
**Fix:** return `Result`/`Bool` from `installHelperIfNeeded()`, abort the root-file phase with a user-visible message on failure, check installation status first (`SMJobBless` returns "already installed" as an error), treat that case as success, and retry the connection with backoff for a few seconds after install.

## 2. HIGH

### H1. Fuzzy substring matching deletes other applications' data
**`Sources/App/FileScanner.swift:71-80`**
```swift
return lowerName.contains(lowerAppName)
```
`Mail` matches `Mailbox`, `SparkleMail`; `Safari` matches `SafariTechnologyPreview`; `System` matches dozens of entries. Combined with C1 (root helper), a single drop can trash unrelated apps' support files and launch daemons.
**Fix:** exact-match the bundle-ID-derived entries (`com.foo.bar` in `~/Library/Containers`, `com.foo.bar.plist` in `~/Library/Preferences`) and match the app name only exactly or as a prefix segment. Keep fuzzy matching behind an explicit opt-in.

### H2. Failed deletions are reported as success
**`Sources/App/ContentView.swift:215-220, 238-247`**
```swift
} catch { print("Failed to trash \(item.path): \(error)") }
```
The final message says "Moved N items to Trash" regardless of failures — and under C4 *all* user-file deletions will fail, so the user is told they cleaned up when nothing was removed.
**Fix:** collect failures, report `Moved N items (M failed)`, and keep failed entries in `scanResults` for retry.

### H3. Root-owned files land in `/var/root/.Trash` — invisible and unrestorable by the user
**`Sources/PrivilegedHelper/HelperDelegate.swift:51`**
`trashItem` executed as root trashes into root's Trash, contradicting the UI copy "Files can be restored from the Trash afterwards."
**Fix:** move root-owned files into the invoking user's `~/.Trash` (create it with correct ownership), or delete and report clearly.

### H4. Removing an app from the drop list leaves its files in the delete list
**`Sources/App/ContentView.swift:372-374` vs `96-131`**
The "x" button removes the app from `droppedApps` but does not remove its `scanResults` entries. The user can then delete leftovers for an app they explicitly dismissed.
**Fix:** track which app each `FileItem` came from and filter `scanResults` when an app is removed, or re-run the scan after any change to `droppedApps`.

### H5. The confirmation dialog blurs the file list, so the user cannot review what is about to be deleted
**`Sources/App/ContentView.swift:137`**
`.blur(radius: showingDeleteConfirmation ...)` blurs the very list showing the paths. The dialog shows only a count and a size. Combined with H1, the user is asked to approve an unreviewable deletion.
**Fix:** keep the list unblurred (blur only the background chrome), or show the full path list inside the dialog.

### H6. Admin password prompt on every root-file deletion
**`Sources/App/PrivilegedHelperClient.swift:12-35`**
`SMJobBless` is invoked unconditionally, with no "is it already installed" check, so every root-file deletion triggers an authorization prompt and logs a spurious error.
**Fix:** check install status first and skip `SMJobBless` when already present.

## 3. MEDIUM

### M1. Ownership compared by username string `"root"`
**`Sources/App/ContentView.swift:203-204`, `Sources/App/FileScanner.swift:106-119`**
Files owned by `wheel`, `daemon`, `_spotlight` are treated as user files (sent to the sandboxed app, which fails); a genuinely root-owned file whose `attributesOfItem` throws returns `"unknown"` and is never routed to the helper.
**Fix:** carry the numeric uid in `FileItem` and compare against `0`.

### M2. Blocking I/O inside an actor; scans are uncancellable
**`Sources/App/FileScanner.swift:41-46, 82-104`, `Sources/App/ContentView.swift:166-193`**
`contentsOfDirectory` on 11 roots (incl. `/Library/Caches`) and a recursive `enumerator` over each match run synchronously on a cooperative-pool thread. The scan `Task` handle is never stored, so it cannot be cancelled — pressing "Clear" mid-scan lets it finish and repopulate `scanResults` with stale results.
**Fix:** store the `Task` in `@State` and cancel it on clear/re-scan; check `Task.isCancelled` in the loops; use a dedicated `DispatchQueue` rather than a cooperative actor for the file I/O.

### M3. AppKit called off the main thread
**`Sources/App/ContentView.swift:396-399`**
`provider.loadObject` invokes its completion on a provider-chosen queue; `NSWorkspace.shared.icon(forFile:)` is AppKit and not thread-safe.
**Fix:** dispatch the icon lookup to the main queue.

### M4. Per-path XPC results are lost
**`Sources/Shared/XPCProtocol.swift:4`, `Sources/PrivilegedHelper/HelperDelegate.swift:58`**
`trashFiles` returns one `Bool` (true only if all succeeded) and one `lastError` for many failures; the client then discards the whole root set from the "deleted" list even on partial success.
**Fix:** return the list of failed paths (or a `[String: Bool]`).

### M5. Scan errors are indistinguishable from "no leftovers"
**`Sources/App/FileScanner.swift:53-57`**
`try?` swallows the error; an unreadable root looks identical to an empty one, so the UI reports "Found 0 files".
**Fix:** return per-root errors and surface them in the status line.

### M6. Invalid application-group entitlement
**`Resources/CullApp.entitlements:7-10`, `Sources/PrivilegedHelper/PrivilegedHelper.entitlements:5-7`**
App-group identifiers must be TeamID-prefixed and cannot equal the app's own bundle identifier; the helper is unsandboxed (`ENABLE_APP_SANDBOX: NO`) so the group grants it nothing.
**Fix:** remove the app-group entitlement from both targets.

### M7. Drop handler reports acceptance for non-`.app` items
**`Sources/App/ContentView.swift:392-409`**
`return !providers.isEmpty` accepts any drop; a non-`.app` drop silently does nothing while showing the accepted-drop highlight. `isTargeted` is also not reset when the drop is rejected.
**Fix:** filter with `hasItemConformingToTypeIdentifier("com.apple.application-bundle")` and reset `isTargeted` in the rejection path.

### M8. The privileged path is untestable outside the App Store
**`Resources/CullApp-Info.plist:23-27`, `Sources/PrivilegedHelper/HelperDelegate.swift:4`**
`anchor apple generic` requires an Apple-signed build; every local/ad-hoc build fails `isCallerAuthorized`, so the entire root-file feature cannot be exercised in development.
**Fix:** use a team-scoped requirement (`certificate leaf[subject.OU] = "TEAMID"`) for development, or a `#if DEBUG` alternate requirement.

### M9. Missing AppIcon / `CFBundleIconName`
**`Resources/Assets.xcassets`, `Resources/CullApp-Info.plist`**
No `AppIcon` imageset and no `CFBundleIconName` key — the build will be rejected, and the app shows a generic icon.

## 4. MINOR

- **`Sources/Shared/XPCProtocol.swift:8-10`** — `AppProtocol` is declared and never implemented or used; delete it.
- **`ContentView.swift:219`, `PrivilegedHelperClient.swift:16,30,40,49`** — `print` for all diagnostics; use `os.Logger` with a dedicated subsystem so failures are filterable and persistable for support.
- **`ContentView.swift:80, 190`** — `statusMessage = "Found \(count) files"` is set but the status row only renders while `isScanning || isDeleting`, so it is never shown.
- **`ContentView.swift:224-236`** — `progress` is not updated during the root-file phase; the bar sits at the user-file ratio until it snaps to 1.0.
- **`FileScanner.swift:93`** — `.skipsHiddenFiles` under-reports directory sizes (dot-files inside bundles are excluded), so "freed space" is understated.
- **`FileScanner.swift:20`** — the dropped `.app` bundle is added to the delete list without verifying it is a real bundle; a plain directory named `Foo.app` would be trashed.
- **`FileScanner.swift:100`** — `fileAllocatedSize` double-counts hard-linked files and counts sparse allocation; `totalSize` is an estimate, worth labelling as such.
- **`ContentView.swift:15-21`** — `FileItem` is not `Sendable` yet crosses an actor boundary; add conformance for Swift 6 readiness.
- **`ContentView.swift:23`** — `byteFormatter` is a global `ByteCountFormatter`; it is not documented thread-safe. It is main-actor-only today, so it is safe, but scoping it would make that explicit.
- **`project.yml:25-26`** — `Resources/CullApp-Info.plist` is listed both as `INFOPLIST_FILE` and as a resource with `buildPhase: none`; the resource entry is redundant.
- **`project.yml:74`** — `OTHER_CODE_SIGN_FLAGS: "--identifier com.cullapp.CullApp.PrivilegedHelper"` duplicates `PRODUCT_BUNDLE_IDENTIFIER`.
- **`project.yml:5`** — deployment target is macOS 12.0 while the project brief states 14+.
- **`Sources/App/CullAppApp.swift`** — filename contains only `AppDelegate`; rename to `AppDelegate.swift`.

---

**Bottom line:** the app does not work as shipped and is unsafe if it did. C4 (sandbox/home resolution + missing entitlements) means it finds nothing; C1 (unvalidated root paths) plus C2 (unresumable continuation) and C5 (ignored install failure) mean a root-file deletion either hangs the app forever or can trash arbitrary paths as root. Fix C1–C5 first, then H1–H3 (wrong-file matching, silent failures, root Trash). The SwiftUI structure and XPC protocol split are otherwise reasonable for a project this size.