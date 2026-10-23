# Code Review Report: CullApp
Generated: 2026-10-24T00:25:34.753751

I've read all 11 source files, the plists, entitlements, and `project.yml`. Report below.

---

# Code Review: CullApp

## 1. CRITICAL

### C1. Privileged helper runs as root with an unrestricted "trash any path" API
**`Sources/PrivilegedHelper/HelperDelegate.swift:44-60`**

`trashFiles(_ paths:)` accepts an arbitrary `[String]` from the XPC client and calls `FileManager.trashItem` as root with zero validation — no allowlist of prefixes (`/Library`, `/private/var/db`, `/System/Library/LaunchDaemons`), no rejection of critical system paths, no check that the path is a leftover associated with the app being uninstalled. The client is trusted only by code-signing identity, so any compromise of the app (or a bug in the scan logic) becomes an arbitrary root-level file-move primitive.

**Fix:** validate inside the helper: canonicalize with `URL(fileURLWithPath:).standardized.resolvingSymlinksInPath()`, reject any path not under a small allowlist, reject `/System`, `/usr`, `/bin`, `/Applications` etc., and pass the *bundle identifier* to the helper so it can re-derive and verify the candidate paths itself. Never let the client send raw paths.

### C2. Helper is a flat Mach-O, not a bundle — SMJobBless will not work
**`project.yml:53-74`, postBuildScript `42-51`**

SMJobBless requires the helper to be a **code-signed bundle** with a valid `Info.plist` (`CFBundleIdentifier`, `SMAuthorizedClients`) and a `Contents/MacOS/<name>` executable. Here the helper target is `type: tool`, producing a bare executable that the script copies to `Contents/Library/LaunchServices/`. A flat binary there has no `Info.plist`, so `SMJobBless` fails ("helper does not support the specified job"), and the `SMAuthorizedClients` array in `Sources/PrivilegedHelper/Info.plist` is **never read** — the file is dead weight. The `-sectcreate __TEXT __launchd_plist` trick only works for manually-installed daemons, not SMJobBless.

**Fix:** change the target to `type: bundle` (or `app-extension`-style helper bundle) with the executable in `Contents/MacOS/`, `CFBundleIdentifier = com.cullapp.CullApp.PrivilegedHelper`, and embed at `Contents/Library/LaunchServices/com.cullapp.CullApp.PrivilegedHelper.bundle`. Keep `SMAuthorizedClients` in that bundle's `Info.plist`. Verify with `SMJobBless` before shipping.

### C3. Root-owned files are trashed into *root's* Trash, not the user's
**`Sources/PrivilegedHelper/HelperDelegate.swift:51`**

The helper runs as root, so `trashItem` moves files to `/var/root/.Trash`. The user can never see or restore them, yet the UI promises "Files can be restored from the Trash afterwards" (`ContentView.swift:296`). This silently breaks the core promise of the app.

**Fix:** either (a) move root-owned leftovers to a dedicated, user-readable location (e.g. `/Library/Application Support/CullApp/Trash` with user-writable permissions, surfaced in the app), or (b) have the helper `chown`/`chmod` the trashed item to the invoking user (pass the user's uid/uid via the XPC call) so it lands in the user's Trash. Prefer (a) — it is what most uninstallers do.

---

## 2. HIGH

### H1. Substring matching produces false positives that get deleted
**`Sources/App/FileScanner.swift:71-80`**

`lowerName.contains(lowerAppName)` matches any filename containing the app name anywhere: app "Mail" → `MailPlugin`, `MailData`; app "Notes" → `NotesSync`, `OneNote`. Combined with the app name being derived from a **user-supplied** dropped bundle (attacker-controlled string), a crafted `Foo.app` can make CullApp trash unrelated user data. There is no per-item selection or uncheck affordance in the UI (`ContentView.swift:98`), so every false positive is deleted on confirm.

**Fix:** require exact name match (plus optional suffix variants like `Name Helper`, `Name.app`); treat bundle-ID matches as high-confidence and name matches as low-confidence; show a confidence/toggle per item with all low-confidence matches **deselected by default**.

### H2. Sandbox entitlements are insufficient for the app's core operations
**`Resources/CullApp.entitlements`**

- Missing `com.apple.security.files.user-selected.read-write` — without it, `trashItem` on the dropped `.app` (which lives outside the container) will fail under App Sandbox.
- `FileScanner` reads `~/Library/Application Support`, `Caches`, `Preferences`, `Logs`, `Containers`, `Saved Application State`, `WebKit`. A sandboxed app is confined to its own container; these `contentsOfDirectory` calls will return `nil` and be swallowed by `try?` at `FileScanner.swift:53` — so the scan finds **nothing** and reports "Found 0 files" with no error.
- `/Library/*` paths (the `rootFiles` path, `FileScanner.swift:34-38`) are unreachable from the sandbox without the helper — the helper only ever receives paths, so this is fine, but the *user-visible* scan list is not.

**Fix:** add `com.apple.security.files.user-selected.read-write`; for Library access use security-scoped bookmarks (persist with `com.apple.security.files.bookmarks.app-scope`) or a `NSOpenPanel`-granted extension, and surface a clear error when a root cannot be enumerated instead of silently returning `[]`.

### H3. `withCheckedContinuation` can hang forever if the helper dies
**`Sources/App/PrivilegedHelperClient.swift:46-53`**

If the helper crashes, is killed, or the connection is interrupted before invoking the reply block, the continuation is never resumed → the app is stuck in `isDeleting = true` with no way out. Same for `remoteObjectProxyWithErrorHandler` errors: they are only `print`ed, never surfaced.

**Fix:** wrap the continuation in a timeout (`withTaskGroup` racing a `Task.sleep`, or `withCheckedThrowingContinuation` + `DispatchQueue` timeout) and return a typed `Result`; surface helper errors in `resultMessage` instead of `print`.

### H4. Errors are swallowed; the result dialog always claims success
**`Sources/App/ContentView.swift:195-249`**

Per-file failures in the user-owned loop are only `print`ed (line 219); the helper's `errorMessage` is only `print`ed (`PrivilegedHelperClient.swift:49`). The dialog then reports "Moved N items to Trash" with no mention of failures, and `installHelperIfNeeded()` returns `void` — its failure is invisible, so a helper that failed to install silently yields "Moved 0 items".

**Fix:** collect `(path, error)` failures, count them, and render "Moved N of M items (K failed)" plus the failed paths. Make `installHelperIfNeeded()` return `Result`/`Bool` and abort the root-file phase with a clear message on failure.

### H5. `installHelperIfNeeded` re-blesses on every delete
**`Sources/App/PrivilegedHelperClient.swift:12-35`**

SMJobBless is called unconditionally whenever root files exist. Once installed, re-blessing can trigger a fresh admin prompt or fail with "already installed". Use `SMJobCopyDictionary` to check for an installed, version-matching helper and skip blessing; only bless when absent or outdated.

### H6. Caller authorization should bind audit ID, not just PID
**`Sources/PrivilegedHelper/HelperDelegate.swift:6-17`**

`SecCodeCopyGuestWithAttributes` with only `kSecGuestAttributePid` is weaker than Apple's documented pattern and is susceptible to PID-reuse races. Add `kSecGuestAttributeAudit: connection.auditSessionIdentifier` to the attributes dictionary, and require `SecCodeCheckValidity` against a requirement built once (not recompiled per connection).

### H7. Duplicate results across multiple dropped apps
**`Sources/App/ContentView.swift:173-184`**

`allItems.append(contentsOf: items)` with no cross-app dedup. Two dropped apps frequently match the same leftover → the same path appears twice, is trashed twice (second attempt errors), and its size is double-counted in `totalSize` and in the freed-space figure.

**Fix:** accumulate into a `[String: FileItem]` keyed by path (matching `FileScanner`'s internal `seenPaths`).

---

## 3. MEDIUM

### M1. Progress bar math is wrong
**`ContentView.swift:212`** — `progress = Double(index) / Double(scanResults.count)` inside a loop over `userFiles`; the ratio never reflects the real fraction and can exceed 1.0. Use `Double(index) / Double(userFiles.count)` and a separate phase for the helper step. Also guard the `droppedApps.count` divisor at line 179 against zero.

### M2. `SMJobBless` authorization ref carries no rights
**`PrivilegedHelperClient.swift:14`** — `AuthorizationCreate(nil, nil, [], &authRef)` requests no rights, so the privileged-helper install right may not be granted and the prompt may never appear. Request `kAuthorizationRightExecute` (or the documented SMJobBless right) and check `AuthorizationGetAuthorizationStatus` before calling.

### M3. Drop handler accepts any `.app` path without validating it is an application bundle
**`ContentView.swift:397`** — only `pathExtension == "app"` is checked; the bundle may not have an `Info.plist`, may be a symlink, or may be a directory named `x.app`. Since `bundleIdentifier` then resolves to `nil` (`FileScanner.swift:23`) and matching falls back to name-only (H1), this widens the false-positive surface. Validate `Bundle(url:)` exists, has a bundle identifier, and that the URL is not a symlink; resolve symlinks before use.

### M4. Directory size enumeration is slow and undercounts
**`FileScanner.swift:90-104`** — the enumerator uses `.skipsHiddenFiles` (so sizes are under-reported) and walks the entire tree for every match, including the dropped app bundle and any `~/Library/Containers/com.apple.*` directory. Combined with the sequential scan this can block the scan for seconds. Use `FileManager.attributesOfItem(atPath:)` `.totalFileAllocatedSize` for directories (available on APFS) as a fast path, and cap the enumeration depth.

### M5. `getpwuid` is not thread-safe and is deprecated
**`FileScanner.swift:110`** — `getpwuid` returns a pointer to static storage; use `getpwuid_r` with a local buffer, or resolve the uid→name mapping once at startup. `getpwuid`/`pw_name` are also unavailable under some future SDKs.

### M6. `owner == "root"` string comparison for privilege routing
**`ContentView.swift:203-204`** — routing on the literal username "root" is brittle. Compare `ownerAccountID == 0` instead and carry the uid on `FileItem`. Files owned by other accounts (`_spotlight`, `staff`) currently fall into the *user* bucket and will fail to trash.

### M7. Redundant helper binary in the app bundle
**`project.yml:38-41`** — the `copy:` block places the helper in `Contents/Resources` while the postBuildScript also places it in `Contents/Library/LaunchServices`. Only the latter is correct; remove the `copy:` block. Also `Sources/App/main.swift` and `Sources/App/CullAppApp.swift` hold the AppKit bootstrap and `AppDelegate` respectively — the latter is misnamed.

### M8. Deployment target mismatch
`project.yml:5,12` sets macOS 12.0 while `CLAUDE.md` specifies macOS 14+. Reconcile — the `@Observable`/SwiftUI APIs implied by the doc require 14.

### M9. App Store eligibility risk with SMJobBless
The stated goal is Mac App Store distribution. Apple generally expects App Store apps to be self-contained and does not permit installing privileged helpers via SMJobBless; MAS submissions using SMJobBless are commonly rejected. Confirm Apple's current position **before** investing further in C2/H5 — if MAS is off the table, the helper design can be simplified considerably.

---

## 4. MINOR

- **`ContentView.swift:408`** — `onDrop` returns `true` whenever any provider was dropped, even if none were `.app`; the UI shows an accepted drop that silently does nothing. Return `false` if no provider yielded a valid app.
- **`ContentView.swift:392`** — `_ = provider.loadObject(ofClass: URL.self)` uses the deprecated completion-handler form; use `loadItem(forTypeIdentifier:)` or the async API.
- **`ContentView.swift:172, 200`** — `Task { }` is not bound to the view's lifetime; the scan/delete continues after the window closes and mutates state afterwards. Tie it to `.task`/an `@State` task handle and cancel on disappear.
- **`ContentView.swift:224-236`** — the root-file phase gives no progress feedback while the helper runs; add a determinate/indeterminate state.
- **All files** — use `os.Logger` / `Logger` instead of `print` for diagnostics; `print` to stdout is invisible in released MAS builds.
- **`FileScanner.swift:47`** — `items.sorted { $0.path < $1.path }` sorts by raw path; sorting by root then name would read better in the UI.
- **`XPCProtocol.swift:8-10`** — `AppProtocol` is declared and never implemented anywhere; remove it.
- **No test target** exists in `project.yml`; the scan-matching rules (H1) are exactly the logic worth unit-testing.

---

**Summary:** The app does not yet work end-to-end as designed — the helper is not SMJobBless-installable (C2), root-deleted files are unrecoverable (C3), the sandbox will prevent both the Library scan and the app-bundle trash (H2), and the match rules will delete unrelated user data (H1). C1–C3 and H1–H2 should be fixed before any release; the rest are cleanup.