import SwiftUI

struct SettingsView: View {
    @AppStorage("ffmpegPath") private var ffmpegPath: String = ""
    @AppStorage("concurrencyLimit") private var concurrencyLimit: Int = 2
    @AppStorage("analysisDepth") private var analysisDepth: String = "deep"

    @State private var detectedFFmpegPath: String?
    @State private var isDetecting = false

    var body: some View {
        Form {
            Section("ffmpeg") {
                LabeledContent("Status") {
                    if let path = detectedFFmpegPath ?? (ffmpegPath.isEmpty ? nil : ffmpegPath) {
                        Label("Available", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Not Found", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }

                LabeledContent("Custom Path") {
                    HStack {
                        TextField("Auto-detect", text: $ffmpegPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse...") {
                            browseForFFmpeg()
                        }
                    }
                }

                Button("Detect Automatically") {
                    detectFFmpeg()
                }
                .disabled(isDetecting)

                Text("ffmpeg enables analysis of MKV, WebM, AVI, and other formats not supported by AVFoundation. Install via Homebrew: brew install ffmpeg")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Analysis") {
                Picker("Depth", selection: $analysisDepth) {
                    Text("Quick (metadata only)").tag("quick")
                    Text("Deep (full decode)").tag("deep")
                }
                .pickerStyle(.radioGroup)

                Stepper("Concurrent analyses: \(concurrencyLimit)", value: $concurrencyLimit, in: 1...8)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450)
        .padding()
        .onAppear {
            detectFFmpeg()
        }
    }

    private func browseForFFmpeg() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select the ffmpeg binary"

        if panel.runModal() == .OK, let url = panel.url {
            ffmpegPath = url.path
        }
    }

    private func detectFFmpeg() {
        isDetecting = true
        let paths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg"
        ]
        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                detectedFFmpegPath = path
                isDetecting = false
                return
            }
        }
        detectedFFmpegPath = nil
        isDetecting = false
    }
}
