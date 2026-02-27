import SwiftUI

extension Notification.Name {
    static let openFiles = Notification.Name("openFiles")
}

@main
struct VideoIntegrityCheckerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 500)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Files...") {
                    NotificationCenter.default.post(name: .openFiles, object: nil)
                }
                .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView()
        }
    }
}
