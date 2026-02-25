import SwiftUI

struct ContentView: View {
    @State private var droppedURLs: [URL] = []

    var body: some View {
        if droppedURLs.isEmpty {
            DropZoneView { urls in
                droppedURLs = urls
            }
        } else {
            VStack {
                List(droppedURLs, id: \.self) { url in
                    Text(url.lastPathComponent)
                }
                Button("Clear") { droppedURLs = [] }
                    .padding()
            }
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 800, height: 500)
}
