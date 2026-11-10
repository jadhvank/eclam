import Foundation
import CryptoKit

@main
enum UpdateSignatureTests {
    static func main() throws {
        let verifier = CommandLine.arguments[1]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("update.zip")
        let data = Data("signed update fixture".utf8)
        try data.write(to: archive)
        // Test-only key remains in memory; no access to the release Keychain.
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let signature = try key.signature(for: data).base64EncodedString()
        func verify(_ publicKey: String, _ signature: String, expected: Int32) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: verifier)
            process.arguments = [publicKey, archive.path, signature]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            precondition(process.terminationStatus == expected, "signature verifier outcome")
        }
        try verify(publicKey, signature, expected: 0)
        var corrupted = data
        corrupted[0] ^= 1 // same length, so a size check alone cannot catch it
        try corrupted.write(to: archive)
        try verify(publicKey, signature, expected: 1)
        try data.write(to: archive)
        let wrongKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        try verify(wrongKey, signature, expected: 1)
        try verify(publicKey, "not-base64", expected: 1)
        print("OK: archive signature valid, tampered bytes, wrong public key, malformed signature")
    }
}
