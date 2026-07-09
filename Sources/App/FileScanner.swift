import Foundation

actor FileScanner {

    func scan(appURL: URL) async -> [FileItem] {
        var items: [FileItem] = []

        // Add the app bundle itself
        items.append(FileItem(path: appURL.path, isDirectory: true, owner: getOwner(at: appURL.path)))

        // Search in ~/Library/Application Support/
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        items.append(contentsOf: searchDirectory(appSupport, appName: appURL.deletingPathExtension().lastPathComponent))

        // Search in ~/Library/
        let libraryUser = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
        let appName = appURL.deletingPathExtension().lastPathComponent
        items.append(contentsOf: searchCachesAndPrefs(in: libraryUser, appName: appName))

        // Search in /Library/ (system)
        let librarySystem = URL(fileURLWithPath: "/Library")
        items.append(contentsOf: searchCachesAndPrefs(in: librarySystem, appName: appName))

        // Search in /Applications/ (system apps)
        let applications = URL(fileURLWithPath: "/Applications")
        items.append(contentsOf: searchDirectory(applications, appName: appName))

        // Search in ~/Library/Containers/ (sandboxed app data)
        let containers = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers")
        items.append(contentsOf: searchDirectory(containers, appName: appName))

        return items
    }

    private func searchDirectory(_ directory: URL, appName: String) -> [FileItem] {
        var items: [FileItem] = []

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [URLResourceKey.isDirectoryKey, URLResourceKey.pathKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            let fileName = fileURL.lastPathComponent
            if fileName.contains(appName) || fileName.hasPrefix(appName) {
                items.append(FileItem(
                    path: fileURL.path,
                    isDirectory: (try? fileURL.resourceValues(forKeys: [URLResourceKey.isDirectoryKey]).isDirectory) ?? false,
                    owner: getOwner(at: fileURL.path)
                ))
            }
        }

        return items
    }

    private func searchCachesAndPrefs(in directory: URL, appName: String) -> [FileItem] {
        var items: [FileItem] = []
        let subdirs = ["Caches", "Preferences", "Logs", "Application Support"]

        for subdir in subdirs {
            let path = directory.appendingPathComponent(subdir)
            items.append(contentsOf: searchDirectory(path, appName: appName))
        }

        return items
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
