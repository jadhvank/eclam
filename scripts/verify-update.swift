import Foundation
import CryptoKit

// Verify with the embedded public key; never request Keychain/private-key access.
guard CommandLine.arguments.count == 4,
      let publicKey = Data(base64Encoded: CommandLine.arguments[1]),
      let signature = Data(base64Encoded: CommandLine.arguments[3]) else {
    fputs("Usage: verify-update.swift PUBLIC_KEY ARCHIVE SIGNATURE\n", stderr)
    exit(1)
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    guard key.isValidSignature(signature, for: archive) else {
        fputs("ERROR: archive Ed25519 signature is invalid\n", stderr)
        exit(1)
    }
    print("OK: archive Ed25519 signature matches the app public key")
} catch {
    fputs("ERROR: \(error)\n", stderr)
    exit(1)
}
