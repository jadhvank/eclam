import Foundation

@main enum OmpHookTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let template = try String(contentsOf: root.appendingPathComponent("Resources/omp-hook.js"), encoding: .utf8)
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("extensions/electric-clam.ts")
        let binary = "/tmp/App 'quoted' $(literal)/eclam-hook"
        try OmpHook.install(template: template, hookBinary: binary, at: file)
        precondition(OmpHook.isInstalled(at: file))
        let installed = try Data(contentsOf: file)
        try OmpHook.install(template: template, hookBinary: binary, at: file)
        let reinstalled = try Data(contentsOf: file)
        precondition(installed == reinstalled)
        try installed.write(to: output)
        try OmpHook.uninstall(at: file)
        try OmpHook.uninstall(at: file)
        precondition(!fm.fileExists(atPath: file.path))
        try Data("// my extension\n".utf8).write(to: file)
        do {
            try OmpHook.install(template: template, hookBinary: binary, at: file)
            preconditionFailure("must preserve an unrelated extension")
        } catch { }
        try OmpHook.uninstall(at: file)
        let untouched = try String(contentsOf: file, encoding: .utf8)
        precondition(untouched == "// my extension\n")
        print("PASS omp installer: quoted paths, idempotent install/removal, unrelated files preserved")
    }
}
