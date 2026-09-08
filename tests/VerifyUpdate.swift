import Foundation
import CryptoKit
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: CommandLine.arguments[2])!)
let signature = Data(base64Encoded: CommandLine.arguments[3])!
precondition(key.isValidSignature(signature, for: data), "Published archive signature must verify")
var tampered = data
if !tampered.isEmpty { tampered[0] ^= 0xff }
precondition(!key.isValidSignature(signature, for: tampered), "Tampered archive must be rejected")
let unrelated = Curve25519.Signing.PrivateKey().publicKey
precondition(!unrelated.isValidSignature(signature, for: data), "Unrelated publisher must be rejected")
print("PASS: archive signature, byte-tampering rejection and wrong-key rejection")
