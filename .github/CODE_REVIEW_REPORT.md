# Code Review Report: CullApp
Generated: 2026-10-30T00:34:38.568923

I've reviewed all the Swift sources, plists, and entitlements. Here's the report.

---

# CullApp — Code Review

**Scope:** `Sources/App/*.swift`, `Sources/Shared/XPCProtocol.swift`, `Sources/PrivilegedHelper/*.swift`, `Resources/*.plist`, `Resources/*.entitlements`, `project.yml` (728 LOC Swift).

---

## 1. CRITICAL (must fix)

### C1. Privileged helper trashes to root's Trash — files become unreachable
`Sources/PrivilegedHelper/HelperDelegate.swift:51`

`FileManager.trashItem` executed as root relocates items to **`/var/root/.Trash`**, not the logged-in user's `~/.Trash`. Consequences:
- The user's Trash shows nothing; "Files can be restored from the Trash afterwards" (README:13, ContentView.swift:296) is false.
- The app is "uninstalled" but the data is still on disk and invisible — no reclaim of disk space, contrary to the UI's "freed X" claim.
- `/var/root/.Trash` is not auto-purged.

**Fix:** Have the helper *report* the absolute path of files it needs removed and let the **sandboxed app** perform `trashItem` (it has access to its own Trash). The helper's real job should be limited to *authorizing* and possibly `chown`ing the target to the user, then returning paths; the app moves them to the user's Trash. If root-level trashing is genuinely required, use `FileManager.default.trashItem` with an explicit `~/.Trash` destination, or delete and report honestly.

### C2. Root helper accepts arbitrary paths from the client — no validation
`Sources/PrivilegedHelper/HelperDelegate.swift:44-60`

`trashFiles(_ paths:)` will trash *any* path the XPC client supplies, with no allowlist, prefix check, ownership check, or symlink resolution. The only defense is the caller code-signature check (good), but there is no defense-in-depth if the sandboxed app is compromised or tricked into passing an unintended path (e.g. via a crafted bundle name, a symlinked leftovers dir, or a future code path that forwards user-controlled strings).

**Fix:** In the helper, canonicalize each path (`URL(fileURLWithPath:).resolvingSymlinksInPath()`), reject any path not under an explicit allowlist (`/Library/Application Support`, `/Library/Caches`, `/Library/Preferences`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`), require `stat().st_uid == 0`, and reject symlinks and paths whose parent is a symlink. Add a hard cap on the number of paths.

### C3. XPC error path never resumes the continuation → the UI hangs forever
`Sources/App/PrivilegedHelperClient.swift:39-53`

`withCheckedContinuation` is resumed **only** inside the reply block. If the connection fails (`remoteObjectProxyWithErrorHandler` fires) or the helper dies before replying, the error handler merely `print`s and the continuation is never resumed. The `deleteFiles()` `Task` hangs, `isDeleting` stays `true`, and the window is permanently disabled on "Moving files to Trash...".

**Fix:** Use `withTaskCancellationHandler` + a timeout, or restructure so the error handler resumes the continuation exactly once (guard with an atomic/lock flag). Also resume on `NSXPCConnection.invalidationHandler`.

### C4. Sandbox entitlement missing for drag & drop file access
`Resources/CullApp.entitlements`

The entitlements contain only `app-sandbox`, `application-groups` and the mach-lookup exception. Drag & drop of a file into a sandboxed app requires `com.apple.security.files.user-selected.read-only` (or `read-write`). Without it, `provider.loadObject(ofClass: URL.self)` may yield no access, `Bundle(url: appURL)?.bundleIdentifier` returns `nil` (killing bundle-ID matching — the app's headline feature), and `NSWorkspace.shared.icon(forFile:)` returns a generic icon.

**Fix:** Add:
```xml
<key>com.apple.security.files.user-selected.read-only</key><true/>
```
(Add `read-write` only if you actually write into dropped bundles.) Verify the real behaviour in a signed sandboxed build — do not assume.

---

## 2. HIGH (should fix)

### H1. `AuthorizationCreate` with empty rights/flags → SMJobBless fails, error swallowed
`Sources/App/PrivilegedHelperClient.swift:14-34`

`AuthorizationCreate(nil, nil, [], &authRef)` creates an authorization with **no interaction rights and no flags**. SMJobBless normally needs `.interactionAllowed` (+ `.extendRights`) so the admin prompt can appear; with `[]` it typically returns `errAuthorizationDenied`/`errAuthorizationFailed`. The result is `print`-ed and ignored, then `trashFiles()` proceeds and fails. The user sees "Moved 0 items" and never learns why.

**Fix:** Use the documented pattern:
```swift
let flags = AuthorizationRights.Flags([.interactionAllowed, .extendRights, .preAuthorize])
AuthorizationCreate(nil, nil, flags, &authRef)
```
Then **propagate** the failure: return `Bool`/`Result` from `installHelperIfNeeded()` and surface it in the UI.

### H2. Root detection by owner *name* instead of uid
`Sources/App/FileScanner.swift:106-119`, `Sources/App/ContentView.swift:203-204`

`getOwner` returns the string `"unknown"` when `attributesOfItem` throws — and in a sandbox, stat'ing root-owned files under `/Library` frequently fails. Such files are then classified as *user* files and sent down the unprivileged path, which cannot delete them → silent failure. Comparing `owner == "root"` is also brittle (uid 0 vs. name).

**Fix:** Return the numeric uid (`Int`), and classify as privileged when `uid == 0` **or** the path is under a system root. Distinguish "unknown" as its own category and route it to the helper.

### H3. Delete failures are swallowed
`Sources/App/ContentView.swift:215-220`, `238-247`

Per-file errors are only `print`ed. The result card unconditionally reports "Moved N items to Trash and freed X" — with no mention of failures, and `freedSize` counts only successes, so the message is at least honest about size but the user is never told that some files were not removed (including the app bundle itself).

**Fix:** Track failures, show "Moved N of M items (K failed)" and list the failed paths in the result card. Use `os.Logger` instead of `print`.

### H4. Substring filename matching causes over-deletion of unrelated data
`Sources/App/FileScanner.swift:71-80`

`lowerName.contains(lowerAppName)` matches *any* entry containing the app name as a substring. Dropping `Notes.app` matches `NotesSync`, `NotesTemplates`, `RemindersNotes`; a short/common name (e.g. `Mail.app`) matches many unrelated folders in `~/Library/Application Support`. Matching on the *raw* name (not lowercased bundle-ID form) plus `contains` is the worst combination. These unrelated directories are then trashed.

**Fix:** Match on (a) exact bundle ID equality (`com.foo.Bar` or `com.foo.Bar.*`), (b) exact app-name equality, and (c) app-name-with-known-suffix equality. Never use raw `contains` on a user-supplied short name. Additionally require the candidate to look like a leftover (e.g. contain the bundle ID prefix) before including it.

### H5. Likely sandbox home-directory / container redirect breaks scanning
`Sources/App/FileScanner.swift:25-39`

Under the App Sandbox, `~/Library/Preferences`, `~/Library/Caches` and `~/Library/Application Support` are redirected into the app container, and `FileManager.homeDirectoryForCurrentUser` may resolve to the container path. If so, `searchRoots` point at the container, the real user leftovers are never found, and the app silently reports "Found 1 files" (just the bundle itself).

**Fix:** Verify empirically in a signed sandboxed build which paths are actually reachable, and construct the roots from `NSHomeDirectory()`/`URL(fileURLWithPath:)` outside the container (with the `user-selected` and any `temporary-exception` entitlements needed). Silently-`try?`-swallowed failures in `matches()` make this failure invisible — log when a root cannot be listed.

### H6. Missing `temporary-exception` entitlements for `/Library` reads
`Resources/CullApp.entitlements`

Even reading `/Library/Application Support`, `/Library/Preferences`, `/Library/LaunchDaemons` from a sandbox is denied without `com.apple.security.temporary-exception.files.absolute-path.read-write` entries. Combined with H2, root-owned leftovers are never even discovered, so the privileged path is dead code in practice.

**Fix:** Add the required `absolute-path.read-write` exceptions (Apple grants these for App Store apps with a justification), or at minimum `read-only` for the scan roots.

### H7. The app deletes its own running bundle
`Sources/App/FileScanner.swift:20`, `Sources/App/ContentView.swift:216`

The `.app` bundle itself is added to the scan list and is trashed while the app is running. The process keeps running, but any later resource load from its own bundle (SwiftUI `Image(name:)` template icons, `Bundle.main` lookups) can fail or render blank — and the app is mid-operation with its own binary on disk gone.

**Fix:** Truncate the bundle *last*, and pre-load/cache any bundle resources the UI still needs (the icons are already in `NSImage` for dropped apps, but the template icons are not). Alternatively, relaunch-free approach: keep the bundle until the UI has torn down, then trash it.

---

## 3. MEDIUM (consider fixing)

### M1. Scanner only inspects the top level of each root and skips hidden files
`Sources/App/FileScanner.swift:53-57`
`contentsOfDirectory(... .skipsHiddenFiles)` — no recursion. Many apps store data in nested dirs (e.g. `~/Library/Application Support/Foo/Sub`, `~/Library/Caches/com.foo.Bar/…`), and hidden entries (`.DS_Store`-like dotfiles, `~/.foo`) are skipped. Coverage of the app's core promise ("finds all related files") is weak.

**Fix:** Recurse one or two levels with a depth cap, and match on the *full relative path* components rather than just the leaf name.

### M2. Duplicate `attributesOfItem` per file (2× stat) and repeated directory listings per app
`Sources/App/FileScanner.swift:82-119`, `FileScanner.swift:41-45`
Each candidate is stat'd once in `getOwner` and again in `sizeOf`; and with N dropped apps, all 12 search roots are enumerated N times (full `contentsOfDirectory` per root per app). For `~/Library/Application Support` this is noticeable.

**Fix:** Read attributes once (`resourceValues` with `.isDirectoryKey, .fileSizeKey, .ownerAccountIDKey` in one call), cache root listings for the lifetime of one scan pass, and compute directory sizes only for entries actually selected for display.

### M3. Blocking filesystem I/O inside an actor
`Sources/App/FileScanner.swift:5-48`
`actor FileScanner` performs synchronous `contentsOfDirectory` and full recursive enumeration on the cooperative executor. The actor provides no concurrency benefit here (no shared mutable state is needed) and the work blocks a cooperative thread.

**Fix:** Drop the actor, make it a `struct`/`enum` with `static` methods, and run the scan from a `Task.detached` (or `nonisolated` async function) so the main thread never blocks.

### M4. Progress denominator is wrong during deletion
`Sources/App/ContentView.swift:212`
`progress = Double(index) / Double(scanResults.count)` while `index` iterates `userFiles` — with root files present the bar never approaches 1.0 before the helper stage, and the helper stage doesn't advance it.

**Fix:** Use per-stage denominators, or compute overall progress as `(userDone + rootDone) / total`.

### M5. Helper returns only an all-or-nothing bool and the last error
`Sources/PrivilegedHelper/HelperDelegate.swift:44-60`
`successCount == paths.count` means one failure makes the whole batch look failed, and the client (`ContentView.swift:233`) then discards *all* root files from the `deleted` list even though most were trashed. Only the last error survives.

**Fix:** Return a result struct: `([String] succeeded, [String: String] failed)`, and have the app count each root file individually.

### M6. Connection lifecycle is not managed
`Sources/App/PrivilegedHelperClient.swift:56-80`
The connection is never invalidated on app termination, and a connection whose helper is not yet installed is cached and reused; the failure surfaces only as a printed XPC error. There is no "helper not installed" state in the UI, and `installHelperIfNeeded()` is called on every delete-with-root-files (prompting for auth repeatedly if the first install failed).

**Fix:** Track installation state, surface it in the UI, and invalidate the connection when the helper reports an error.

### M7. The app's own bundle is included in the scan list and shown as a deletable item
`Sources/App/FileScanner.swift:20`
Showing the `.app` in the "leftovers" list conflates the app with its residue; `/Applications/Foo.app` is typically root:admin so it will be routed to the helper (H2), and its size dominates the "freed space" number.

**Fix:** Exclude the bundle from the residue list and handle it as a separate, explicit step in the confirmation dialog ("Uninstall Foo.app and remove N leftover items").

### M8. Sandbox-consistency: `NSWorkspace.moveToTrash` vs `FileManager.trashItem`
`README.md:56` vs `Sources/App/ContentView.swift:216`
Docs and code disagree. `FileManager.trashItem` is the correct modern API, but the README should match the code.

---

## 4. MINOR (nice to have)

- **Dead code:** `AppProtocol` (`Sources/Shared/XPCProtocol.swift:8-10`) and `getVersion` (`HelperDelegate.swift:62`) are never used. Remove them, or wire `getVersion` into a helper-health check.
- **`droppedApps` de-duplication** uses `contains(where:)` at `ContentView.swift:402` while the type defines `Equatable` by URL (`ContentView.swift:10-12`) — use `Set`/`contains($0.url)` so the custom `==` is actually used.
- **Drop accepts non-app files:** `ContentView.swift:408` returns `!providers.isEmpty`, so the drop is "accepted" even when nothing is a `.app`. Return `false` if no provider yields a `.app` URL.
- **`getpwuid` is not thread-safe** (`FileScanner.swift:110`); use `getpwuid_r` or copy the name under a lock. It also leaks nothing but is non-reentrant — with M3 (parallel scanning) this becomes a real bug.
- **`FileItem.id` is a fresh `UUID` per scan** (`ContentView.swift:17`), so SwiftUI list identity churns on every scan and animations restart. Use the path as the `id`.
- **Deployment-target mismatch:** `project.yml:5` says macOS 12.0, README:35 says 14.0+, CLAUDE.md says 14+. Reconcile.
- **`byteFormatter` is a global `let` of a non-`Sendable` class** (`ContentView.swift:23`) — fine under Swift 5.9, but will warn under Swift 6 strict concurrency. Mark `@unchecked Sendable` or use `ByteCountFormatter` per call.
- **Log with `os.Logger`** instead of `print` throughout (`PrivilegedHelperClient.swift`, `ContentView.swift:219`) so failures are diagnosable from the unified log.
- **Helper `interruptionHandler`/`invalidationHandler` are empty** (`HelperDelegate.swift:29-35`) — log them and clean up state.
- **No `NSMenu`/About panel** in `Sources/App/main.swift` — the app has no menu bar, so Cmd-Q and standard shortcuts don't work in a bundled build.

---

## Summary

The happy path is thin but functional; the privileged path is **not production-ready**. The three blocking items are: the helper trashes into root's Trash (C1), the root helper trusts the client for paths (C2), and the XPC error path hangs the UI (C3). The sandbox configuration (C4, H5, H6) needs empirical verification in a signed build — that is the single highest-value next step, because if the container redirect applies, the scanner currently finds nothing outside the app container and the whole feature is inert in App Store builds.