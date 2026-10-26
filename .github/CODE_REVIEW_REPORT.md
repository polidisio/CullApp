# Code Review Report: CullApp
Generated: 2026-10-27T00:02:07.109025

I've reviewed all 8 Swift sources plus the build config, entitlements, and plists. The code is small (821 lines) and clearly structured, but has several real problems.

---

# CullApp Code Review

**Scope:** `Sources/App/*.swift`, `Sources/Shared/*.swift`, `Sources/PrivilegedHelper/*.swift`, `project.yml`, plists, entitlements.
**Verdict:** Not clean — 2 CRITICAL, 6 HIGH issues. The good news: the XPC authorization pattern, actor isolation, and `SMJobBless` plumbing are structurally sound.

---

## 1. CRITICAL

### C1. Root helper deletes arbitrary paths with no validation
**`Sources/PrivilegedHelper/HelperDelegate.swift:44-60`**

`HelperImpl.trashFiles` runs as root and trashes *any* path string it receives. The only gate is the client-side filter in `ContentView.deleteFiles` (`scanResults.filter { $0.owner == "root" }`). A modified/compromised app (or a path injected into `scanResults`) can move arbitrary system files to root's Trash with one XPC call. There is no allowlist, no path normalization, and no check that the path is under a system location the app legitimately owns.

**Fix:** validate in the helper, not the client:
```swift
private let allowedRoots = ["/Library/Application Support", "/Library/Caches",
                           "/Library/Preferences", "/Library/LaunchAgents",
                           "/Library/LaunchDaemons"]
```
Resolve symlinks (`URL.resolvingSymlinksInPath()`), reject anything outside those roots, reject `..` components, and reject paths that are not regular files/dirs. Reject the call (reply `false`) otherwise.

### C2. Name-substring matching will delete *other* apps' data
**`Sources/App/FileScanner.swift:71-80`**

`fileNameMatches` uses `lowerName.contains(lowerAppName)`. This is not "smart detection by bundle identifier" as the project intends — it is a substring match, and it produces destructive false positives:

- Dropping `Chrome.app` → matches `/Library/Preferences/Google Chrome.plist` → **deletes Google Chrome's preferences**.
- Dropping `Notes.app` → matches `NotesTimeline`, `MyNotesBackup`, `QuickNotes`.
- Dropping `Steam.app` → matches `SteamworksShared`.

Any app whose name is a substring of an unrelated product's directory gets that product's data deleted. There is no verification that the matched item actually belongs to the dropped bundle.

**Fix:** use exact match on the bundle-ID-derived directory name (`com.apple.Notes` → `~/Library/Containers/com.apple.Notes`), or exact/prefix match on the app name with a token boundary, then *verify* the candidate by reading its `Info.plist` and comparing `CFBundleIdentifier` before including it. If a candidate's bundle ID does not match, drop it.

---

## 2. HIGH

### H1. XPC continuation may never resume → UI hangs forever
**`Sources/App/PrivilegedHelperClient.swift:37-54`**

`withCheckedContinuation` resumes only from the reply block. If the proxy errors out (helper not installed, service unreachable), `remoteObjectProxyWithErrorHandler` fires, the handler only `print`s, and the reply block never runs — the `await` hangs indefinitely, leaving `isDeleting = true` and the app permanently stuck on "Moving files to Trash...".

**Fix:** guard the continuation with an atomic flag, and resume `false` from the error handler:
```swift
let resumed = AtomicFlag()
return await withCheckedContinuation { continuation in
    func finish(_ ok: Bool) { if resumed.trySet() { continuation.resume(returning: ok) } }
    ...
}
```

### H2. `SMJobBless` authorization is created without the required right
**`Sources/App/PrivilegedHelperClient.swift:12-35`**

`AuthorizationCreate(nil, nil, [], &authRef)` creates an authorization with an **empty rights set**. `SMJobBless` needs the authorization to carry `kAuthorizationRightExecute` (and typically an admin-authenticated rights dictionary). With empty rights this call fails with an auth error on most systems. Additionally the result is never surfaced: `installHelperIfNeeded()` returns `Void`, the failure is `print`ed, and `deleteFiles` proceeds to call the helper anyway.

**Fix:** request the right explicitly, check `AuthorizationCopyRights`/`SMJobBless` status, and return `Bool` (or a `Result`) so the caller can abort and tell the user:
```swift
let rights = [kAuthorizationRightExecute: [kAuthorizationRuleClassAllow: true]] as CFDictionary
AuthorizationCopyRights(auth, rights, &authRef2, nil)
```

### H3. All deletion errors are swallowed; the user is told a lie
**`Sources/App/ContentView.swift:209-221, 238-247`**

Per-item failures are `print`ed only. At the end, `scanResults` and `droppedApps` are cleared unconditionally and the UI reports *"Moved N items to Trash and freed X"*. If the app bundle in `/Applications` failed to move (likely — a sandboxed app holds only *read* access to a dropped bundle via the powerbox, and `trashItem` needs write), or if 17 of 20 items failed, the user sees a success message with no list of what survived.

**Fix:** accumulate failures into an array, keep failed items in `scanResults`, and report both counts in the result card ("Moved 14 of 20 items; 6 failed — see log"). Surface at least the first error message to the UI.

### H4. `allSucceeded` makes the helper all-or-nothing and the app mis-reports
**`Sources/PrivilegedHelper/HelperDelegate.swift:45-59`** and **`Sources/App/ContentView.swift:230-235`**

The helper returns `successCount == paths.count`. If 9 of 10 root files succeed, `success` is `false`, so the app discards the entire `rootFiles` array and reports **zero** root files deleted — even though 9 were moved to Trash. The user sees an undercount and may re-run the scan against already-deleted paths.

**Fix:** return per-path results (`[String: Bool]` or `[(String, Bool)]`) so the app can report accurate counts and retry only failures.

### H5. Caller authorization uses `processIdentifier` (racy) and no team-ID requirement
**`Sources/PrivilegedHelper/HelperDelegate.swift:4-17`**

Two problems:
1. `connection.processIdentifier` is a PID, which can be recycled — the classic TOCTOU on PID-based code-signing checks. On macOS 11+ use `connection.auditToken` with `sec_code_copy_guest`, which is not PID-based.
2. The requirement is `anchor apple generic and identifier "com.cullapp.CullApp"` with no Team ID. Add `and certificate leaf[subject.OU] = "<TEAMID>"` and mirror it exactly in the helper's `SMAuthorizedClients`.

Also note `processIdentifier` returns `0` for privileged/root peers, which would make the check fail closed — acceptable, but prefer `auditToken`.

### H6. Scanning `~/Library/Containers` of other apps is blocked by the sandbox
**`Sources/App/FileScanner.swift:31`**

The app enables `com.apple.security.app-sandbox` (`project.yml:33`) but scans `~/Library/Containers`. A sandboxed app cannot read *other* apps' container directories — `contentsOfDirectory` returns nil and the call silently returns `[]` (`FileScanner.swift:53-57`). So container leftovers are never found, and the same silent-failure pattern applies to any path the sandbox denies.

**Fix:** decide explicitly — either drop the Containers root (containers are deleted with the app anyway) or surface a "some locations could not be scanned (sandbox restrictions)" note instead of silently reporting a clean scan.

---

## 3. MEDIUM

### M1. Root-owned files go to root's Trash, not the user's
**`Sources/PrivilegedHelper/HelperDelegate.swift:51`** — as root, `trashItem` targets `/var/root/.Trash`, which the user cannot see in Finder. Files become effectively invisible (recoverable only by an admin). Consider having the helper move root-owned files into the *user's* `~/.Trash` explicitly, or at minimum surface the destination path.

### M2. `NSXPCInterface` collection typing is not configured
**`Sources/App/PrivilegedHelperClient.swift:62`** — the interface is built for a protocol taking `[String]` with no `setClasses(_:for:at:)`. For `NSArray` parameters XPC requires the contained classes to be declared, otherwise the message is rejected at runtime. Verify and add:
```swift
let iface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
iface.setClasses([NSString.self], for: argumentSignature: "trashFiles", at: 0)
```

### M3. Off-main-actor reads of SwiftUI state
**`Sources/App/ContentView.swift:200-204`** — inside the `Task`, `scanResults` is read (`filter`, `count`) without `MainActor` isolation. `@State` storage is main-actor-bound; this is a data race (and a Swift 6 concurrency error). Hoist the values before entering the `Task`, or mark `deleteFiles`/`scanApps` `@MainActor` and hop explicitly.

### M4. Progress denominator is wrong during deletion
**`Sources/App/ContentView.swift:212`** — `progress` uses `scanResults.count` but the loop iterates `userFiles`, so progress jumps and never reflects the root-file phase. Use a single `total` and increment across both phases.

### M5. Actor-isolated scanner does blocking filesystem I/O
**`Sources/App/FileScanner.swift:3, 82-104`** — `FileScanner` is an `actor`, so all `scan` calls serialize, and `sizeOf` walks whole directory trees (via `FileManager.enumerator`) synchronously on a cooperative-pool thread. For a large `~/Library/Application Support` this blocks and stalls other scans. Move the enumeration to a detached task / `Task.detached` and compute sizes in parallel.

### M6. `.skipsHiddenFiles` hides real leftovers
**`Sources/App/FileScanner.swift:56, 93`** — many apps store state in dot-directories (`~/.example`, `~/.config/example`). Both the directory listing and the size enumeration skip them, so their size is underreported and their contents are never listed. At minimum, size enumeration should not skip hidden files.

### M7. Helper launch failure is silent
**`Sources/PrivilegedHelper/main.swift:3-6`** — if `NSXPCListener(machServiceName:)` fails (service already registered, stale install), the process runs forever with a dead listener and no diagnostic. Log the failure and exit non-zero so `launchd`/the app can observe it.

### M8. Unused code
**`Sources/Shared/XPCProtocol.swift:8-10`** — `AppProtocol` is never implemented or referenced. Delete it. `getVersion` (`HelperDelegate.swift:62`) is also never called.

---

## 4. MINOR

- **`ContentView.swift:5-13`** — `DroppedApp.id` is a fresh `UUID()` per instance, so identity changes on every view update; use the URL as the `id`.
- **`ContentView.swift:408`** — the drop handler returns `!providers.isEmpty`, claiming acceptance even when no `.app` was found. Return `false` unless at least one provider yielded a valid `.app`.
- **`FileScanner.swift:106-119`** — `getOwner` returns `"unknown"` on failure, and `ContentView.swift:203` treats any owner other than `"root"` as user-owned. An `unknown` owner (e.g. a file whose attributes can't be read) would be sent to the *unprivileged* path and fail. Invert the test: route to the helper unless the owner is provably the current user.
- **`PrivilegedHelperClient.swift:7`** — the mach service name is duplicated in three places (client, `PrivilegedHelper/main.swift:3`, plists). Define it once in `Sources/Shared`.
- **`project.yml:5,11,12`** — deployment target 12.0 / Swift 5.9 / xcodeVersion 15.0 contradicts `CLAUDE.md` ("macOS 14+", "Xcode 26"). Reconcile.
- **`project.yml:36-41`** — the `copy: destination: resources` block copies the helper binary into the app's Resources *in addition to* the `Contents/Library/LaunchServices` post-build copy. The duplicate is unused; drop it.
- **`ContentView.swift:396`** — `provider.loadObject` completion runs off the main thread and calls `NSWorkspace.shared.icon(forFile:)`, a filesystem hit; move icon loading into the `DispatchQueue.main.async` block.
- **`Resources/CullApp-Info.plist`** — no `CFBundleIconFile`/app icon; the app will ship with a generic icon.

---

## Priority order

1. **C1 + C2** — the helper's path allowlist and the matcher's false positives are the two things that can destroy a user's unrelated data. Fix these before any release.
2. **H1, H2, H3** — the helper install and delete paths currently fail silently and can hang the app.
3. **H5, M2** — tighten XPC authorization and confirm the interface typing, otherwise the helper may never accept a connection at all.

The overall architecture (sandboxed app → XPC → root helper, bundle-ID-based detection) is sound; the gaps are all in validation and error handling at the privileged boundary.