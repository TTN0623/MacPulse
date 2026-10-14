// Vòng đời app khi phát cho người khác: chuyển vào thư mục Ứng dụng, gỡ cài đặt sạch.
import AppKit

enum AppLocation {
    /// Chạy thẳng từ file .dmg hoặc từ bản tạm macOS cách ly (App Translocation) thì
    /// helper, mở cùng máy và tự cập nhật đều hỏng; đề nghị chuyển vào /Applications.
    static func offerMoveIfNeeded() {
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") else { return }
        let alert = NSAlert()
        alert.messageText = "Chuyển MacPulse vào thư mục Ứng dụng?"
        alert.informativeText = "MacPulse đang chạy từ file cài đặt. Để điều khiển quạt, mở cùng máy và tự cập nhật hoạt động đúng, app cần nằm trong thư mục Ứng dụng."
        alert.addButton(withTitle: "Chuyển và mở lại")
        alert.addButton(withTitle: "Để sau")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let fm = FileManager.default
        var dest = URL(fileURLWithPath: "/Applications/MacPulse.app")
        if !fm.isWritableFile(atPath: "/Applications") {
            dest = URL(fileURLWithPath: NSHomeDirectory() + "/Applications/MacPulse.app")
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        do {
            if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
            try fm.copyItem(at: Bundle.main.bundleURL, to: dest)
            // Người dùng đã đồng ý mở app này; bỏ cờ cách ly trên bản chép để khỏi bị hỏi lại.
            _ = try? Updater.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", dest.path]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            let a = NSAlert()
            a.messageText = "Không chuyển được"
            a.informativeText = "Hãy tự kéo MacPulse vào thư mục Ứng dụng rồi mở lại. (\(error.localizedDescription))"
            a.runModal()
        }
    }
}

enum Uninstaller {
    /// Gỡ helper quạt (hỏi mật khẩu), bỏ mở cùng máy, xóa cài đặt, đưa app vào Thùng rác.
    static func run(fan: FanController) {
        let alert = NSAlert()
        alert.messageText = "Gỡ MacPulse khỏi máy?"
        alert.informativeText = "Quạt trở về chế độ mặc định của macOS. Helper quạt, mục mở cùng máy và cài đặt của MacPulse sẽ bị xóa; app được chuyển vào Thùng rác."
        alert.addButton(withTitle: "Gỡ")
        alert.addButton(withTitle: "Hủy")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        fan.releaseOnQuit()
        if fan.helperInstalled, let res = Bundle.main.resourcePath {
            let cmd = "/bin/bash '\(res)/uninstall-helper.sh'"
            let script = "do shell script \"\(cmd)\" with prompt \"Gỡ helper quạt của MacPulse.\" with administrator privileges"
            _ = try? Updater.run("/usr/bin/osascript", ["-e", script])
        }
        try? FileManager.default.removeItem(atPath: Prefs.agentPath)
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
