import SwiftUI

struct ContentView: View {
    @State private var viewModel = AnalyzerViewModel()

    var body: some View {
        NavigationSplitView {
            if viewModel.entries.isEmpty {
                DropZoneView { urls in
                    viewModel.addFiles(urls: urls)
                }
            } else {
                VStack(spacing: 0) {
                    FileListView(
                        entries: viewModel.entries,
                        selectedFileID: $viewModel.selectedFileID,
                        onRemove: { id in viewModel.removeFile(id: id) }
                    )

                    HStack {
                        Text(viewModel.overallProgress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
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
            }
        } detail: {
            DetailView(entry: viewModel.selectedEntry)
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            await viewModel.setup()
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
