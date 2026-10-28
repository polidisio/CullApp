# Code Review Report: CullApp
Generated: 2026-10-29T00:01:45.029708

I've read all 12 source files. Here's the report.

---

# CullApp Code Review

## 1. CRITICAL (must fix)

### C1. Root helper trashes arbitrary paths — no path validation
**File:** `Sources/PrivilegedHelper/HelperDelegate.swift:44-60`

The privileged helper accepts any path string from the client and trashes it as root. The only check (`isCallerAuthorized`) validates the *caller's* code signature, not the *target*. Since the client is the app itself and the app can be tricked into passing arbitrary paths, anything in the filesystem is reachable: `/etc/passwd`, `/Library/...`, user data of unrelated apps.

**Fix:** In the helper, enforce an allowlist before trashing:
```swift
private let allowedRoots = ["/Library/Application Support/", "/Library/Caches/",
                           "/Library/Preferences/", "/Library/LaunchAgents/",
                           "/Library/LaunchDaemons/"]
```
Reject any path that isn't under one of those roots, and resolve symlinks (`URL.resolvingSymlinksInPath()`) *before* the prefix check to block `/Library/Caches/evil -> /etc` style escapes. Also re-validate at delete time, not only at scan time (TOCTOU).

### C2. XPC call hangs forever if the helper is missing or unreachable
**File:** `Sources/App/PrivilegedHelperClient.swift:39-53`

`withCheckedContinuation` is resumed only from the `withReply` block. If the helper isn't installed, the mach service doesn't exist, or the connection is invalid, the `remoteObjectProxyWithErrorHandler` block fires and merely `print`s — the continuation is never resumed. The `Task` in `deleteFiles` never completes, `isDeleting` stays `true`, and the whole UI is permanently disabled with no way out except relaunching.

**Fix:** Resume the continuation from the error handler too, and add a timeout:
```swift
let proxy = conn.remoteObjectProxyWithErrorHandler { error in
    continuation.resume(returning: false)   // resume exactly once
}
```
Wrap in a `withThrowingTaskGroup` race against `Task.sleep(for: .seconds(15))` so a stuck helper can't hang the UI.

### C3. Missing `com.apple.security.files.user-selected.read-write` entitlement
**File:** `Resources/CullApp.entitlements`

The app is sandboxed (`ENABLE_APP_SANDBOX: YES`) but has no user-selected-files entitlement. Without it, the drag & drop zone cannot read the dropped `.app`, `Bundle(url:)` returns nil (so bundle-ID matching silently degrades to name matching), and `trashItem` on the bundle fails.

**Fix:** Add:
```xml
<key>com.apple.security.files.user-selected.read-write</key><true/>
```

---

## 2. HIGH (should fix)

### H1. Substring matching causes destructive false positives
**File:** `Sources/App/FileScanner.swift:71-80`

`lowerName.contains(lowerAppName)` matches any file whose name merely *contains* the app name. Dropping `Notes.app` matches `NotesSync`, `Google Keep Notes Export`, `meetingnotes.db`… Those get permanently deleted. A one-character app name ("X") matches a huge fraction of `~/Library`.

**Fix:** Require a token-boundary match rather than substring:
```swift
let nameMatches = lowerName == lowerAppName
    || lowerName.hasPrefix(lowerAppName + ".")
    || lowerName.hasPrefix(lowerAppName + "-")
    || lowerName.hasSuffix("." + lowerAppName)
```
For bundle IDs, require an exact match on `<bundleID>` or `<bundleID>.plist`.

### H2. Mach service name is not App Store compliant
**Files:** `Resources/launchd.plist:9`, `Sources/PrivilegedHelper/main.swift:3`, `Sources/App/PrivilegedHelperClient.swift:7`

For Mac App Store distribution, mach service names must be prefixed with the Team ID, and the app must use `com.apple.security.temporary-exception.mach-lookup.global-name` only for *outside-the-store* distribution — Apple's docs state this entitlement is **not available to Mac App Store apps**. The current setup will be rejected at submission, which is the stated project goal.

**Fix:** Rename the service to `<TeamID>.com.cullapp.CullApp.PrivilegedHelper` in `launchd.plist`, `main.swift`, `PrivilegedHelperClient.swift`, and the entitlements, and remove the `temporary-exception.mach-lookup.global-name` entitlement in favour of the app-group mechanism.

### H3. SMJobBless is called unconditionally on every delete, and failures are silent
**File:** `Sources/App/PrivilegedHelperClient.swift:12-35`

`installHelperIfNeeded` calls `SMJobBless` every time root files exist, even when the helper is already installed (error 106) — it only `print`s the failure. The user gets no indication that authorization failed; the subsequent `trashFiles` then hangs (C2).

**Fix:** Check installation state first via `SMJobCopyDictionary`, only bless when absent, and surface the real error to the UI (the error is currently confined to stdout, which is invisible in a sandboxed App Store build).

### H4. Authorization is created with no rights and never rights-copied
**File:** `Sources/App/PrivilegedHelperClient.swift:14`

`AuthorizationCreate(nil, nil, [], &authRef)` yields an authorization ref with no granted right, and `AuthorizationCopyRights` is never called. SMJobBless then has no right to elevate.

**Fix:**
```swift
var rights = AuthorizationRights([kAuthorizationRightExecute])
var authRef: AuthorizationRef?
AuthorizationCreate(nil, nil, &rights, &authRef)
var cfError: Unmanaged<CFError>?
AuthorizationCopyRights(authRef, &rights, kAuthorizationEnvironmentDefault,
                         AuthorizationFlags([.interactionAllowed, .preUI]), &cfError)
```
`SMJobBless` should also be given a `kSMJobBlessOptionAuthorization` so it uses this right.

### H5. Root/user ownership split is fragile and misclassifies inaccessible files
**File:** `Sources/App/ContentView.swift:203-204`, `Sources/App/FileScanner.swift:106-119`

Ownership is inferred from the owner *name* string (`"root"`). Any lookup failure returns `"unknown"`, and `unknown != "root"`, so unreadable `/Library` paths are classified as **user-owned** and sent straight to the sandboxed `trashItem`, where they fail. Root files are therefore routinely misrouted.

**Fix:** Determine root-ownership by *path prefix* (`/Library/…`), not by owner lookup. Keep the owner string purely for display.

### H6. All deletion errors are swallowed — the user is shown a false success
**File:** `Sources/App/ContentView.swift:215-220, 238-247`

Failures are `print`ed to stdout only. The result card always says "Moved N items to Trash and freed X", with no indication that items failed or that the helper was never reached. In a sandboxed App Store build, stdout is invisible, so the user believes files were deleted when they weren't.

**Fix:** Collect failures and surface a count of failures plus the first few error messages in the result card (and log via `os.Logger` instead of `print`).

---

## 3. MEDIUM (consider fixing)

### M1. Directory sizes are computed by full recursive enumeration — slow and inaccurate
**File:** `Sources/App/FileScanner.swift:82-104`

`sizeOf` enumerates every file in the dropped `.app` bundle and every matched directory to compute sizes, then enumerates them *again* implicitly through `getOwner`. `.skipsHiddenFiles` excludes hidden files, so totals under-report (the "freed X" figure shown to the user is wrong). Enumerating large bundles on every scan is the main latency source.

**Fix:** Use `URL.resourceValues(forKeys: [.fileAllocatedSizeKey])` on the directory itself for a cheap total, or cache sizes. Drop `.skipsHiddenFiles` if accuracy matters, and compute size in a single pass rather than per-item.

### M2. `getConnection()` can store a dead connection
**File:** `Sources/App/PrivilegedHelperClient.swift:56-76`

`connection = conn` happens *after* `conn.resume()`. If the invalidation handler fires between resume and assignment, `removeConnection()` nils an already-nil field, then the stale connection gets stored and reused forever.

**Fix:** Assign `connection = conn` before `conn.resume()`, and guard `removeConnection` with an identity check (`if self.connection === conn`).

### M3. `.privileged` NSXPCConnection option is deprecated
**File:** `Sources/App/PrivilegedHelperClient.swift:61`

`options: .privileged` has been deprecated since macOS 10.14 and is ignored by modern launchd-managed mach services.

**Fix:** Use `NSXPCConnection(machServiceName:)` with no options; privilege comes from the launchd `MachServices` declaration.

### M4. Caller authorization should be enforced per-message, not per-connection
**File:** `Sources/PrivilegedHelper/HelperDelegate.swift:20-24`

Validating the client's code signature once at connection time leaves a window where the connection outlives the validating process. `SecCodeCopyGuestWithAttributes` with just a PID is also weaker than using the connection's audit token.

**Fix:** Call `newConnection.setCodeSigningRequirement(requirement)` — the system then re-validates on every message and invalidates the connection automatically.

### M5. Scan runs only one level deep and skips hidden entries
**File:** `Sources/App/FileScanner.swift:50-69`

`contentsOfDirectory` with `.skipsHiddenFiles` misses dot-directories, and matches are only found at the top level of each search root, so nested leftovers (e.g. `~/Library/Application Support/Foo/bar.db`) are never listed.

**Fix:** Consider a bounded recursive search (depth 2–3) and drop `.skipsHiddenFiles` for the Application Support / Caches roots.

### M6. `getpwuid` is not thread-safe
**File:** `Sources/App/FileScanner.swift:110`

`getpwuid` returns a pointer to a static buffer. It's currently serialized by the actor, but `getpwuid_r` (or `getpwuid` + immediate copy) is the safe API and avoids a latent crash if the scanner is ever used from multiple tasks.

### M7. Unused protocol and dead code
**Files:** `Sources/Shared/XPCProtocol.swift:8-10`, `Sources/PrivilegedHelper/HelperDelegate.swift:62-64`

`AppProtocol` is never used, and `getVersion` is implemented but never called. `getVersion` is a reasonable liveness probe though — wire it up as the ping that replaces the C2 hang.

### M8. `print` used for all logging
**Files:** `PrivilegedHelperClient.swift:16,30,41,49`, `ContentView.swift:219`, `HelperDelegate.swift`

`print` is unavailable in Release/App Store builds for diagnostics. Use `os.Logger` with a dedicated subsystem so failures are diagnosable.

---

## 4. MINOR (nice to have)

- **`project.yml:5`** — deployment target is macOS 12.0, but CLAUDE.md states macOS 14+. Reconcile; `SMJobBless` and modern APIs are fine on 12, but the docs and build disagree.
- **`project.yml:36-41`** — the helper is copied both via the `copy:` dependency and the `postBuildScripts` step, producing a duplicate binary inside `Contents/Resources`. Drop one.
- **`FileScanner.swift:22`** — `appURL.deletingPathExtension().lastPathComponent` gives "Foo" for "Foo.app", but "Foo.bar" for "Foo.bar.app". Use `appURL.deletingPathExtension()` consistently or read `CFBundleName`.
- **`FileScanner.swift:23`** — no validation that the dropped URL is actually a bundle directory. `ContentView.swift:397` only checks the `app` extension, so a *file* named `foo.app` is accepted.
- **`ContentView.swift:196-406`** — `provider.loadObject` results are handled with `DispatchQueue.main.async` but the completion isn't retained; consider `NSItemProvider` with a proper `loadItem` and a uniform type check for `com.apple.application-bundle`.
- **`ContentView.swift:212`** — `Double(index) / Double(scanResults.count)` and `ContentView.swift:179` `Double(index) / Double(droppedApps.count)` can divide by zero if the list is cleared between the button press and the `Task` body running. Guard with `max(1, count)`.
- **`Resources/CullApp-Info.plist`** — no `CFBundleIconName`, `LSApplicationCategoryType`, or `NSHighResolutionCapable`. Also worth verifying Xcode injects `CFBundleExecutable` into a custom `INFOPLIST_FILE`.
- **`ContentView.swift:15-21`** — `FileItem.id` is a fresh `UUID()` per item, so SwiftUI loses identity across rescans and animations flicker. Use the path as the `id`.

---

**Overall:** the architecture is sound, but C1 (root helper with no path allowlist) is a genuine privilege-escalation-class flaw and must be fixed before shipping, together with C2 (the UI-hanging continuation) and C3 (the missing entitlement, which likely means drag & drop doesn't work in a sandboxed build at all).