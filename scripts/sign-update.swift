// Signs a release download so Bobcorn's updater can tell it came from us:
// an Ed25519 signature over the file, printed in base64.
//
//   UPDATE_SIGNING_KEY=<base64 private key> swift scripts/sign-update.swift build/Bobcorn.dmg
//   swift scripts/sign-update.swift --new-key <file>
//
// --new-key writes a new private key to <file> (keep it secret: it goes in
// the repository's UPDATE_SIGNING_KEY secret) and prints the public key,
// which goes in Updater.swift.
import CryptoKit
import Foundation

let args = CommandLine.arguments
if args.count == 3, args[1] == "--new-key" {
    let key = Curve25519.Signing.PrivateKey()
    let url = URL(fileURLWithPath: args[2])
    FileManager.default.createFile(atPath: url.path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                   attributes: [.posixPermissions: 0o600])
    print(key.publicKey.rawRepresentation.base64EncodedString())
    exit(0)
}
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: sign-update.swift <file> | --new-key <file>\n".utf8))
    exit(2)
}
guard let encoded = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"],
      let raw = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
else {
    FileHandle.standardError.write(Data("UPDATE_SIGNING_KEY is missing or not a key\n".utf8))
    exit(1)
}
let file = try Data(contentsOf: URL(fileURLWithPath: args[1]))
print(try key.signature(for: file).base64EncodedString())
