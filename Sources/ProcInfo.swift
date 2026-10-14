// Đọc chi tiết một tiến trình qua libproc/sysctl: tham số lệnh, thư mục làm việc, giờ bắt đầu, file đang mở.
// Chỉ đọc được tiến trình của chính người dùng (đủ cho ffmpeg, claude, python…).
import Foundation
import Darwin

enum ProcInfo {
    struct OpenFile {
        let path: String
        let offset: Int64      // vị trí đang đọc/ghi
        let size: Int64
        let readable: Bool
        let writable: Bool
    }

    static func args(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }   // bỏ đường dẫn file chạy
        while i < size && buf[i] == 0 { i += 1 }
        var out: [String] = []
        while out.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            out.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return out
    }

    static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let r = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard r > 0 else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty ? nil : path
    }

    static func startTime(_ pid: pid_t) -> Date? {
        var bsd = proc_bsdinfo()
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard r > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000)
    }

    static func openFiles(_ pid: pid_t) -> [OpenFile] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var list = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &list, bytes)
        guard got > 0 else { return [] }
        var out: [OpenFile] = []
        for fd in list.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard r > 0 else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard !path.isEmpty else { continue }
            let flags = info.pfi.fi_openflags
            out.append(OpenFile(path: path, offset: info.pfi.fi_offset, size: info.pvip.vip_vi.vi_stat.vst_size,
                                readable: flags & UInt32(FREAD) != 0, writable: flags & UInt32(FWRITE) != 0))
        }
        return out
    }

    /// So khớp đường dẫn bất kể dạng Unicode (tên tiếng Việt có thể ở dạng NFC hoặc NFD).
    static func samePath(_ a: String, _ b: String) -> Bool {
        a.precomposedStringWithCanonicalMapping == b.precomposedStringWithCanonicalMapping
    }
}
