import Darwin

enum ProcessLiveness {
    /// Signal 0 only probes existence/permission; it never terminates a process.
    /// Treat permission errors and invalid/group PIDs as unknown, not exited.
    static func hasExited(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return Darwin.kill(pid, 0) == -1 && errno == ESRCH
    }
}
