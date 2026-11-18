import Foundation

/// The extension is opt-in, owns a separate file, and never edits omp settings.
enum OmpHook {
    static let marker = "// Electric Clam managed omp hook v1\n"

    static func isInstalled(at url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.hasPrefix(marker)
    }

    static func install(template: String, hookBinary: String, at url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path), !isInstalled(at: url) {
            throw NSError(domain: "com.jadhvank.eclam.hook", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The omp extension path already contains an unrelated file: \(url.path)"])
        }
        let literal = String(decoding: try JSONEncoder().encode(hookBinary), as: UTF8.self)
        let text = template.replacingOccurrences(of: "__ECLAM_HOOK_BINARY__", with: literal)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    static func uninstall(at url: URL) throws {
        guard isInstalled(at: url) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
