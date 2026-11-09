// Verifies a Sparkle EdDSA signature against the public key embedded in the app.
// Usage: swift scripts/verify-update.swift <SUPublicEDKey> <edSignature> <zip>
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 4,
      let publicKeyData = Data(base64Encoded: CommandLine.arguments[1]),
      let signature = Data(base64Encoded: CommandLine.arguments[2]) else {
    FileHandle.standardError.write(Data("Usage: verify-update.swift <public-key> <signature> <zip>\n".utf8))
    exit(1)
}

let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]), options: .mappedIfSafe)
guard publicKey.isValidSignature(signature, for: archive) else {
    FileHandle.standardError.write(Data("Sparkle signature does not match the app's SUPublicEDKey.\n".utf8))
    exit(1)
}
print("Sparkle signature verified.")
