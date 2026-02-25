import SwiftUI

struct ContentView: View {
    @State private var viewModel = AnalyzerViewModel()

    var body: some View {
        Group {
            if viewModel.entries.isEmpty {
                DropZoneView { urls in
                    viewModel.addFiles(urls: urls)
                }
            } else {
                VSplitView {
                    VStack(spacing: 0) {
                        FileListView(
                            entries: viewModel.entries,
                            selectedFileID: $viewModel.selectedFileID,
                            onRemove: { id in viewModel.removeFile(id: id) }
                        )
                        .frame(maxWidth: .infinity)

                        HStack {
                            Text(viewModel.overallProgress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if viewModel.entries.contains(where: { $0.isAnalyzing }) {
                                Button("Cancel All") {
                                    viewModel.cancelAll()
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            }
                            Text("Drop more files to add")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.bar)
                    }
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        handleDrop(providers: providers)
                        return true
                    }
                    .frame(minHeight: 120, idealHeight: 220)

                    DetailView(entry: viewModel.selectedEntry)
                        .frame(minHeight: 200, idealHeight: 300)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    openFiles()
                } label: {
                    Label("Open", systemImage: "plus")
                }

                Button {
                    viewModel.analyzeAllPending()
                } label: {
                    Label("Analyze All", systemImage: "play.fill")
                }
                .disabled(viewModel.entries.isEmpty)

                Button {
                    viewModel.clearAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(viewModel.entries.isEmpty)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFiles)) { _ in
            openFiles()
        }
        .onDeleteCommand {
            if let id = viewModel.selectedFileID {
                viewModel.removeFile(id: id)
            }
        }
        .task {
            await viewModel.setup()
        }
    }

    private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .audio, .mpeg4Movie, .quickTimeMovie, .avi, .wav, .aiff, .mp3]

        if panel.runModal() == .OK {
            viewModel.addFiles(urls: panel.urls)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        var resolvedURLs: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    resolvedURLs.append(url)
                }
            }
        }

        group.notify(queue: .main) {
            if !resolvedURLs.isEmpty {
                viewModel.addFiles(urls: resolvedURLs)
            }
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 800, height: 500)
}
