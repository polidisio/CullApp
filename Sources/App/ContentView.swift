import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var droppedApps: [URL] = []
    @State private var scanResults: [FileItem] = []
    @State private var isScanning = false
    @State private var isDeleting = false
    @State private var progress: Double = 0.0
    @State private var statusMessage = "Drop applications here to uninstall"
    @State private var showingAlert = false
    @State private var alertMessage = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("CullApp")
                .font(.largeTitle)
                .fontWeight(.bold)

            DropZoneView(droppedApps: $droppedApps, isScanning: $isScanning)
                .frame(height: 200)
                .padding(.horizontal)

            if !droppedApps.isEmpty {
                Button("Scan for Files") {
                    scanApps()
                }
                .disabled(isScanning || isDeleting)
            }

            if isScanning || isDeleting {
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(width: 400)

                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if !scanResults.isEmpty {
                List(scanResults) { item in
                    HStack {
                        Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                            .foregroundColor(item.isDirectory ? .blue : .secondary)
                        Text(item.path)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text(item.owner)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(height: 150)

                Button("Move to Trash") {
                    deleteFiles()
                }
                .disabled(isScanning || isDeleting)
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 600, minHeight: 500)
        .alert("CullApp", isPresented: $showingAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
    }

    private func scanApps() {
        isScanning = true
        scanResults = []
        progress = 0.0
        statusMessage = "Scanning..."

        Task {
            var allItems: [FileItem] = []
            let scanner = FileScanner()

            for (index, appURL) in droppedApps.enumerated() {
                await MainActor.run {
                    statusMessage = "Scanning \(appURL.lastPathComponent)..."
                    progress = Double(index) / Double(droppedApps.count)
                }

                let items = await scanner.scan(appURL: appURL)
                allItems.append(contentsOf: items)
            }

            await MainActor.run {
                scanResults = allItems
                isScanning = false
                progress = 1.0
                statusMessage = "Found \(scanResults.count) files"
            }
        }
    }

    private func deleteFiles() {
        isDeleting = true
        progress = 0.0
        statusMessage = "Moving files to Trash..."

        Task {
            let helper = PrivilegedHelperClient.shared
            await helper.installHelperIfNeeded()

            let userFiles = scanResults.filter { $0.owner != "root" }
            let rootFiles = scanResults.filter { $0.owner == "root" }

            var deleted: [FileItem] = []

            // Delete user-owned files directly
            for (index, item) in userFiles.enumerated() {
                await MainActor.run {
                    statusMessage = "Trashing \(item.path)"
                    progress = Double(index) / Double(scanResults.count)
                }

                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                    deleted.append(item)
                } catch {
                    print("Failed to trash \(item.path): \(error)")
                }
            }

            // Delete root-owned files via privileged helper
            if !rootFiles.isEmpty {
                let rootPaths = rootFiles.map { $0.path }
                let success = await helper.trashFiles(rootPaths)

                if success {
                    deleted.append(contentsOf: rootFiles)
                }
            }

            await MainActor.run {
                isDeleting = false
                progress = 1.0
                let deletedCount = deleted.count
                scanResults.removeAll()
                droppedApps.removeAll()
                statusMessage = "Trashed \(deletedCount) items"
                alertMessage = "Successfully moved \(deletedCount) items to Trash."
                showingAlert = true
            }
        }
    }
}

struct FileItem: Identifiable {
    let id = UUID()
    let path: String
    let isDirectory: Bool
    let owner: String
}

struct DropZoneView: View {
    @Binding var droppedApps: [URL]
    @Binding var isScanning: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .stroke(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundColor(.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.1))
                )

            VStack(spacing: 12) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.blue)

                Text("Drop .app files here")
                    .font(.headline)
                    .foregroundColor(.secondary)

                if !droppedApps.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(droppedApps, id: \.absoluteString) { url in
                            Text(url.lastPathComponent)
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !isScanning else { return false }

            providers.forEach { provider in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          url.pathExtension == "app" else { return }

                    DispatchQueue.main.async {
                        if !droppedApps.contains(url) {
                            droppedApps.append(url)
                        }
                    }
                }
            }
            return true
        }
    }
}
