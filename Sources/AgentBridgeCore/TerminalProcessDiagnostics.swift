import Darwin
import Foundation
import os

/// Diagnostics for terminal processes that outlive what the app expects, written
/// to the unified log. Read them with:
///
///     log show --last 1h --predicate 'subsystem BEGINSWITH "org.agentbridge"'
///
/// Entries carry process IDs, process group IDs, exit statuses and executable
/// names (at most 16 characters, from the kernel), never arguments, paths,
/// environment, titles or terminal text.
public enum TerminalProcessDiagnostics {
    public static let appSubsystem = "org.agentbridge.app"
    public static let helperSubsystem = "org.agentbridge.cli"

    public static func logger(subsystem: String, category: String = "terminal") -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    /// One process as the kernel reports it.
    public struct Entry: Equatable, Sendable {
        public let pid: pid_t
        public let parentPID: pid_t
        public let processGroupID: pid_t
        /// The foreground process group of the process's controlling terminal.
        public let terminalForegroundGroupID: pid_t
        public let terminalDevice: dev_t
        public let name: String

        public var summary: String {
            "\(pid)(ppid \(parentPID), pgid \(processGroupID), fg \(terminalForegroundGroupID), \(name))"
        }
    }

    /// Every process the kernel lists, or nil when the list cannot be read, so a
    /// failed read is never mistaken for "no process left".
    public static func allProcesses() -> [Entry]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var processes: [kinfo_proc] = []
        var size = 0
        var listed = false
        // Processes can start between sizing the list and reading it; a list that
        // grew past the room left gives ENOMEM, so size it again with more room.
        for _ in 0..<4 {
            size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
            size += size / 4
            processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
            if sysctl(&mib, u_int(mib.count), &processes, &size, nil, 0) == 0 { listed = true; break }
            guard errno == ENOMEM else { return nil }
        }
        guard listed else { return nil }
        let count = size / MemoryLayout<kinfo_proc>.stride
        return processes.prefix(count).map { info in
            var command = info.kp_proc.p_comm
            let name = withUnsafeBytes(of: &command) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            return Entry(
                pid: info.kp_proc.p_pid,
                parentPID: info.kp_eproc.e_ppid,
                processGroupID: info.kp_eproc.e_pgid,
                terminalForegroundGroupID: info.kp_eproc.e_tpgid,
                terminalDevice: info.kp_eproc.e_tdev,
                name: name
            )
        }
    }

    /// The processes whose controlling terminal is `device`, plus the descendants
    /// of `rootPID`. A process that left the launch's process group, or its
    /// session, still shows up through one of the two.
    public static func related(
        toTerminal device: dev_t?,
        rootPID: pid_t?,
        in processes: [Entry]
    ) -> [Entry] {
        var selected = Set<pid_t>()
        if let device, device != 0, device != ~dev_t(0) {
            for entry in processes where entry.terminalDevice == device { selected.insert(entry.pid) }
        }
        if let rootPID, rootPID > 0 {
            // Walked apart from `selected`, so a descendant already found on the
            // terminal still has its own children followed.
            let children = Dictionary(grouping: processes, by: \.parentPID)
            var visited: Set<pid_t> = [rootPID]
            var frontier: [pid_t] = [rootPID]
            while let parent = frontier.popLast() {
                for entry in children[parent] ?? [] where !visited.contains(entry.pid) {
                    visited.insert(entry.pid)
                    frontier.append(entry.pid)
                }
            }
            selected.formUnion(visited)
        }
        return processes.filter { selected.contains($0.pid) }.sorted { $0.pid < $1.pid }
    }

    public static func describe(_ entries: [Entry]) -> String {
        entries.isEmpty ? "none" : entries.map(\.summary).joined(separator: "; ")
    }

    /// `describe` of the processes `related` finds right now, or "unavailable"
    /// when the kernel's list cannot be read.
    public static func describeRelated(toTerminal device: dev_t?, rootPID: pid_t?, excluding excluded: Set<pid_t> = []) -> String {
        guard let processes = allProcesses() else { return "unavailable" }
        return describe(related(toTerminal: device, rootPID: rootPID, in: processes).filter { !excluded.contains($0.pid) })
    }

    /// The device of the terminal that `descriptor` refers to, if it is one.
    public static func terminalDevice(of descriptor: Int32) -> dev_t? {
        guard descriptor >= 0 else { return nil }
        var information = stat()
        guard fstat(descriptor, &information) == 0 else { return nil }
        return information.st_rdev
    }

    /// The device of the terminal whose controlling side is `masterDescriptor`;
    /// processes list that terminal, not the master, as theirs.
    public static func terminalDevice(ofPseudoTerminalMaster masterDescriptor: Int32) -> dev_t? {
        guard masterDescriptor >= 0 else { return nil }
        // ptsname_r, not ptsname, whose static buffer other threads can overwrite.
        var name = [CChar](repeating: 0, count: 128)
        guard ptsname_r(masterDescriptor, &name, name.count) == 0 else { return nil }
        var information = stat()
        guard stat(name, &information) == 0 else { return nil }
        return information.st_rdev
    }
}
