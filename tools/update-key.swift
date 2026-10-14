// Khóa ký bản cập nhật (Ed25519).
//   swift tools/update-key.swift generate        tạo khóa (một lần), in khóa công khai
//   swift tools/update-key.swift public          in lại khóa công khai
//   swift tools/update-key.swift sign <file>     in chữ ký base64 của file
// Khóa bí mật nằm ở ~/.config/macpulse/update_ed25519.key, KHÔNG đưa vào git. Mất khóa này thì
// người dùng cũ không nhận được bản cập nhật tự động nữa, nên hãy sao lưu nó.
import CryptoKit
import Foundation

let keyPath = NSHomeDirectory() + "/.config/macpulse/update_ed25519.key"
let args = CommandLine.arguments.dropFirst()

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: keyPath, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        FileHandle.standardError.write("Chưa có khóa ở \(keyPath). Chạy: swift tools/update-key.swift generate\n".data(using: .utf8)!)
        exit(1)
    }
    return key
}

switch args.first {
case "generate":
    if FileManager.default.fileExists(atPath: keyPath) {
        FileHandle.standardError.write("Đã có khóa ở \(keyPath), không ghi đè.\n".data(using: .utf8)!)
        exit(1)
    }
    let key = Curve25519.Signing.PrivateKey()
    try! FileManager.default.createDirectory(atPath: (keyPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: keyPath, contents: key.rawRepresentation.base64EncodedString().data(using: .utf8),
                                   attributes: [.posixPermissions: 0o600])
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let file = args.dropFirst().first, let data = FileManager.default.contents(atPath: file) else {
        FileHandle.standardError.write("Cách dùng: sign <file>\n".data(using: .utf8)!)
        exit(1)
    }
    print(try! loadKey().signature(for: data).base64EncodedString())
default:
    FileHandle.standardError.write("Lệnh: generate | public | sign <file>\n".data(using: .utf8)!)
    exit(1)
}
