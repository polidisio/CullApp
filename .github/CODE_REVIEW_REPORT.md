# Code Review Report: CullApp
Generated: 2026-10-25T00:02:10.894415

I've read all the source files. Here's my review.

# Code Review — CullApp

## 1. CRITICAL issues

### C1. Sandboxed app scans its own container instead of the real home directory
**`Sources/App/FileScanner.swift:25`**
```swift
let home = FileManager.default.homeDirectoryForCurrentUser
```
In a sandboxed process (`ENABLE_APP_SANDBOX: YES`, `project.yml:33`), `homeDirectoryForCurrentUser` resolves to the app's *container* (`~/Library/Containers/com.cullapp.CullApp/Data`), not the user's real home. Every `~/Library/...` search root is therefore wrong and the scan finds nothing outside the container.
**Fix:** resolve the real home explicitly, e.g. `NSHomeDirectoryForUser(NSUserName())`, or `confstr(_CS_DARWIN_USER_DIR)`.

### C2. Missing `com.apple.security.files.user-selected.read-only` entitlement → drag & drop cannot read the `.app`
**`Resources/CullApp.entitlements`**
A sandboxed app may only read files the user explicitly selected via the powerbox. Without this entitlement the dropped `.app` URL is unreadable: `NSWorkspace.shared.icon(forFile:)` returns a generic icon and `Bundle(url:)` returns nil.
**Fix:** add `com.apple.security.files.user-selected.read-only`. Note this grants access to the dropped app only — leftovers in `~/Library` still need a temporary-exception entitlement (see C3).

### C3. No entitlement to trash leftover files outside the container
**`Resources/CullApp.entitlements`, `Sources/App/ContentView.swift:216`**
`FileManager.default.trashItem` on `~/Library/Caches/com.foo.bar` will fail under sandbox regardless of C2 — the app has no write access to arbitrary `~/Library` subpaths. The root-files path via the helper works only because the helper is unsandboxed, but *user* leftovers will always fail silently (the `catch` only `print`s).
**Fix:** add `com.apple.security.temporary-exception.files.absolute-path.read-write` for the scanned `~/Library/*` roots (App Store requires justification), **and** surface failures in the UI (see H3).

### C4. Root helper will trash *any* path it is given — no path allowlist
**`Sources/PrivilegedHelper/HelperDelegate.swift:44-60`**
```swift
for path in paths { try FileManager.default.trashItem(at: url, ...) }
```
The helper runs as root and performs zero validation of `paths`. A bug in the client (or a client with a matching identifier) can move `/etc/passwd`, `/System/Library/...`, or a user's `~/Documents` to the Trash as root. This is the highest-impact bug in the codebase.
**Fix:** in the helper, canonicalize (`resolvingSymlinksInPath`), then require the path to be under an explicit allowlist of prefixes — `/Library/Application Support/`, `/Library/Caches/`, `/Library/Preferences/`, `/Library/LaunchAgents/`, `/Library/LaunchDaemons/`, `/Library/Logs/` — and explicitly reject anything under `/System`, `/usr`, `/bin`, `/etc`, `/var` (except `/var/db` style allowlist if ever needed). Also reject paths equal to the caller's own bundle.

### C5. Trashing the dropped `.app` is not validated — a symlink named `X.app` can delete an arbitrary directory
**`Sources/App/ContentView.swift:397-399`, `Sources/App/FileScanner.swift:20`**
The drop handler accepts any URL whose extension is `app`, then `FileScanner.add(appURL.path, isDirectory: true)` puts it straight into the delete list and `trashItem` moves it. Dropping a symlink `~/Documents/Photos.app → ~/Documents` would trash the user's Documents folder.
**Fix:** verify the dropped URL is a real bundle (`Bundle(url:)?.bundleIdentifier != nil`, `Contents/MacOS` exists), and resolve symlinks before adding it to the delete list.

## 2. HIGH issues

### H1. XPC continuation can never resume → UI hangs forever in "Moving files to Trash"
**`Sources/App/PrivilegedHelperClient.swift:39-53`**
The proxy's `errorHandler` only prints; if the helper is missing, dies, or the reply block never fires, `withCheckedContinuation` never resumes. The `Task` in `ContentView.deleteFiles` awaits it, `isDeleting` stays `true`, and every button stays disabled — a hard UI deadlock with no recovery.
**Fix:** use `withCheckedThrowingContinuation`, resume from the error handler and from `connection.interruptionHandler`, and add a timeout (e.g. `Task` + `withThrowingTaskGroup` racing a `sleep`). Also surface the failure to the user instead of `print`.

### H2. Loose substring matching causes false-positive deletions
**`Sources/App/FileScanner.swift:71-80`**
```swift
return lowerName.contains(lowerAppName)
```
An app named `Mail` matches `Mailbox`, `MailItems`, `SparkleMail`; `Safari` matches `SafariTechnologyPreview`; `System` matches dozens of entries. Combined with C4, a drop can trash unrelated applications' support files and launch daemons.
**Fix:** prefer exact match on the bundle-ID-named entry (e.g. `com.foo.bar` in `~/Library/Containers`, `~/Library/Preferences/com.foo.bar.plist`) and exact/prefix matching on the app name; keep fuzzy matching only as an opt-in "search more" mode, clearly labeled.

### H3. Failed deletions are invisible to the user
**`Sources/App/ContentView.swift:215-220`**
```swift
} catch { print("Failed to trash \(item.path): \(error)") }
```
The final message reads *"Moved N items to Trash"* regardless. Users who hit sandbox failures (C3) will be told everything succeeded.
**Fix:** collect failures and report `Moved N items (M failed: …)`. Keep the failed items in `scanResults` so they can be retried.

### H4. Helper installs to the wrong place / install result is ignored
**`Sources/App/PrivilegedHelperClient.swift:12-35`, `project.yml:44-51`**
`installHelperIfNeeded()` calls `SMJobBless` unconditionally (no `isHelperInstalled` check), ignores the error result, and returns immediately — the mach service may not be registered yet when `trashFiles` is called right after, so the first attempt typically fails. Also, `AuthorizationFree` is skipped on the `guard` early-return path.
**Fix:** check installation status first, treat `kSMJobBlessErrorAlreadyExists` as success, retry the XPC connection with backoff for a few seconds after install, and free the auth ref on all paths.

### H5. `SMJobBless` requirement is unusable for local/development builds
**`Resources/CullApp-Info.plist:22-25`, `Sources/PrivilegedHelper/HelperDelegate.swift:4`**
`anchor apple generic` requires an Apple-signed (Mac App Store) signature. Every local build of the helper will fail the check in `isCallerAuthorized`, so the "helper installs via SMJobBless" metric cannot be verified outside the MAS build.
**Fix:** use the team-scoped requirement for dev builds (`anchor apple generic and identifier "…" and certificate leaf[subject.OU] = "TEAMID"`, or a `#if DEBUG` alternate) and keep the strict requirement for release.

### H6. Root-owned files land in `/var/root/.Trash`, not the user's Trash
**`Sources/PrivilegedHelper/HelperDelegate.swift:51`**
`FileManager.trashItem` executed as root trashes into root's Trash, which the user cannot see or restore — contradicting the UI copy *"Files can be restored from the Trash afterwards."*
**Fix:** have the helper move root-owned files into the target user's `~/.Trash` explicitly (creating it with the correct ownership), or delete directly and report that clearly.

## 3. MEDIUM issues

### M1. No `AppIcon` and missing App Store `Info.plist` keys
**`Resources/Assets.xcassets` (no `AppIcon.imageset`), `Resources/CullApp-Info.plist`**
There is no `AppIcon` asset and no `CFBundleIconFile`/`CFBundleIconName` key. The App Store build will be rejected. `LSApplicationCategoryType` and `NSHumanReadableCopyright` format are also missing/naive.
**Fix:** add an `AppIcon` imageset with all required sizes, and add `CFBundleIconName`, `LSApplicationCategoryType`, `LSApplicationCategoryType` = `public.app-category.utilities`.

### M2. Scan runs slow, blocking, and cannot be cancelled
**`Sources/App/FileScanner.swift:82-104`**
`sizeOf` recursively enumerates every matched directory (including the full `.app` bundle) with `resourceValues` per file, and `matches` does a full `contentsOfDirectory` on 11 roots (`/Library/Caches` can hold tens of thousands of entries). This all runs synchronously inside the `FileScanner` actor, blocking a cooperative-pool thread. There is no cancellation check, so a scan cannot be stopped.
**Fix:** compute directory sizes with a single `enumerator` pass, hoist `resourceValues` reads, skip the `~/Library/Containers` deep enumeration (huge), and add a `Task.isCancelled` check in the loop.

### M3. `.skipsHiddenFiles` under-reports sizes and misses real leftovers
**`Sources/App/FileScanner.swift:56, 93`**
Hidden files inside an app bundle and hidden directories in `~/Library` are excluded, so the displayed "freed space" is understated and legitimate leftover data is missed.
**Fix:** drop `.skipsHiddenFiles` for the enumerator (keep it only for the top-level directory listing if desired), or report it as an estimate.

### M4. Scan task is not cancelled when the user hits "Clear" or drops a new app
**`Sources/App/ContentView.swift:166-193`**
The `Task` is fire-and-forget with no handle stored. Pressing "Clear" mid-scan lets the scan finish afterwards and repopulate `scanResults` with stale results for apps the user already dismissed — and the stale list is then deletable.
**Fix:** store the `Task` in `@State` and `.cancel()` it on clear/re-scan/reset; check `Task.isCancelled` before assigning results.

### M5. `owner != "root"` misclassifies system-owned files
**`Sources/App/ContentView.swift:203-204`**
Ownership is compared against the literal string `"root"`. Files owned by `wheel`, `_spotlight`, `daemon`, or `"unknown"` (when `attributesOfItem` fails, e.g. permission-denied) are treated as *user* files and sent to the sandboxed app, which then fails to delete them. Conversely, if `getOwner` returns `"unknown"` for a genuinely root-owned file, it will never be routed to the helper.
**Fix:** compare uids numerically against `0` rather than by username; propagate the uid in `FileItem` instead of a display string.

### M6. `Application Support` and `Preferences` in `/Library` are scanned but there is no matching home-directory counterpart for all roots
**`Sources/App/FileScanner.swift:26-39`**
The list is inconsistent: `/Library/Logs` is missing, `~/Library/Group Containers` is missing (group-container data is a common leftover), and `~/Library/Saved Application State` is included while its `/Library` counterpart is not.
**Fix:** make the root list symmetric and add `~/Library/Group Containers`.

### M7. XPC reply semantics lose partial-failure information
**`Sources/App/Shared/XPCProtocol.swift:4`, `Sources/PrivilegedHelper/HelperDelegate.swift:58`**
`trashFiles` returns a single `Bool` that is `true` only if *all* paths succeeded, plus a single `lastError` string for possibly many failures. The client then drops all root files from the "deleted" list even if some were moved.
**Fix:** return a per-path result (`[String: Bool]` or a list of failed paths).

### M8. `AppProtocol` is dead code
**`Sources/Shared/XPCProtocol.swift:8-10`**
`AppProtocol` is declared and never used by either side. Remove it.

### M9. `ContentView.swift:408` — drop acceptance is reported incorrectly
```swift
return !providers.isEmpty
```
The drop is accepted even when no provider turns out to be a `.app`, so the UI shows an accepted drop that silently does nothing.
**Fix:** validate providers synchronously via `hasItemConformingToTypeIdentifier` and only accept `.app` items.

### M10. Deployment target disagrees with the documented target
**`project.yml:5`, `CLAUDE.md`**
`project.yml` sets macOS 12.0 while the project brief says macOS 14+. `Sources/App/CullAppApp.swift` also contains the `AppDelegate` only — the filename is misleading.
**Fix:** align `deploymentTarget` with the stated minimum; rename `CullAppApp.swift` to `AppDelegate.swift`.

## 4. MINOR suggestions

- **`Resources/CullApp-Info.plist` is listed both as `INFOPLIST_FILE` and as a resource** (`project.yml:25-26` with `buildPhase: none`) — the `resources` entry is redundant and confusing.
- **`OTHER_CODE_SIGN_FLAGS: "--identifier …"`** (`project.yml:74`) duplicates `PRODUCT_BUNDLE_IDENTIFIER`; remove it.
- **`print` used for all diagnostics** (`ContentView.swift:219`, `PrivilegedHelperClient.swift:16,30,40,49`) — use `os.Logger` with a dedicated subsystem so logs are filterable.
- **Global mutable-ish `byteFormatter`** (`ContentView.swift:23`) — `ByteCountFormatter` is not guaranteed thread-safe; it is only read here, so it is acceptable, but constructing it per call or scoping it to the main actor is safer.
- **`FileScanner` is an `actor` but does blocking synchronous I/O on its executor** — a `nonisolated` static function invoked from a background task would be more accurate.
- **No per-item selection** — the user can only delete the whole set; a checkbox list would reduce risk given H2.
- **`HelperDelegate` invalidation/interruption handlers are empty** (`HelperDelegate.swift:29-35`) — at minimum log them.

---

**Bottom line:** the codebase is clean and small, and the SwiftUI structure is reasonable, but it will not work as shipped: the sandbox/home-directory resolution (C1), the missing file-access entitlements (C2/C3), and the unvalidated root-privileged path handling (C4) must be fixed before the app can scan, delete, or be safe to submit. The XPC hang (H1) and the invisible failures (H3) are the next most urgent.