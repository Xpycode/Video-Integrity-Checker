import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct DropZoneView: View {
    let onDrop: ([URL]) -> Void
    @State private var isTargeted = false


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
                let collected = FileDiscovery.collectMediaFiles(from: [url])
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
            onDrop(FileDiscovery.collectMediaFiles(from: panel.urls))
        }
    }

}

#Preview {
    DropZoneView { urls in
        print("Dropped: \(urls)")
    }
    .frame(width: 600, height: 400)
}
