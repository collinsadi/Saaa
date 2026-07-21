import Darwin
import Foundation

/// Minimal process-ancestry queries (sysctl), used to attribute helper
/// processes (browser renderers, conferencing audio services) to the app the
/// user actually picked.
enum ProcessTree {

    /// Parent PID, or `nil` if the process is gone.
    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let status = sysctl(&mib, 4, &info, &size, nil, 0)
        guard status == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Whether `pid` has `ancestor` in its parent chain (or is the ancestor).
    static func isDescendant(_ pid: pid_t, of ancestor: pid_t) -> Bool {
        var current = pid
        for _ in 0..<64 { // cycle guard; real chains are far shorter
            if current == ancestor { return true }
            guard current > 1, let parent = parentPID(of: current) else { return false }
            current = parent
        }
        return false
    }

    /// The process's BSD short name (e.g. "Google Chrome Helper").
    static func name(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = buffer.withUnsafeMutableBytes {
            proc_name(pid, $0.baseAddress, UInt32($0.count))
        }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }
}
