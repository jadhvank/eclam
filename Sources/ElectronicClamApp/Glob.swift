import Foundation
import Darwin

// MARK: - Glob

/// Tiny `~`-aware wrapper around POSIX `glob(3)`. No external deps.
enum Glob {
    static func expand(_ pattern: String) -> [String] {
        let resolved = expand_tildeOnly(pattern)
        var g = glob_t()
        defer { globfree(&g) }
        // Flags:
        //   GLOB_NOSORT  — order doesn't matter for "any match fresh?" check.
        //   GLOB_TILDE   — we already expanded `~`, but harmless if set; not all
        //                  libcs define it, so we leave it off and do it ourselves.
        let flags: Int32 = GLOB_NOSORT
        let rc = resolved.withCString { cstr in
            glob(cstr, flags, nil, &g)
        }
        guard rc == 0 else { return [] }
        var out: [String] = []
        out.reserveCapacity(Int(g.gl_pathc))
        if let v = g.gl_pathv {
            for i in 0..<Int(g.gl_pathc) {
                if let p = v[i] {
                    out.append(String(cString: p))
                }
            }
        }
        return out
    }

    /// Expand a leading `~` or `~/` to the current user's home directory.
    static func expand_tildeOnly(_ pattern: String) -> String {
        guard pattern.hasPrefix("~") else { return pattern }
        let home = NSHomeDirectory()
        if pattern == "~" { return home }
        if pattern.hasPrefix("~/") {
            return home + String(pattern.dropFirst(1))
        }
        // `~user/...` — not supported; pass through.
        return pattern
    }
}
