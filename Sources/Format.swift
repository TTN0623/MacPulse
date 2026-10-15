// Định dạng số liệu kiểu Việt Nam và thông tin máy.
import Foundation
import IOKit

enum SystemInfo {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func int(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
    }

    static let chip = string("machdep.cpu.brand_string") ?? "Mac"
    static let effCores = int("hw.perflevel1.logicalcpu") ?? 0
    static let model = string("hw.model") ?? ""
    /// MacBook Air/Pro có pin và nắp gập; Mac mini, iMac, Studio, Pro thì không.
    static let isLaptop = model.hasPrefix("MacBook") || hasBattery
    static let hasBattery: Bool = {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        defer { if s != 0 { IOObjectRelease(s) } }
        return s != 0
    }()
    static let subtitle: String = {
        var mem: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &mem, &size, nil, 0)
        return "\(chip) · \(mem / 1_073_741_824) GB RAM"
    }()
}

enum Fmt {
    static let vi = Locale(identifier: "vi_VN")

    static func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    static func temp(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))°C" } ?? "–" }

    static func bytes(_ b: Double) -> String {
        let gb = b / 1_073_741_824
        // Từ ~0,95 GB ghi theo GB, tránh kiểu "1.017 MB" dễ đọc nhầm thành 1,017.
        if gb >= 0.95 { return gb.formatted(.number.precision(.fractionLength(1)).locale(vi)) + " GB" }
        return Int((b / 1_048_576).rounded()).formatted(.number.locale(vi)) + " MB"
    }

    static func rpm(_ v: Double) -> String { Int(v.rounded()).formatted(.number.locale(vi)) + " rpm" }

    static func cpuPct(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(1)).locale(vi)) + "%" }

    /// 75 -> "1 phút 15 giây", 4000 -> "1 giờ 6 phút"
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        if s < 60 { return "\(s) giây" }
        if s < 3600 { return s % 60 == 0 || s >= 600 ? "\(s / 60) phút" : "\(s / 60) phút \(s % 60) giây" }
        return s / 60 % 60 == 0 ? "\(s / 3600) giờ" : "\(s / 3600) giờ \(s / 60 % 60) phút"
    }

    static func ago(_ t: TimeInterval) -> String { t < 60 ? "vừa xong" : duration(t) + " trước" }

    /// Đồng hồ đếm ngược: 5400 -> "1:30:00", 75 -> "1:15"
    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.up)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// Tốc độ truyền: "425 KB/giây", "3,2 MB/giây".
    static func rate(_ bytesPerSec: Double) -> String {
        bytesPerSec >= 1_000_000
            ? (bytesPerSec / 1_048_576).formatted(.number.precision(.fractionLength(1)).locale(vi)) + " MB/giây"
            : Int((bytesPerSec / 1024).rounded()).formatted(.number.locale(vi)) + " KB/giây"
    }

    /// Dung lượng đã truyền, có KB cho số nhỏ: "850 KB", "215 MB", "1,4 GB".
    static func size(_ b: Double) -> String {
        b < 1_000_000 ? Int((b / 1024).rounded()).formatted(.number.locale(vi)) + " KB" : bytes(b)
    }
}
