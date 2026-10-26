import Foundation
import CryptoKit

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("YeetkixUpdateFixture-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
defer { try? fm.removeItem(at: root) }
let key = Curve25519.Signing.PrivateKey()
let seed = root.appendingPathComponent("fixture-seed")
try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: seed)
try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: seed.path)
let payload = Data("Only generated YEETKIX update test data".utf8)
let archive = root.appendingPathComponent("fixture.zip"); try payload.write(to: archive)
let process = Process(); let output = Pipe()
process.executableURL = URL(fileURLWithPath: ".build/artifacts/sparkle/Sparkle/bin/sign_update").standardizedFileURL
process.arguments = ["--ed-key-file", seed.path, "-p", archive.path]
process.standardOutput = output; process.standardError = FileHandle.standardError
try process.run()
let signatureText = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
process.waitUntilExit()
guard process.terminationStatus == 0, let signature = Data(base64Encoded: signatureText), key.publicKey.isValidSignature(signature, for: payload), !key.publicKey.isValidSignature(signature, for: payload + Data([1])) else {
    fputs("Update signature check failed\n", stderr); exit(1)
}
print("PASS Sparkle Ed25519 signing; altered archive rejected; only disposable local fixture used")
