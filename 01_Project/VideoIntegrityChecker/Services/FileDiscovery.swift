import Foundation

enum FileDiscovery {
    static let supportedExtensions: Set<String> = [
        "mov", "mp4", "m4v", "m4a", "wav", "aiff", "mp3",
        "ts", "mkv", "webm", "avi", "flv", "wmv", "mxf"
    ]

    /// Recursively collects media files from a list of URLs.
    /// Directories are traversed; non-media files are filtered out.
    static func collectMediaFiles(from urls: [URL]) -> [URL] {
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
                    if supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                        results.append(fileURL)
                    }
                }
            } else {
                if supportedExtensions.contains(url.pathExtension.lowercased()) {
                    results.append(url)
                }
            }
        }

        return results
    }
}
