// Tự cập nhật qua GitHub Releases. Mỗi bản phát hành có:
//   MacPulse-<phiên bản>.zip      app đã nén
//   MacPulse-<phiên bản>.zip.sig  chữ ký Ed25519 (base64) của file zip
// App chỉ cài khi chữ ký khớp khóa công khai gắn sẵn (Info.plist: MPUpdatePublicKey),
// nên kể cả tài khoản GitHub bị chiếm, kẻ gian cũng không đẩy được bản giả.
import AppKit
import CryptoKit

final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, notes: String)
        case downloading
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "update.autoCheck") }
    }

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private let repo = Bundle.main.object(forInfoDictionaryKey: "MPUpdateRepo") as? String ?? ""
    private let publicKey = Bundle.main.object(forInfoDictionaryKey: "MPUpdatePublicKey") as? String ?? ""
    private var release: (version: String, zip: URL, sig: URL, page: URL)?
    private var timer: Timer?

    var pageURL: URL? {
        release?.page ?? URL(string: "https://github.com/\(repo)/releases/latest")
    }

    var availableVersion: String? {
        if case .available(let v, _) = state { return v }
        return nil
    }

    init() {
        autoCheck = UserDefaults.standard.object(forKey: "update.autoCheck") as? Bool ?? true
        // Kiểm tra sau khi mở app 20 giây, rồi mỗi 24 giờ.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard autoCheck, !repo.isEmpty else { return }
        let last = UserDefaults.standard.object(forKey: "update.lastCheck") as? Date ?? .distantPast
        if Date().timeIntervalSince(last) > 24 * 3600 { check(userInitiated: false) }
    }

    // MARK: Kiểm tra

    func check(userInitiated: Bool = true) {
        guard !repo.isEmpty else { state = .failed("Bản build này chưa gắn repo cập nhật."); return }
        if case .downloading = state { return }
        state = .checking
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MacPulse/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                UserDefaults.standard.set(Date(), forKey: "update.lastCheck")
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    let code = (resp as? HTTPURLResponse)?.statusCode
                    self.state = userInitiated
                        ? .failed(code == 404 ? "Chưa có bản phát hành nào." : "Không kiểm tra được (\(err?.localizedDescription ?? "mã \(code ?? 0)")).")
                        : .idle
                    return
                }
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let assets = json["assets"] as? [[String: Any]] ?? []
                func asset(_ suffix: String) -> URL? {
                    assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }
                        .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
                }
                guard Updater.isNewer(version, than: self.currentVersion) else {
                    self.state = userInitiated ? .upToDate : .idle
                    return
                }
                guard let zip = asset(".zip"), let sig = asset(".zip.sig") else {
                    self.state = userInitiated ? .failed("Bản \(version) thiếu file cài hoặc chữ ký.") : .idle
                    return
                }
                let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? self.pageURL!
                self.release = (version, zip, sig, page)
                self.state = .available(version: version, notes: json["body"] as? String ?? "")
            }
        }.resume()
    }

    /// So sánh "1.10.0" > "1.9.2" theo từng số.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    // MARK: Tải, kiểm chữ ký, thay app

    func install() {
        guard let r = release else { return }
        state = .downloading
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("macpulse-update-\(UUID().uuidString)")
        Task.detached {
            do {
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let (zipFile, _) = try await URLSession.shared.download(from: r.zip)
                let (sigData, _) = try await URLSession.shared.data(from: r.sig)
                let zipData = try Data(contentsOf: zipFile)
                try Updater.verify(zipData, signature: sigData, publicKey: self.publicKey)
                await MainActor.run { self.state = .installing }
                let zipPath = tmp.appendingPathComponent("update.zip")
                try zipData.write(to: zipPath)
                try Updater.run("/usr/bin/ditto", ["-x", "-k", zipPath.path, tmp.path])
                let newApp = tmp.appendingPathComponent("MacPulse.app")
                try Updater.checkBundle(newApp, version: r.version)
                try await MainActor.run { try self.replaceAndRelaunch(with: newApp) }
            } catch {
                await MainActor.run { self.state = .failed(error.localizedDescription) }
            }
        }
    }

    struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func verify(_ data: Data, signature: Data, publicKey: String) throws {
        let sigText = String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let keyData = Data(base64Encoded: publicKey), let sig = Data(base64Encoded: sigText),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw UpdateError(message: "Thiếu khóa hoặc chữ ký cập nhật.")
        }
        guard key.isValidSignature(sig, for: data) else {
            throw UpdateError(message: "Chữ ký bản cập nhật không khớp. Đã dừng, không cài.")
        }
    }

    static func checkBundle(_ app: URL, version: String) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError(message: "Gói cập nhật không đúng app hoặc sai phiên bản.")
        }
        if let minOS = info["LSMinimumSystemVersion"] as? String {
            let parts = minOS.split(separator: ".").map { Int($0) ?? 0 }
            let need = OperatingSystemVersion(majorVersion: parts.first ?? 0, minorVersion: parts.count > 1 ? parts[1] : 0, patchVersion: 0)
            guard ProcessInfo.processInfo.isOperatingSystemAtLeast(need) else {
                throw UpdateError(message: "Bản mới cần macOS \(minOS) trở lên.")
            }
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", app.path])
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else { throw UpdateError(message: "\((exe as NSString).lastPathComponent) lỗi: \(text)") }
        return text
    }

    private func replaceAndRelaunch(with newApp: URL) throws {
        let current = Bundle.main.bundleURL
        do {
            _ = try FileManager.default.replaceItemAt(current, withItemAt: newApp)
        } catch {
            throw UpdateError(message: "Không ghi được vào \(current.deletingLastPathComponent().path). Hãy tải bản mới ở trang phát hành.")
        }
        // Mở lại bản mới sau khi app này thoát hẳn.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1.5; /usr/bin/open \"$0\"", current.path]
        try p.run()
        NSApp.terminate(nil)
    }
}
