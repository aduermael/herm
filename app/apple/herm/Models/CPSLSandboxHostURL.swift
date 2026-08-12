import Foundation

/// Pure virtual-path helpers for the CPSL sandbox (non-iCloud host mapping).
/// Used by file preview/share resolution so tests can exercise the shipped mapping.
nonisolated enum CPSLSandboxHostURL {
    /// Normalizes a CPSL virtual path (leading slash, collapse `.` / `..`, optional trim).
    static func normalize(
        _ path: String,
        trimsOuterWhitespace: Bool = true
    ) -> String {
        var normalized = trimsOuterWhitespace
            ? path.trimmingCharacters(in: .whitespacesAndNewlines)
            : path
        if normalized.isEmpty {
            normalized = "/"
        }
        if !normalized.hasPrefix("/") {
            normalized = "/\(normalized)"
        }
        var components: [String] = []
        for component in normalized.split(separator: "/") {
            let pathComponent = String(component)
            switch pathComponent {
            case ".", "":
                continue
            case "..":
                _ = components.popLast()
            default:
                components.append(pathComponent)
            }
        }
        return components.isEmpty ? "/" : "/\(components.joined(separator: "/"))"
    }

    /// Maps a non-iCloud virtual path to a host file URL under the sandbox root.
    /// Virtual `/home/herm/note.txt` → `{sandboxRoot}/home/herm/note.txt`.
    static func hostFileURL(
        virtualPath: String,
        sandboxRoot: URL
    ) -> URL {
        let normalized = normalize(virtualPath)
        var url = sandboxRoot
        let relative = normalized == "/" ? "" : String(normalized.dropFirst())
        for component in relative.split(separator: "/") where !component.isEmpty {
            url.appendPathComponent(String(component))
        }
        return url
    }
}
