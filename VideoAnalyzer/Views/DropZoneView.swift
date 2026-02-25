import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct DropZoneView: View {
    let onDrop: ([URL]) -> Void
    @State private var isTargeted = false

    nonisolated private static let supportedExtensions: Set<String> = [
        "mov", "mp4", "m4v", "m4a", "wav", "aiff", "mp3",
        "ts", "mkv", "webm", "avi", "flv", "wmv"
    ]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary,
                    style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                )

            VStack(spacing: 16) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 48))
                    .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)

                Text("Drop media files here to analyze")
                    .font(.title2)
                    .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)

                Text("or")
                    .font(.body)
                    .foregroundStyle(Color.secondary)

                Button("Open Files...") {
                    openFiles()
                }
                .font(.body)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        var resolvedURLs: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard
                    let data = item as? Data,
                    let url = URL(dataRepresentation: data, relativeTo: nil)
                else { return }
                let collected = DropZoneView.collectMediaFiles(from: [url])
                DispatchQueue.main.async {
                    resolvedURLs.append(contentsOf: collected)
                }
            }
        }

        group.notify(queue: .main) {
            if !resolvedURLs.isEmpty {
                onDrop(resolvedURLs)
            }
        }
    }

    private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .movie, .audio, .mpeg4Movie, .quickTimeMovie, .avi, .wav, .aiff, .mp3
        ]

        if panel.runModal() == .OK {
            onDrop(DropZoneView.collectMediaFiles(from: panel.urls))
        }
    }

    nonisolated private static func collectMediaFiles(from urls: [URL]) -> [URL] {
        var results: [URL] = []
        let fm = FileManager.default

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                guard let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for case let fileURL as URL in enumerator {
                    guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                    if Self.supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                        results.append(fileURL)
                    }
                }
            } else {
                if Self.supportedExtensions.contains(url.pathExtension.lowercased()) {
                    results.append(url)
                }
            }
        }

        return results
    }
}

#Preview {
    DropZoneView { urls in
        print("Dropped: \(urls)")
    }
    .frame(width: 600, height: 400)
}
