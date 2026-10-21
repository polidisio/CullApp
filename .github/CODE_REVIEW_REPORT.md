# Code Review Report: CullApp
Generated: 2026-10-22T00:24:15.586631

I have a full picture of the codebase. Here's my review.

---

# CullApp — Code Review

**Scope:** `Sources/App` (5 files), `Sources/PrivilegedHelper` (3 files), `Sources/Shared`, `project.yml`, entitlements/plists, `README.md`.

**Overall:** The code is small, readable, and reasonably structured — but there are several **security-critical** issues in the privileged-helper path, and the app almost certainly **does not work as shipped** in the App Store sandbox configuration (it lacks file-access entitlements and scans the wrong home directory). The App Store submission path (SMJobBless + legacy `launchd.plist` `__TEXT` section) is deprecated by Apple and will be rejected.

---

## 1. CRITICAL — must fix

### C1. Privileged helper trashes arbitrary paths with no validation
**`Sources/PrivilegedHelper/HelperDelegate.swift:44-60`**

The helper runs as root and calls `FileManager.default.trashItem(at:)` on whatever strings the client sends. The only check is that the *caller* is CullApp — nothing constrains *which* paths may be touched. A compromised/buggy app, or a path that slipped through the scanner, can trash `/etc`, `/Library/LaunchDaemons`, or any user's home directory.

**Fix:** validate in the helper, not in the app:
```swift
let allowedPrefixes = ["/Library/Application Support/", "/Library/Caches/", "/Library/Preferences/",
                       "/Library/LaunchAgents/", "/Library/LaunchDaemons/"]
guard allowedPrefixes.contains(where: { path.hasPrefix($0) }) else { /* reject */ }
```
Also reject symlinks (`resolvingSymlinksInPath() != path`), reject paths that are ancestors of the helper's own location, and reject empty/relative paths. **Never trust path strings from a client — especially a privileged one.**

### C2. Overly loose leftover matching → deletes unrelated files
**`Sources/App/FileScanner.swift:71-80`**

```swift
if let bundleID, !bundleID.isEmpty, lowerName.contains(bundleID.lowercased()) { return true }
return lowerName.contains(lowerAppName)
```

Two problems:
- `contains` on the bundle ID matches `com.foo.bar` when the bundle ID is `com.foo` (false positive across vendors).
- Substring matching on the app *name* matches unrelated products: dropping `Notes.app` also matches `Keynotes`, `Notion`; dropping `Mail.app` matches `Mailplane`, `Thunderbird` mail stores, `AppleMail`… These get **trashed**.

The user's `Notes.app` can therefore destroy `Keynotes` data, and the confirmation dialog ("Move N items to Trash?") shows only counts and bytes — never the paths in a reviewable form.

**Fix:**
- For `~/Library/Preferences`, `~/Library/LaunchAgents`, `~/Library/LaunchDaemons`, `/Library/Preferences`: match **exact** filename (`com.foo.plist` == `<bundleID>.plist`), not `contains`.
- For directories, require an **exact** name match, or `exactName` / `exactName + suffix` (e.g. `.plist`, `.savedState`).
- Only fall back to name matching when the bundle ID is unavailable — and even then require the name to be ≥ 4 chars and match case-sensitively.
- Show the full list of paths in the confirmation dialog (a scrollable list), not just a count.

### C3. Dropped URL is barely validated
**`Sources/App/ContentView.swift:392-409`**

The drop handler only checks `url.pathExtension == "app"`. It does not verify:
- the URL is a *local* file URL (a remote/`.download` URL would be treated as a path),
- the item is a real application bundle (`Bundle(url:)` / `CFBundleIdentifier` present),
- it isn't a symlink into an arbitrary directory.

If `Bundle(url: appURL)?.bundleIdentifier` is `nil` (very common for a non-bundle directory named `Foo.app`), the scanner silently degrades to **name-only matching** — which combined with C2 means dropping a bogus `Foo.app` folder causes broad deletion by name.

**Fix:** require `url.isFileURL`, `Bundle(url:) != nil`, a non-empty `bundleIdentifier`, and `url.pathExtension == "app"`; reject symlinks (`URLResourceValues.isSymbolicLink`).

### C4. Sandboxed app has no file-access entitlements — deletion silently fails
**`Resources/CullApp.entitlements`, `project.yml:33`**

The app is sandboxed (`com.apple.security.app-sandbox = true`) but declares **no** `com.apple.security.files.user-selected.read-only` / `read-write` and no `com.apple.security.temporary-exception.files.absolute-path.*`. A sandboxed app cannot read arbitrary `~/Library/Application Support`, `~/Library/Containers`, etc., nor trash files the user didn't explicitly open.

Consequence: `FileScanner.matches` returns `[]` for every sandboxed root (`try?` swallows the EPERM), and `FileManager.trashItem` in `ContentView.swift:216` throws for every path — the error is only `print`ed, so the user sees "Moved 0 items to Trash" with no explanation.

**Fix:** add `com.apple.security.files.user-selected.read-write` (granted by the drag & drop), plus `com.apple.security.temporary-exception.files.absolute-path.read-write` for the `~/Library` roots you must scan, and **surface failures in the UI** instead of `print`.

### C5. `homeDirectoryForCurrentUser` in a sandbox returns the *container* home
**`Sources/App/FileScanner.swift:25`**

For a sandboxed app, `FileManager.default.homeDirectoryForCurrentUser` resolves to the sandbox container (`~/Library/Containers/com.cullapp.CullApp/Data/`), not the user's real home. So the `~/Library/*` search roots point at the container's Library — the scanner finds nothing even before C4.

**Fix:** resolve the real home explicitly, e.g. `NSHomeDirectory()` is also containerized; use
`FileManager.default.homeDirectoryForCurrentUser` **only when unsandboxed**, or derive it from `getpwuid(getuid())->pw_dir`, or use `NSOpenPanel` to obtain a user-granted directory URL. Verify with a real run before shipping.

### C6. XPC reply may never arrive → the UI hangs forever
**`Sources/App/PrivilegedHelperClient.swift:46-53`**

`withCheckedContinuation` waits on the helper's reply block. If the helper isn't installed, the connection fails, or the helper crashes, the `errorHandler` only `print`s — the reply block is never invoked and the continuation is never resumed. The UI sits at "Moving files to Trash..." indefinitely, with the window blurred and disabled.

**Fix:**
- Check the helper's presence first (`SMJobBless` status / `SMAppService.status`) and fail fast with a user-facing message.
- Use `withCheckedThrowingContinuation` and resume from `errorHandler`/`invalidationHandler` too.
- Add a timeout.

### C7. Root-owned files land in `/var/root/.Trash`, not the user's Trash
**`Sources/PrivilegedHelper/HelperDelegate.swift:51`**

`trashItem` executed as root moves the item to root's Trash (`/var/root/.Trash`), where the user can neither see nor restore it. The README claims "Trash, not Delete — files go to Trash (reversible)". For root-owned items this is false: they're effectively deleted from the user's perspective.

**Fix:** have the helper move the item to the *user's* `~/.Trash` (pass the target user's UID/home from the client and validate it), or delete it and say so in the UI.

---

## 2. HIGH — should fix

### H1. `SMJobBless` is deprecated and will fail App Store review
**`Sources/App/PrivilegedHelperClient.swift:12-35`**

Apple deprecated `SMJobBless` in favour of `SMAppService` (macOS 13+). Mac App Store submissions that use `SMJobBless` for privileged helpers are commonly rejected, and the entitlement/plist arrangement here (`__TEXT,__launchd_plist` `sectcreate`, `Resources/launchd.plist`, `SMPrivilegedExecutables`) is the pre-10.15 pattern.

**Fix:** migrate to `SMAppService.daemon(plistName:)`:
- ship `launchd.plist` in `Contents/Library/LaunchServices/`,
- it must include `Label`, `MachServices`, and `ProgramArguments` pointing at the helper binary,
- the helper should be a **bundle** (with its own `Info.plist`) at `Contents/Library/LaunchServices/com.cullapp.CullApp.PrivilegedHelper`,
- check `SMAppService.status` before registering; surface `register()` errors to the user.

### H2. `SMJobBless` is invoked on every delete, without checking whether it is installed
**`Sources/App/ContentView.swift:228` → `PrivilegedHelperClient.swift:12`**

`installHelperIfNeeded()` runs `SMJobBless` unconditionally every time root files are found. Re-blessing an already-installed helper fails (and on MAS may prompt again). The "IfNeeded" in the name is a lie.

**Fix:** query the installed status first; only bless/register when absent.

### H3. `AuthorizationCreate` requests no rights
**`Sources/App/PrivilegedHelperClient.swift:14`**

`AuthorizationCreate(nil, nil, [], &authRef)` creates an authorization with an **empty** rights set. `SMJobBless` then has no right to assert and typically fails with `errAuthorizationFailed` or asks for a passwordless right it never requested.

**Fix:** create the authorization with the rights you need (e.g. `kAuthorizationRightExecute` / the right appropriate for the helper), and handle the failure by showing the system auth prompt and reporting the `OSStatus`.

### H4. `SMJobBless` errors are invisible to the user
**`Sources/App/PrivilegedHelperClient.swift:16, 30, 41, 49`**

Every failure path is a `print`. The user gets a misleading success/failure message with no cause ("Moved 0 items to Trash").

**Fix:** return typed errors (`Result`) and render them in the `ResultCard`; at minimum surface the `CFError`/`OSStatus` from `SMJobBless` and the helper's `errorMessage`.

### H5. Partial failures are reported as success
**`Sources/PrivilegedHelper/HelperDelegate.swift:58`, `Sources/App/ContentView.swift:231-236`**

The helper returns `allSucceeded` as a single `Bool`. If 3 of 5 root files fail, `success == false`, so **none** are counted as deleted — but the client neither retries nor reports which ones failed; the UI just shows a smaller count with no explanation. User-file failures (`ContentView.swift:218-220`) are likewise swallowed.

**Fix:** have the helper return per-path results (`[(String, Bool, String?)]`), and show a per-item failure list.

### H6. The helper does not verify the *client's* code signing requirement via XPC
**`Sources/App/PrivilegedHelperClient.swift:61-62`**

The client creates an `NSXPCConnection` to a global mach service and never sets a code-signing requirement for the peer. Apple's guidance is to call `conn.setCodeSigningRequirement(...)` so the client only talks to a helper signed by the expected team.

**Fix:** `conn.setCodeSigningRequirement("anchor apple generic and identifier \"com.cullapp.CullApp.PrivilegedHelper\" and certificate leaf[subject.OU] = \"<TEAMID>\"")` — and use the same hardened requirement in `SMAuthorizedClients`.

### H7. Invalid app-group entitlement
**`Resources/CullApp.entitlements:7-10`**

`com.apple.security.application-groups` is set to `"com.cullapp.CullApp"`, which is the app's own bundle ID, not a group ID. App group IDs must be of the form `group.<team>.<name>` and must be registered in the developer portal. This will fail provisioning or App Store validation.

**Fix:** remove the entitlement (it isn't needed) or use a properly registered group ID.

### H8. `launchd.plist` is missing `ProgramArguments`/`Program`
**`Resources/launchd.plist`**

The embedded launchd job declares only `Label` and `MachServices`. With the `__TEXT,__launchd_plist` technique the job needs to know how to launch the tool. Combined with H1 (a `type: tool` rather than a bundle), helper launch is unreliable.

**Fix:** adopt the `SMAppService` layout (H1) and include `ProgramArguments` referencing the helper path.

### H9. Progress reporting is wrong during deletion
**`Sources/App/ContentView.swift:212`**

```swift
progress = Double(index) / Double(scanResults.count)
```
`index` enumerates `userFiles` only, while the denominator is `scanResults.count`. With root files present, the bar never reaches 1 during the user-file phase and jumps afterwards. The scan phase (`ContentView.swift:179`) has the same shape.

**Fix:** use a single monotonic counter over the total item count.

### H10. No error handling around the scan `Task`
**`Sources/App/ContentView.swift:172-192`**

If the task throws or is cancelled, `isScanning` stays `true` forever and the UI is stuck disabled. There's also no cancellation support — the user cannot abort a scan of a large `~/Library/Containers`.

**Fix:** wrap in `do/catch`, always reset `isScanning`/`isDeleting` in a `defer`, and store a `Task` handle to cancel it.

---

## 3. MEDIUM — consider fixing

### M1. The architecture doesn't match the documented one
**`Sources/App/ContentView.swift:29-37` vs `CLAUDE.md`**

CLAUDE.md specifies "SwiftUI + MVVM con `@Observable`", but all state lives as `@State` inside the `View`, and `FileScanner`/`PrivilegedHelperClient` are plain actors with no view-model layer. Business logic (scan orchestration, delete orchestration, partitioning root vs user files) is embedded in view code.

**Fix:** extract a `@Observable` `ScanViewModel` (or `AppModel`) owning `scanResults`, `isScanning`, `progress`, `statusMessage`, and the delete pipeline.

### M2. `FileItem` is declared in `ContentView.swift` but used by `FileScanner.swift`
**`Sources/App/ContentView.swift:15-21`**

The model type lives in a view file and is consumed by the scanner. Also `FileItem.id` is a fresh `UUID` per instance, so it isn't stable across re-scans and can't be diffed.

**Fix:** move `FileItem` (and `DroppedApp`) into `Sources/Shared/` or a `Models/` folder; make it `Hashable` with `id` derived from `path`.

### M3. `getOwner` uses `ownerAccountID` + `getpwuid` instead of the simpler attribute
**`Sources/App/FileScanner.swift:106-119`**

`attributes[.ownerAccountID] as? Int` is a fragile cast (it's an `NSNumber`), and `getpwuid` returns a pointer into a static buffer that is not thread-safe under concurrent access. The scanner is an actor, but `sizeOf`/`getOwner` could move to a `TaskGroup` later.

**Fix:** use `attributes[.ownerAccountName] as? String` — one syscall, no pointer handling, no thread-safety caveat.

### M4. `sizeOf` enumerates directories synchronously and follows symlinks
**`Sources/App/FileScanner.swift:90-104`**

`FileManager.enumerator` with `.skipsHiddenFiles` (no `.skipsPackageDescendants`) descends into `.app` bundles inside `Application Support` and follows symlinks; it can also loop on symlink cycles. It reports allocated size but the UI label says "disk space", which will mismatch what the user sees.

**Fix:** add `.skipsPackageDescendants` and `.skipsSubdirectoryDescendants` where appropriate; guard against symlink cycles; be consistent about whether you report logical or allocated bytes.

### M5. Hidden files are skipped during scanning
**`Sources/App/FileScanner.swift:56`**

`options: [.skipsHiddenFiles]` means dot-directories in `Application Support` (a common convention, e.g. `~/.config`-style layouts) are never found.

**Fix:** scan hidden entries too; the size enumerator can still skip them if desired.

### M6. `AppProtocol` is dead code
**`Sources/Shared/XPCProtocol.swift:8-10`**

`reportProgress` is never implemented, exported, or called anywhere.

**Fix:** delete it, or implement it — the UI claims "live scan/delete progress" but the helper has no progress channel.

### M7. Bundle ID strings are duplicated across four files
**`Sources/App/PrivilegedHelperClient.swift:7`, `Sources/PrivilegedHelper/main.swift:3`, `Sources/PrivilegedHelper/Info.plist:6,17`, `Resources/CullApp-Info.plist:25-26`, `Resources/CullApp.entitlements:12`**

**Fix:** single source of truth (a `Constants` enum in `Sources/Shared/`), with the plists generated or verified against it in a build phase.

### M8. The helper duplicates the signed-requirement string
**`Sources/PrivilegedHelper/HelperDelegate.swift:4`**

`callerRequirement` is re-parsed on every connection (`SecRequirementCreateWithString` per connection). Also, `anchor apple generic` accepts *any* Apple-signed binary with that identifier — it does not constrain the team.

**Fix:** cache the compiled `SecRequirement` as a `static let`; tighten the requirement with `certificate leaf[subject.OU] = "<TEAMID>"`.

### M9. `helper.getVersion` is never called
**`Sources/Shared/XPCProtocol.swift:5`, `Sources/PrivilegedHelper/HelperDelegate.swift:62`**

Dead protocol method — unless a version handshake is planned (it should be: the helper can outlive the app version).

**Fix:** either implement a version check before use, or remove it.

### M10. README / project metadata are inconsistent
**`README.md:35`, `project.yml:5,11`**

README says macOS 14.0+ and Xcode 15+; `project.yml` targets macOS 12.0 with Swift 5.9, and `CLAUDE.md` says Xcode 26. `README.md:56` also says files are moved with `NSWorkspace.shared.moveToTrash()` while the code uses `FileManager.trashItem`. `Resources/CullApp-Info.plist:17` pins `LSMinimumSystemVersion` to 12.0.

**Fix:** pick one deployment target, align the plist, project.yml and README, and correct the API references. (Note: `SMAppService` requires macOS 13+, which forces the target up.)

### M11. The helper is copied into the bundle twice
**`project.yml:36-51`**

The `copy:` dependency places the binary in `Contents/Resources/`, and the `postBuildScripts` step copies it to `Contents/Library/LaunchServices/`. The `Resources/` copy is unnecessary and pollutes the bundle.

**Fix:** drop the `copy:` block, keep only the `Library/LaunchServices` copy (and adjust for the `SMAppService` bundle layout).

### M12. The app has no menu bar
**`Sources/App/main.swift`**

`NSApplication` is started without a main menu, so ⌘Q, ⌘C/⌘V and standard shortcuts don't work — a common App Store review rejection (guideline 2.5 / missing standard keyboard support) and generally poor UX.

**Fix:** install a minimal `NSMenu` (App menu with Quit, Edit menu with Cut/Copy/Paste/Select All) or move to `SwiftUI`'s `App`/`Commands` lifecycle.

---

## 4. MINOR — nice to have

- **`Sources/App/ContentView.swift:199-249`** — `deleteFiles` has no cancellation and no guard against the user dropping new apps mid-delete. Add a `Task` handle and cancel it in `onDisappear`.
- **`Sources/App/ContentView.swift:203-204`** — the root/user split uses `owner == "root"`, a string comparison against a locale-dependent name. Compare UID `== 0` instead and carry the uid in `FileItem`.
- **`Sources/App/ContentView.swift:216`** — the app bundle itself is trashed along with leftovers; if the target app is *running*, its data stays open and the deletion is incomplete. Consider prompting to quit the app first.
- **`Sources/App/ContentView.swift:14-21`** — `DroppedApp` holds a full `NSImage` per dropped app; fine at this scale, but `Equatable` compares only `url` while `Identifiable.id` is a random `UUID` — two entries for the same app would have different ids. Make `id` derived from `url`.
- **`Sources/App/ContentView.swift:373`** — removing an individual dropped app doesn't clear `scanResults`, so results from the removed app remain listed and deletable.
- **`Sources/App/ContentView.swift:398`** — `NSWorkspace.shared.icon(forFile:)` is called on the drop thread; it can block on a network volume. Move it off the drop callback or use `NSWorkspace.icon(forFile:)` on a background queue.
- **`Sources/App/FileScanner.swift:41-45`** — roots are scanned sequentially; `~/Library/Containers` and `Application Support` are the slow ones. A `TaskGroup` over roots would cut wall-clock time roughly proportionally.
- **`Sources/PrivilegedHelper/main.swift:3`** — `NSXPCListener(machServiceName:)` without `NSXPCListener(anonymousListener:)`; for `SMAppService.daemon` the label must match the `launchd.plist` `Label` exactly. Add a startup log to make launch failures diagnosable.
- **`Sources/PrivilegedHelper/HelperDelegate.swift:29-35`** — the invalidation/interruption handlers are empty; the helper should at least log disconnects.
- **`Sources/PrivilegedHelper/HelperDelegate.swift:62`** — the helper version is the hardcoded string `"1.0.0"`, independent of the app's `CFBundleVersion`. Read it from the bundle.
- **No test target at all.** At minimum add unit tests for `fileNameMatches`/`sizeOf` and an XPC round-trip test — the path-validation logic (C1) especially deserves tests.
- **`CrowdStrike_Comparativa.xlsx`** and `README.md` in the repo root are unrelated to the app bundle; move them out of the project directory.
- **`Resources/Assets.xcassets/*/Contents.json`** — each imageset declares `"author": "xcode"` and `"version": 1` at the *imageset* level, which is not a valid key for that file type (those belong at the catalog root). Harmless, but Xcode will rewrite them.

---

## Suggested order of work

1. **C1–C3** (helper path validation, tighter matching, drop validation) — security-critical, small diffs.
2. **C4/C5** (sandbox entitlements + real home resolution) — the app is non-functional without these; verify by running against a real `~/Library`.
3. **C6/C7/H1–H5** (XPC reliability + `SMAppService` migration + error surfacing) — required for the App Store path to work at all.
4. **M1/M2/M10/M12** (MVVM split, model placement, metadata consistency, menu bar) — App Store readiness and maintainability.

The good news: the architecture is sound, the code is short and readable, the XPC interface is properly declared on both sides, and the caller-authorization check in the helper is the right idea — it just needs the same rigor applied to the *paths* it operates on.