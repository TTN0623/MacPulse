// MacPulse Fan Helper: tiến trình nền chạy bằng root (LaunchDaemon).
// Đọc file yêu cầu do app ghi rồi đặt tốc độ quạt:
//   "auto"                                  -> trả quạt cho macOS
//   "manual <phần trăm> <unix>"             -> giữ quạt ở mức đó
//   "smart <bắt đầu °C> <tối đa °C> <unix>" -> macOS điều khiển, helper chỉ tăng quạt khi chip vượt ngưỡng
// An toàn: yêu cầu manual/smart cũ hơn 20 giây (app đã tắt hoặc treo) thì về auto.
// Thủ công: chip từ 110°C thì quạt không chạy dưới 50% (macOS ở auto chỉ chạy ~45% khi 114°C),
// nguội dưới 100°C thì trả lại đúng mức người dùng đặt.
import Foundation
import CryptoKit

let requestPath = "/Library/Application Support/MacPulse/fan-request"
let powerPath = "/Library/Application Support/MacPulse/power-request"
let helperUpdateRequestPath = "/Library/Application Support/MacPulse/helper-update-request"
let autoUpdateFlagPath = "/Library/Application Support/MacPulse/helper-auto-update"
let selfPath = "/Library/PrivilegedHelperTools/com.tai.macpulse.fanhelper"
// Khóa công khai Ed25519 của MacPulse, phải khớp MPUpdatePublicKey trong Info.plist.
// Gắn cứng ở đây (file root) chứ không đọc từ app, vì app nằm ở chỗ người dùng sửa được.
let updatePublicKey = "kbC51KqEO8gdfyaFoenvnlHvJjLgRwpg1x/uOQK/5Rg="
let staleAfter: TimeInterval = 20
let hotOn = 110.0
let hotOff = 100.0
let hotFloor = 50.0

func log(_ msg: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    FileHandle.standardError.write("\(f.string(from: Date())) \(msg)\n".data(using: .utf8)!)
}

guard getuid() == 0 else {
    log("Cần chạy bằng root")
    exit(1)
}

guard let smc = try? SMC() else {
    log("Không mở được SMC")
    exit(1)
}

let fanCount = Int(smc.number("FNum") ?? 0)
let hasUnlockKey = smc.read("Ftst") != nil

// Mọi khóa nhiệt kiểu số thực, chia nhóm CPU và GPU. Số vô lý bị lọc ở từng lần đọc (avg, hottest),
// không lọc lúc khởi động vì nhân đang nghỉ có lúc đọc ra 0 hoặc âm.
func sensors(_ prefixes: [String]) -> [String] {
    smc.allKeys().filter { key in prefixes.contains(where: { key.hasPrefix($0) }) && smc.read(key)?.type == "flt " }
}
func spread(_ keys: [String], _ n: Int) -> [String] {
    let step = max(1, keys.count / n)
    return stride(from: 0, to: keys.count, by: step).map { keys[$0] }
}
let cpuKeys = sensors(["Tp", "Te"])
let gpuKeys = sensors(["Tg"])
func avg(_ keys: [String]) -> Double? {
    let v = keys.compactMap { smc.number($0) }.filter { $0 > 10 && $0 < 150 }
    return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
}

func hottest() -> Double {
    (cpuKeys + gpuKeys).compactMap { smc.number($0) }.filter { $0 > 10 && $0 < 150 }.max() ?? 0
}

struct SmartConfig: Equatable {
    var start: Double       // bắt đầu tăng quạt (°C, nhiệt điều khiển)
    var full: Double        // quạt tối đa
    var hot: Double         // chốt an toàn theo điểm nóng nhất
    var hotPct: Double      // mức quạt tối thiểu khi chạm chốt
    var hyst: Double        // phải nguội dưới start - hyst ...
    var hold: Double        // ... liên tục chừng này giây mới trả quyền cho macOS
}

enum Request: Equatable {
    case auto
    case manual(Double)
    case smart(SmartConfig)
}

var lastRequest: (req: Request, ts: Double)?

func readRequest() -> Request {
    // File mất = auto. Nội dung dở dang (đọc trúng lúc app đang ghi) thì giữ yêu cầu trước.
    guard let text = try? String(contentsOfFile: requestPath, encoding: .utf8) else { lastRequest = nil; return .auto }
    let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
    if parts.first == "auto" {
        lastRequest = nil
    } else if parts.count >= 3, parts[0] == "manual", let pct = Double(parts[1]), let ts = Double(parts[2]) {
        lastRequest = (.manual(max(0, min(100, pct))), ts)
    } else if parts.count >= 8, parts[0] == "smart" {
        // smart <start> <full> <hot> <hotPct> <hyst> <hold> <unix>
        let v = parts[1...7].compactMap { Double($0) }
        if v.count == 7, v[1] > v[0] {
            lastRequest = (.smart(SmartConfig(start: v[0], full: v[1], hot: v[2], hotPct: min(100, max(0, v[3])),
                                              hyst: v[4], hold: v[5])), v[6])
        }
    } else if parts.count >= 4, parts[0] == "smart", let s = Double(parts[1]), let f = Double(parts[2]), let ts = Double(parts[3]), f > s {
        lastRequest = (.smart(SmartConfig(start: s, full: f, hot: 108, hotPct: 100, hyst: 4, hold: 15)), ts)
    }
    guard let r = lastRequest, Date().timeIntervalSince1970 - r.ts <= staleAfter else { return .auto }
    return r.req
}

var controlling = false
var lastLogged = ""

func logOnce(_ msg: String) {
    if msg != lastLogged { log(msg); lastLogged = msg }
}

func applyPercent(_ pct: Double, label: String?) {
    // Apple Silicon đời mới: phải mở khóa Ftst thì thermalmonitord mới nhả quyền điều khiển quạt.
    if hasUnlockKey, smc.number("Ftst") != 1 {
        do { try smc.write("Ftst", number: 1) } catch { logOnce("Ghi Ftst lỗi: \(error)") }
    }
    controlling = true
    var states: [String] = []
    for i in 0..<fanCount {
        let minRPM = smc.number("F\(i)Mn") ?? 0
        let maxRPM = smc.number("F\(i)Mx") ?? 0
        guard maxRPM > minRPM else { continue }
        let target = (minRPM + (maxRPM - minRPM) * pct / 100).rounded()
        if smc.number("F\(i)Md") != 1 {
            do { try smc.write("F\(i)Md", number: 1) } catch {
                // Hệ thống chưa nhả quyền; vòng sau thử lại.
                states.append("quạt \(i) chờ mở khóa")
                continue
            }
        }
        if abs((smc.number("F\(i)Tg") ?? 0) - target) > 1 {
            do { try smc.write("F\(i)Tg", number: target) } catch {
                states.append("quạt \(i) ghi đích lỗi: \(error)")
                continue
            }
        }
        states.append("quạt \(i) -> \(Int(target)) rpm")
    }
    if let label { logOnce("\(label) \(Int(pct))%: " + states.joined(separator: ", ")) }
}

func resetToAuto(_ reason: String) {
    var failed = false
    for i in 0..<fanCount where smc.number("F\(i)Md") != 0 {
        if (try? smc.write("F\(i)Md", number: 0)) == nil {
            // Lúc máy ngủ hoặc tỉnh nền (DarkWake), SMC có thể từ chối; mở khóa Ftst rồi thử lại một lần.
            if hasUnlockKey { try? smc.write("Ftst", number: 1) }
            if (try? smc.write("F\(i)Md", number: 0)) == nil { failed = true }
        }
    }
    if !failed, hasUnlockKey, smc.number("Ftst") != 0, (try? smc.write("Ftst", number: 0)) == nil {
        failed = true
    }
    // Còn lỗi thì giữ cờ đang điều khiển để vòng sau (1 giây) thử lại, không bỏ quạt ở chế độ thủ công.
    controlling = failed
    logOnce(failed ? "Chưa trả được quạt về macOS (SMC từ chối, có thể máy đang ngủ), sẽ thử lại" : "Tự động (\(reason))")
}

/// Tốc độ quạt hiện tại quy ra % của khoảng thấp nhất..tối đa.
func currentPercent() -> Double {
    let v: [Double] = (0..<fanCount).compactMap { i in
        guard let a = smc.number("F\(i)Ac"), let mn = smc.number("F\(i)Mn"), let mx = smc.number("F\(i)Mx"), mx > mn else { return nil }
        return (a - mn) / (mx - mn) * 100
    }
    return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
}

// Lần chạy trước có thể bị dừng giữa chừng khi đang giữ quạt: dọn lại.
if hasUnlockKey, smc.number("Ftst") == 1 { controlling = true }
if (0..<fanCount).contains(where: { smc.number("F\($0)Md") == 1 }) { controlling = true }

log("Khởi động: \(fanCount) quạt, khóa Ftst: \(hasUnlockKey ? "có" : "không"), \(cpuKeys.count) cảm biến CPU, \(gpuKeys.count) cảm biến GPU")

let sigQueue = DispatchQueue(label: "signals")
var sources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: sigQueue)
    src.setEventHandler {
        DispatchQueue.main.async {
            if controlling { resetToAuto("helper dừng") }
            exit(0)
        }
    }
    src.resume()
    sources.append(src)
}

// MARK: Dự phòng tắt máy
// App ghi "shutdown <unix>" rồi xin macOS tắt máy. Nếu 3 phút sau helper vẫn còn chạy nghĩa là có app
// chặn tắt máy (thường do file chưa lưu); khi đó cho máy ngủ thay vì ép tắt để không mất dữ liệu.
let bootTime: Double = {
    var tv = timeval()
    var size = MemoryLayout<timeval>.size
    sysctlbyname("kern.boottime", &tv, &size, nil, 0)
    return Double(tv.tv_sec)
}()
try? "none\n".write(toFile: powerPath, atomically: false, encoding: .utf8)

func checkPowerRequest() {
    guard let text = try? String(contentsOfFile: powerPath, encoding: .utf8) else { return }
    let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
    guard parts.count >= 2, parts[0] == "shutdown", let ts = Double(parts[1]) else { return }
    let age = Date().timeIntervalSince1970 - ts
    guard ts > bootTime, age >= 180 else { return }
    try? "none\n".write(toFile: powerPath, atomically: false, encoding: .utf8)
    guard age < 3600 else { return }
    log("Tắt máy bị chặn quá 3 phút, cho máy ngủ")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["sleepnow"]
    try? p.run()
}

// MARK: Tự cập nhật helper (khi người dùng chọn "Luôn cho phép" lúc cài)
// App ghi đường dẫn thư mục Resources chứa bản helper mới. Helper đọc file vào bộ nhớ, kiểm chữ ký Ed25519,
// khớp thì ghi đúng các byte đã kiểm sang chỗ của mình rồi thoát để launchd chạy bản mới.
// Cờ cho phép là file thuộc root, chỉ tạo được lúc cài bằng mật khẩu, nên tiến trình khác không tự bật được.
func checkHelperUpdate() {
    let fm = FileManager.default
    guard let flag = try? String(contentsOfFile: autoUpdateFlagPath, encoding: .utf8), flag.hasPrefix("1"),
          let owner = (try? fm.attributesOfItem(atPath: autoUpdateFlagPath))?[.ownerAccountID] as? NSNumber, owner.intValue == 0,
          let req = try? String(contentsOfFile: helperUpdateRequestPath, encoding: .utf8) else { return }
    let dir = req.trimmingCharacters(in: .whitespacesAndNewlines)
    guard dir.hasPrefix("/") else { return }
    try? "none\n".write(toFile: helperUpdateRequestPath, atomically: false, encoding: .utf8)
    guard let bin = fm.contents(atPath: dir + "/MacPulseFanHelper"),
          let sigText = fm.contents(atPath: dir + "/MacPulseFanHelper.sig").map({ String(decoding: $0, as: UTF8.self) }),
          let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let keyData = Data(base64Encoded: updatePublicKey),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
        log("Tự cập nhật helper: thiếu file hoặc chữ ký")
        return
    }
    guard key.isValidSignature(sig, for: bin) else {
        log("Tự cập nhật helper: chữ ký không khớp, bỏ qua")
        return
    }
    guard bin != fm.contents(atPath: selfPath) else { return }
    let tmp = selfPath + ".new"
    guard fm.createFile(atPath: tmp, contents: bin, attributes: [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0]),
          rename(tmp, selfPath) == 0 else {
        log("Tự cập nhật helper: ghi file lỗi")
        try? fm.removeItem(atPath: tmp)
        return
    }
    log("Tự cập nhật helper: đã thay bản mới (đã kiểm chữ ký), khởi động lại")
    if controlling { resetToAuto("cập nhật helper") }
    exit(0)   // launchd (KeepAlive) chạy lại ngay với bản mới
}

// MARK: Chế độ Thông minh
// Theo nghiên cứu cho MBP 14" M4 Pro (docs/nhiet-do-m4pro.md):
// - Nhiệt điều khiển = max(trung bình nhân CPU, trung bình GPU), làm mượt EMA τ ≈ 8 giây.
// - Điểm nóng nhất (trung vị 3 lần đọc, không làm mượt) chỉ dùng làm chốt an toàn; macOS báo căng nhiệt
//   từ mức "serious" thì quạt chạy hết cỡ.
// - Chỉ giành quyền khi đường cong đòi quạt nhanh hơn mức macOS đang chạy và kéo dài 3 giây,
//   nên không bao giờ làm quạt yếu hơn mặc định.
// - Tăng tối đa ~600 rpm/giây, giảm tối đa ~150 rpm/giây; nguội dưới ngưỡng đủ lâu thì trả quyền cho macOS.
// - Mất số đo nhiệt quá 5 giây thì trả quyền cho macOS.
let cpuSample = spread(cpuKeys, 16)
let gpuSample = spread(gpuKeys, 8)
let rangeRPM: Double = {
    let mn = smc.number("F0Mn") ?? 0, mx = smc.number("F0Mx") ?? 0
    return mx > mn ? mx - mn : 1
}()
let upPerSec = 600 / rangeRPM * 100      // % mỗi giây
let downPerSec = 150 / rangeRPM * 100

var smoothed: Double?
var lastGoodRead = Date()
var hotReads: [Double] = []
var smartPct = 0.0
var overSince: Date?
var belowSince: Date?

func smartStep(_ c: SmartConfig, tick: Int) {
    let now = Date()
    // Nhiệt điều khiển: đọc nhóm cảm biến đại diện mỗi 2 giây.
    if tick % 2 == 0 {
        if let tc = avg(cpuSample) {
            let t = max(tc, avg(gpuSample) ?? 0)
            let alpha = 1 - exp(-2.0 / 8.0)
            smoothed = smoothed.map { $0 + (t - $0) * alpha } ?? t
            lastGoodRead = now
        }
    }
    // Điểm nóng nhất: đọc hết cảm biến mỗi 5 giây (tốn công hơn), lấy trung vị 3 lần.
    if tick % 5 == 0 {
        hotReads = Array((hotReads + [hottest()]).suffix(3))
    }
    guard let t = smoothed, now.timeIntervalSince(lastGoodRead) <= 5 else {
        if controlling { resetToAuto("Thông minh: mất số đo nhiệt") }
        return
    }
    let tHot = hotReads.sorted()[safe: hotReads.count / 2] ?? 0
    let pressure = ProcessInfo.processInfo.thermalState.rawValue   // 2 = serious, 3 = critical
    var demand = t <= c.start ? 0 : min(100, (t - c.start) / (c.full - c.start) * 100)
    var safety: String?
    if pressure >= 2 {
        demand = 100
        safety = "macOS báo căng nhiệt"
    } else if tHot >= c.hot {
        demand = max(demand, c.hotPct)
        safety = "điểm nóng nhất \(Int(tHot))°C"
    }

    if !controlling {
        let wants = demand > currentPercent() + 5 && (t >= c.start || safety != nil)
        guard wants else { overSince = nil; return }
        overSince = overSince ?? now
        // Chờ 3 giây cho chắc không phải gai nhiệt thoáng qua (chốt an toàn thì vào ngay).
        guard safety != nil || now.timeIntervalSince(overSince!) >= 3 else { return }
        overSince = nil
        smartPct = currentPercent()
        logOnce("Thông minh: chip \(Int(t))°C\(safety.map { ", " + $0 } ?? ""), bắt đầu tăng quạt")
    }

    if safety == nil && t < c.start - c.hyst {
        belowSince = belowSince ?? now
        if now.timeIntervalSince(belowSince!) >= c.hold {
            belowSince = nil
            smartPct = 0
            resetToAuto("Thông minh: chip đã nguội còn \(Int(t))°C")
            return
        }
    } else {
        belowSince = nil
    }
    smartPct = demand > smartPct ? min(demand, smartPct + upPerSec) : max(demand, smartPct - downPerSec)
    applyPercent(smartPct, label: nil)
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: Vòng lặp chính

var tick = 0
var tickAll = 0
var hotHold = false
var lastKind = ""

let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: 1)
timer.setEventHandler {
    checkPowerRequest()
    if tickAll % 3 == 0 { checkHelperUpdate() }
    tickAll += 1
    let req = readRequest()
    let kind: String
    switch req {
    case .auto: kind = "auto"
    case .manual: kind = "manual"
    case .smart: kind = "smart"
    }
    if kind != lastKind {
        // Vừa đổi chế độ: Thông minh luôn bắt đầu từ trạng thái macOS điều khiển.
        if kind == "smart" && controlling { resetToAuto("chuyển sang Thông minh") }
        smoothed = nil
        belowSince = nil
        overSince = nil
        hotReads = []
        smartPct = 0
        tick = 0
        lastGoodRead = Date()
        lastKind = kind
    }
    switch req {
    case .auto:
        if controlling { resetToAuto("theo yêu cầu") }
        hotHold = false
        tick = 0   // lần bật kế tiếp đo nhiệt ngay
    case .manual(let pct):
        // Đọc hết cảm biến tốn công, nên chỉ kiểm tra nhiệt mỗi 5 giây.
        if tick % 5 == 0 {
            let t = hottest()
            if t >= hotOn { hotHold = true } else if t < hotOff { hotHold = false }
        }
        tick += 1
        applyPercent(hotHold ? max(pct, hotFloor) : pct, label: "Thủ công")
    case .smart(let c):
        smartStep(c, tick: tick)
        tick += 1
    }
}
timer.resume()
dispatchMain()
