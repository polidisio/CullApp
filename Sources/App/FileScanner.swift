import Foundation

actor FileScanner {

    func scan(appURL: URL) async -> [FileItem] {
        var items: [FileItem] = []
        var seenPaths = Set<String>()

        func add(_ path: String, isDirectory: Bool) {
            guard seenPaths.insert(path).inserted else { return }
            items.append(FileItem(
                path: path,
                isDirectory: isDirectory,
                owner: getOwner(at: path),
                size: sizeOf(path: path, isDirectory: isDirectory)
            ))
        }

        // The app bundle itself
        add(appURL.path, isDirectory: true)

        let appName = appURL.deletingPathExtension().lastPathComponent
        let bundleID = Bundle(url: appURL)?.bundleIdentifier

        let home = FileManager.default.homeDirectoryForCurrentUser
        let searchRoots: [URL] = [
            home.appendingPathComponent("Library/Application Support"),
            home.appendingPathComponent("Library/Caches"),
            home.appendingPathComponent("Library/Preferences"),
            home.appendingPathComponent("Library/Logs"),
            home.appendingPathComponent("Library/Containers"),
            home.appendingPathComponent("Library/Saved Application State"),
            home.appendingPathComponent("Library/WebKit"),
            URL(fileURLWithPath: "/Library/Application Support"),
            URL(fileURLWithPath: "/Library/Caches"),
            URL(fileURLWithPath: "/Library/Preferences"),
            URL(fileURLWithPath: "/Library/LaunchAgents"),
            URL(fileURLWithPath: "/Library/LaunchDaemons"),
        ]

        for root in searchRoots {
            for match in matches(in: root, appName: appName, bundleID: bundleID) {
                add(match.path, isDirectory: match.isDirectory)
            }
        }

        return items.sorted { $0.path < $1.path }
    }

    private func matches(in directory: URL, appName: String, bundleID: String?) -> [(path: String, isDirectory: Bool)] {
        var results: [(path: String, isDirectory: Bool)] = []

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for entryURL in contents {
            let fileName = entryURL.lastPathComponent
            let isDirectory = (try? entryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            if fileNameMatches(fileName, appName: appName, bundleID: bundleID) {
                results.append((entryURL.path, isDirectory))
            }
        }

        return results
    }

    private func fileNameMatches(_ fileName: String, appName: String, bundleID: String?) -> Bool {
        let lowerName = fileName.lowercased()
        let lowerAppName = appName.lowercased()

        if let bundleID, !bundleID.isEmpty, lowerName.contains(bundleID.lowercased()) {
            return true
        }

        return lowerName.contains(lowerAppName)
    }

    private func sizeOf(path: String, isDirectory: Bool) -> Int64 {
        let fileManager = FileManager.default

        if !isDirectory {
            let attributes = try? fileManager.attributesOfItem(atPath: path)
            return (attributes?[.size] as? Int64) ?? 0
        }

        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileAllocatedSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileAllocatedSizeKey, .isDirectoryKey])
            if values?.isDirectory == false {
                total += Int64(values?.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    private func getOwner(at path: String) -> String {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            if let uid = attributes[.ownerAccountID] as? Int {
                let user = getpwuid(uid_t(uid))
                if let name = user?.pointee.pw_name {
                    return String(cString: name)
                }
            }
        } catch {
            return "unknown"
        }
        return "unknown"
    }
}
