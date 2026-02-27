import Foundation

/// Routes files to the appropriate container inspector based on extension and magic bytes.
/// Designed to be extended as new format inspectors are added.
struct ContainerInspectorRegistry: Sendable {

    private static let inspectors: [any ContainerInspector] = [
        ISOBMFFInspector(),
        MXFInspector(),
    ]

    /// Find the right inspector for a file URL.
    /// Checks extension first, then falls back to magic byte detection.
    static func inspector(for url: URL) -> (any ContainerInspector)? {
        let ext = url.pathExtension.lowercased()

        // Fast path: match by extension
        for inspector in inspectors {
            if type(of: inspector).supportedExtensions.contains(ext) {
                return inspector
            }
        }

        // Slow path: try magic byte detection
        for inspector in inspectors {
            if inspector.canInspect(url: url) {
                return inspector
            }
        }

        return nil
    }

    /// Run container inspection on a file, returning nil if no inspector matches.
    static func inspect(url: URL, depth: InspectionDepth = .standard) async throws -> ContainerReport? {
        guard let inspector = inspector(for: url) else { return nil }
        return try await inspector.inspect(url: url, depth: depth)
    }
}
