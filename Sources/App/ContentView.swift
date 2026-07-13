import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DroppedApp: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let icon: NSImage

    static func == (lhs: DroppedApp, rhs: DroppedApp) -> Bool {
        lhs.url == rhs.url
    }
}

struct FileItem: Identifiable {
    let id = UUID()
    let path: String
    let isDirectory: Bool
    let owner: String
    let size: Int64
}

private let byteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter
}()

struct ContentView: View {
    @State private var droppedApps: [DroppedApp] = []
    @State private var scanResults: [FileItem] = []
    @State private var isScanning = false
    @State private var isDeleting = false
    @State private var progress: Double = 0.0
    @State private var statusMessage = "Drop applications here to uninstall"
    @State private var showingDeleteConfirmation = false
    @State private var resultMessage: String?

    private var totalSize: Int64 {
        scanResults.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 20) {
                Text("CullApp")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                DropZoneView(droppedApps: $droppedApps, isScanning: isScanning || isDeleting)
                    .frame(height: 200)
                    .padding(.horizontal)

                if !droppedApps.isEmpty {
                    HStack {
                        Button("Scan for Leftover Files") {
                            scanApps()
                        }
                        .disabled(isScanning || isDeleting)

                        Button("Clear") {
                            droppedApps.removeAll()
                            scanResults.removeAll()
                            statusMessage = "Drop applications here to uninstall"
                        }
                        .disabled(isScanning || isDeleting)
                    }
                }

                if isScanning || isDeleting {
                    VStack(spacing: 8) {
                        HStack(spacing: 6) {
                            templateIcon("IconScan", size: 14)
                                .foregroundColor(.blue)
                            Text(statusMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        ProgressView(value: progress)
                            .progressViewStyle(LinearProgressViewStyle())
                            .frame(width: 400)
                    }
                }

                if !scanResults.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        List(scanResults) { item in
                            HStack {
                                templateIcon(item.isDirectory ? "IconFolder" : "IconFile", size: 14)
                                    .foregroundColor(item.isDirectory ? .blue : .secondary)
                                Text(item.path)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(byteFormatter.string(fromByteCount: item.size))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(item.owner)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(height: 150)

                        Text("\(scanResults.count) items · \(byteFormatter.string(fromByteCount: totalSize)) total")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Button {
                        showingDeleteConfirmation = true
                    } label: {
                        HStack {
                            templateIcon("IconTrash", size: 14)
                            Text("Move to Trash")
                        }
                    }
                    .disabled(isScanning || isDeleting)
                }

                Spacer()
            }
            .padding()
            .frame(minWidth: 600, minHeight: 500)
            .blur(radius: showingDeleteConfirmation || resultMessage != nil ? 3 : 0)
            .disabled(showingDeleteConfirmation || resultMessage != nil)

            if showingDeleteConfirmation {
                DialogOverlay {
                    ConfirmationCard(
                        itemCount: scanResults.count,
                        totalSize: byteFormatter.string(fromByteCount: totalSize),
                        onCancel: { showingDeleteConfirmation = false },
                        onConfirm: {
                            showingDeleteConfirmation = false
                            deleteFiles()
                        }
                    )
                }
            }

            if let resultMessage {
                DialogOverlay {
                    ResultCard(message: resultMessage) {
                        self.resultMessage = nil
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: showingDeleteConfirmation)
        .animation(.easeOut(duration: 0.15), value: resultMessage)
    }

    private func scanApps() {
        isScanning = true
        scanResults = []
        progress = 0.0
        statusMessage = "Scanning..."

        Task {
            var allItems: [FileItem] = []
            let scanner = FileScanner()

            for (index, app) in droppedApps.enumerated() {
                await MainActor.run {
                    statusMessage = "Scanning \(app.url.lastPathComponent)..."
                    progress = Double(index) / Double(droppedApps.count)
                }

                let items = await scanner.scan(appURL: app.url)
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
                await MainActor.run {
                    statusMessage = "Requesting authorization for system files..."
                }
                await helper.installHelperIfNeeded()

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
                let freedSize = deleted.reduce(0) { $0 + $1.size }
                scanResults.removeAll()
                droppedApps.removeAll()
                statusMessage = "Drop applications here to uninstall"
                resultMessage = "Moved \(deletedCount) items to Trash and freed \(byteFormatter.string(fromByteCount: freedSize))."
            }
        }
    }
}

/// Renders a reicon-derived SVG asset (see Resources/Assets.xcassets) as a tintable template image.
private func templateIcon(_ name: String, size: CGFloat) -> some View {
    Image(name)
        .renderingMode(.template)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
}

private struct DialogOverlay<Content: View>: View {
    let content: () -> Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
            content()
                .padding(24)
                .frame(width: 380)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.regularMaterial)
                        .shadow(radius: 20)
                )
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

private struct ConfirmationCard: View {
    let itemCount: Int
    let totalSize: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            templateIcon("IconWarning", size: 40)
                .foregroundColor(.orange)

            Text("Move \(itemCount) items to Trash?")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("This will free up \(totalSize) of disk space. Files can be restored from the Trash afterwards.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("Move to Trash", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct ResultCard: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            templateIcon("IconCheck", size: 40)
                .foregroundColor(.green)

            Text("Done")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("OK", action: onDismiss)
                .keyboardShortcut(.defaultAction)
        }
    }
}

struct DropZoneView: View {
    @Binding var droppedApps: [DroppedApp]
    var isScanning: Bool
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .stroke(style: StrokeStyle(lineWidth: 2, dash: isTargeted ? [] : [8]))
                .foregroundColor(isTargeted ? .accentColor : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.1))
                )
                .animation(.easeOut(duration: 0.15), value: isTargeted)

            if droppedApps.isEmpty {
                VStack(spacing: 12) {
                    templateIcon("IconAppBox", size: 44)
                        .foregroundColor(isTargeted ? .accentColor : .blue)
                        .scaleEffect(isTargeted ? 1.1 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isTargeted)

                    Text("Drop .app files here")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 12) {
                        ForEach(droppedApps) { app in
                            VStack(spacing: 6) {
                                ZStack(alignment: .topTrailing) {
                                    Image(nsImage: app.icon)
                                        .resizable()
                                        .frame(width: 48, height: 48)

                                    Button {
                                        droppedApps.removeAll { $0.id == app.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 8, y: -8)
                                }

                                Text(app.url.deletingPathExtension().lastPathComponent)
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard !isScanning else { return false }

            var didAccept = false
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          url.pathExtension == "app" else { return }

                    let icon = NSWorkspace.shared.icon(forFile: url.path)

                    DispatchQueue.main.async {
                        if !droppedApps.contains(where: { $0.url == url }) {
                            droppedApps.append(DroppedApp(url: url, icon: icon))
                        }
                    }
                }
                didAccept = true
            }
            return didAccept
        }
    }
}
