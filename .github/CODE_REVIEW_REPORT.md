# Code Review Report: CullApp
Generated: 2026-07-17

## Swift Code Review Summary

### CRITICAL
| File | Issue |
|------|-------|
| `PrivilegedHelperClient.swift:34` | `AuthorizationFree` never called on early return — resource leak |
| `PrivilegedHelperClient.swift:61` / `HelperDelegate.swift:42-60` | No path validation in `trashFiles` — arbitrary file deletion via XPC possible |
| `PrivilegedHelperClient.swift:62` | Misleading `[weak self]` on actor — doesn't prevent what it implies |

### HIGH
| File | Issue |
|------|-------|
| `FileScanner.swift:110-113` | `getpwuid` result dereferenced unsafely — potential crash |
| `HelperDelegate.swift:29-35` | Empty XPC connection/interruption handlers — silent failure, no recovery |
| `ContentView.swift:396-407` | Deprecated `loadObject` API mixed with async/await — error-prone |

### MEDIUM
| File | Issue |
|------|-------|
| `FileScanner.swift:53` | `try?` swallows all errors in `matches` |
| `PrivilegedHelperClient.swift:46-53` | Only last error preserved — partial failures hidden |
| `ContentView.swift:401` | `DispatchQueue.main.async` instead of `MainActor` |

### MINOR
| File | Issue |
|------|-------|
| `ContentView.swift:219` | `print` in production path — path leakage risk |
| `ContentView.swift:24-27` | `ByteCountFormatter` static initialization is unconventional |

**Most urgent fix:** The missing path validation in `trashFiles` (CRITICAL #2) is the biggest security concern — any sandboxed app could pass `"/etc/passwd"` or similar. Add a validation check that the path is within a known uninstalled app bundle before deletion.
