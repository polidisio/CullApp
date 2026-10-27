# Code Review Report: CullApp
Generated: 2026-10-28T00:16:03.384309

I've read all 11 Swift files plus the entitlements, plists, and project config. Here's the review.

---

# CullApp Code Review

Scope: 9 Swift files, 3 plists, 2 entitlements, `project.yml`. Overall the structure (scanner / client / helper / delegate) is clean and idiomatic SwiftUI + actor. The problems below are mostly in the **deletion path**, where the blast radius is "files on disk."

---

## 1. CRITICAL (must fix)

### C1 — Name matching causes mass false-positive deletion
`Sources/App/FileScanner.swift:71-80`

```swift
if let bundleID, ... lowerName.contains(bundleID.lowercased()) { return true }
return lowerName.contains(lowerAppName)
```

`contains` on the raw app name is far too loose:
- Dropping **Photos.app** → appName `photos` → matches **"Adobe Photoshop"** (`~/Library/Application Support/Adobe/Photoshop`) → trashed.
- Dropping **Mail.app** → matches `Mailspring`, `Mailplane`, `Thunderbird` (contains "mail")…
- Dropping **Steam.app** → matches `Steamworks`, `steam_autoupdate`, `de.steam.*`.

Any directory whose name merely *contains* the app name is silently queued for deletion, and the UI shows the full path in a monospaced list the user is expected to eyeball.

**Fix:** require an exact match (case-insensitive) on the entry's `lastPathComponent`, plus an explicit prefix/suffix allowance for known patterns (`com.<vendor>.<app>`, `<app>-agent`, `<app>.plist`). Resolve the bundle ID *inverted* — read `Contents/Info.plist` from candidate dirs and compare `CFBundleIdentifier` exactly — rather than string-matching the ID into a filename. If a candidate's bundle ID doesn't match exactly, drop it from the list.

### C2 — The helper authorizes any Apple-signed app, not just CullApp
`Sources/PrivilegedHelper/HelperDelegate.swift:4` and `Sources/PrivilegedHelper/Info.plist` (`SMAuthorizedClients`)

```
anchor apple generic and identifier "com.cullapp.CullApp"
```

`anchor apple generic` matches *any* certificate chaining to Apple's root CA. Every Mac App Store app and every Developer ID-signed app on the machine satisfies that anchor. Combined with the helper running as root and `trashFiles` accepting an arbitrary path list, **any third-party app on the system can connect to the helper and trash arbitrary root-owned files** (e.g. `/etc/hosts`, `/Library/LaunchDaemons/*`).

**Fix:** pin the requirement to the Team ID and the specific identifier:

```
identifier "com.cullapp.CullApp" and anchor apple generic
  and certificate leaf[subject.OU] = "TEAMID1234"
```

Same string in `SMAuthorizedClients`. Note: `SecCodeCheckValidity` in `isCallerAuthorized` also uses the loose requirement — change both. Additionally, in the helper, refuse any path that isn't under a scanned root and that isn't a regular file/dir.

### C3 — Helper deletes arbitrary root paths with no validation
`Sources/PrivilegedHelper/HelperDelegate.swift:44-60`

`trashFiles` takes `[String]` and calls `trashItem` on each, as root, with:
- no check that the path is under `/Library`, `/var`, or another intended root,
- no rejection of symlinks (a symlink pointing at `/etc` — `trashItem` moves the link, but combined with `URL(fileURLWithPath:)` semantics and any future resolve, this is a footgun),
- no per-path allowlist derived from what the scanner actually found.

**Fix:** in the helper, canonicalize with `URL(fileURLWithPath:).resolvingSymlinksInPath()`, require the resolved path to be under one of `/Library`, `/usr/local`, `/private/var/db`, `/private/var/log`, and reject anything under `/System`, `/bin`, `/usr/bin`, `/etc`, `/private/etc`. Verify `lstat` says it is not a symlink.

### C4 — XPC call can hang the UI forever
`Sources/App/PrivilegedHelperClient.swift:37-54`

```swift
return await withCheckedContinuation { continuation in
    helper.trashFiles(paths) { success, errorMessage in ... continuation.resume(...) }
}
```

If the helper is not installed, `SMJobBless` failed (and the error was only `print`ed — `installHelperIfNeeded` returns `Void` and its caller ignores it), or the helper dies mid-call, the reply block never fires. `withCheckedContinuation` then never resumes: the `Task` in `deleteFiles` hangs, `isDeleting` stays `true`, and every control in the window is permanently disabled. The `remoteObjectProxyWithErrorHandler` prints the error but does **not** resume the continuation.

**Fix:** use `withCheckedThrowingContinuation` and resume from the error handler; wrap the call in `withTimeout` (e.g. 60s) and treat timeout as failure. Have `installHelperIfNeeded()` return `Bool`/`Result` and abort the deletion if the helper isn't available.

### C5 — Sandbox vs. the actual feature set
`project.yml:33` (`ENABLE_APP_SANDBOX: YES`), `Resources/CullApp.entitlements`

A sandboxed app's container is `~/Library/Containers/com.cullapp.CullApp`. The scanner reaches into the *real* `~/Library/Application Support`, `~/Library/Caches`, `~/Library/Preferences`, `~/Library/Containers` and the app's own `/Applications` bundle. Under the sandbox these are largely out of reach — and drag & drop only grants a sandbox extension for the single dropped URL, not its siblings. In practice the user-owned leftover trashing at `ContentView.swift:216` will fail for most paths, with the error only `print`ed, so the app reports "Moved N items" while having moved nothing.

**Fix:** verify on a real MAS-signed build which of these roots are readable. If unreadable, the leftovers must be enumerated and trashed via the privileged helper (which is *not* sandboxed), or the app must use `NSOpenPanel` with `NSOpenPanel.canChooseDirectories` to obtain granted access to each root. `Resources/CullApp.entitlements` also has a stray `com.apple.security.application-groups` entry pointing at the app's own bundle ID — that's a no-op and should be removed or changed to a real group.

---

## 2. HIGH (should fix)

### H1 — Deleting the app bundle never works, and it's routed to the wrong executor
`FileScanner.swift:20` adds the `.app` itself to the deletion list. Its owner is the admin user, so `ContentView.swift:203` classifies it as `owner != "root"` and tries `FileManager.trashItem` in-process — which fails for `/Applications/*.app` under the sandbox. Also, per `CLAUDE.md`, the App Store-safe API for moving a `.app` is `NSWorkspace.shared.moveToTrash()`, not `FileManager.trashItem`.

**Fix:** use `NSWorkspace.shared.moveToTrash()` for the `.app` bundle; route it through the helper if the in-process call fails with a permission error.

### H2 — Root-owned files land in root's Trash, invisible to the user
`HelperDelegate.swift:51` runs `trashItem` as root, so the file goes to `/var/root/.Trash`. The user can never restore it from the Finder, and the "Files can be restored from the Trash afterwards" promise in `ConfirmationCard` (`ContentView.swift:296`) is false for exactly the files that needed the helper.

**Fix:** have the helper move root-owned files into the *user's* `~/.Trash` (pass the user's home/uid in the XPC call, or resolve the console user via `SCDynamicStoreCopyConsoleUser`), or delete them permanently with an explicit confirmation.

### H3 — Every failure is invisible to the user
`ContentView.swift:195-249`. Failures are `print`ed; `resultMessage` at line 246 always reports a success count and a freed size. `scanResults` and `droppedApps` are cleared regardless of what failed, so the user loses the list of items that were not removed. `installHelperIfNeeded` prints "SMJobBless failed: …" and the app proceeds as if it worked.

**Fix:** collect per-item errors, show them in `ResultCard` ("Moved 12 of 15 items to Trash; 3 failed: …"), and keep the failed entries in `scanResults`.

### H4 — Helper installation is re-attempted on every deletion and its auth flow is wrong
`PrivilegedHelperClient.swift:12-35`. `SMJobBless` is called unconditionally before every root-file deletion, which will prompt for admin credentials each time even when the helper is already installed. `AuthorizationCreate(nil, nil, [], &authRef)` creates a right-less `AuthorizationRef`; `SMJobBless` normally needs an authorization created with the appropriate rights (or `kSMRightPrivilegedHelperToolBlessRule`) for the prompt to appear correctly.

**Fix:** check `SMJobCopyDictionary` for an existing install first; only bless when missing. Create the `AuthorizationRef` with `AuthorizationCreate(nil, nil, nil, &auth)` and a rights set including `kSMRightPrivilegedHelperToolBlessRule`.

### H5 — `fileNameMatches` uses the app's *file* name, not its display name
`FileScanner.swift:22` — `appURL.deletingPathExtension().lastPathComponent` yields `Foo` for `Foo.app`, but the bundle's real name is in `CFBundleName`. Apps whose on-disk name differs from their branding (`Microsoft Word.app` vs "Word") produce poor matches both ways.

**Fix:** read `CFBundleName`/`CFBundleIdentifier` from `Contents/Info.plist` and match on the bundle ID.

### H6 — The scanner only looks at the top level of each root
`FileScanner.swift:50-69` calls `contentsOfDirectory` without recursing. Leftovers nested one level deeper (e.g. `~/Library/Application Support/Some Vendor/Foo/`) are missed entirely.

**Fix:** recurse to a bounded depth (2-3 levels), skipping package contents.

---

## 3. MEDIUM (consider fixing)

- **`ContentView.swift:172, 200` — `Task { }` in a `View` without `@MainActor` isolation.** State is mutated from a detached-ish task. The `await MainActor.run` calls cover most writes, but `scanResults = []` (line 168) and `isScanning = true` (167) run outside a main-actor hop. Mark the view's methods `@MainActor` or hop once at the top of the task.
- **`ContentView.swift:212` — progress denominator mismatch.** `progress = Double(index) / Double(scanResults.count)` but the loop only walks `userFiles`, so progress never reflects the root-file phase and can exceed 1.0. Use per-phase denominators.
- **`FileScanner.swift:82-104` — `sizeOf` walks entire directory trees** synchronously inside the actor, including `/Library/Application Support` matches. This is off the main thread (good) but can take many seconds for large trees. Consider capping depth, or computing size lazily in the row view.
- **`FileScanner.swift:56, 93` — `.skipsHiddenFiles`** misses legitimate hidden leftovers (e.g. `~/.cache` entries, dot-prefixed support dirs). Drop it for the roots, keep it only when recursing inside a matched bundle.
- **`FileScanner.swift:110` — `getpwuid` is not thread-safe** and returns a pointer into a shared static buffer. Use `getpwuid_r` with a caller-supplied buffer, or `copygetpwuid` if available, or resolve the name only for the known uid 0 case.
- **`FileScanner.swift:106-119` — `getOwner` returns `"unknown"` on error**, and `ContentView.swift:203` then treats `"unknown"` as user-owned. A root-owned file that fails the lookup is attempted in-process and fails silently. Return `uid` instead of a display string and compare against 0.
- **`project.yml:42-51` — the post-build script silently does nothing** if the helper binary is missing (`if [ -f … ]` with no `else`). A missing helper would then fail at runtime with no build-time signal. Fail the build instead.
- **`Sources/PrivilegedHelper/main.swift:3-6` — no error handling around `NSXPCListener`.** If the listener fails to register (wrong label, not run as root), the helper runs as a live process doing nothing and the app hangs (see C4). Check `listener` state and exit non-zero on failure.
- **`HelperDelegate.swift:6-17` — the `SecRequirement` is recompiled on every connection.** Cache it in a `static let`.
- **`Sources/App/CullAppApp.swift` — the app has no Dock icon / is not a proper `LSUIElement`-or-regular app**; the window is created manually rather than via `WindowGroup`. Minor, but `NSApp.activate` is a workaround for the app not activating. Use SwiftUI's `App` lifecycle.

---

## 4. MINOR (nice to have)

- `ContentView.swift:23-27` — `byteFormatter` is a global `let` of a non-`Sendable` class; Swift 6 strict concurrency will flag it.
- `ContentView.swift:392-409` — `loadObject(ofClass: URL.self)` drops the `NSItemProvider` security-scoped access; in a sandbox the icon lookup may fail and return a generic icon. Consider `NSWorkspace.shared.icon(forFile:)` after `startAccessingSecurityScopedResource()`.
- `ContentView.swift:397` — `pathExtension == "app"` is case-sensitive; accept `"app"` case-insensitively and verify the URL is a directory with an `Info.plist`.
- `ContentView.swift:216` — `FileManager.trashItem` on an `.app` bundle is not the App Store-recommended path; see H1.
- `FileScanner.swift:47` — the final `sorted { $0.path < $1.path }` is a stable sort on an already-deterministic set; fine, but `items.sorted(by: { $0.path < $1.path })` reads better.
- `FileScanner.swift:5` — `scan(appURL:)` takes a `URL` but never validates it is an `.app` bundle; a directory named `Foo.app` would scan it.
- `HelperDelegate.swift:29-35` — the invalidation/interruption handlers are empty; log them for field diagnosis.
- `project.yml:6` — `xcodeVersion: "15.0"` vs `CLAUDE.md` claiming Xcode 26 / macOS 14+; the deployment target is 12.0 in both places. Reconcile the documented and actual targets.
- `README.md` / `CLAUDE.md` — mention that the helper's `SMAuthorizedClients` and the `SecRequirement` string must stay in sync with the Team ID, or the helper will refuse the app after signing changes.

---

## Summary

The architecture and code organization are good — actor-based scanning, a thin XPC client, and a delegated helper are the right shapes, and error handling isn't absent so much as mis-routed (printed instead of surfaced).

The three things I'd fix before shipping: **C1** (the name matcher will delete the wrong apps' data — `Photos` → `Photoshop`), **C2/C3** (the privileged helper will accept connections from any Apple-signed app and will trash any root path it's handed), and **C4** (the deletion flow can wedge the UI indefinitely). C5 needs a real MAS-signed build to confirm, but it determines whether the app works at all as a Mac App Store app.