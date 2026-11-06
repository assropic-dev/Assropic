import Foundation
import Darwin

@main
struct ProcessLivenessTests {
    static func main() throws {
        var assertions = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            assertions += 1
        }
        check(!ProcessLiveness.hasExited(getpid()), "the current process remains alive")
        check(!ProcessLiveness.hasExited(0), "PID zero is not treated as an exited process")
        check(!ProcessLiveness.hasExited(-1), "PID minus one never probes all processes")
        check(!ProcessLiveness.hasExited(pid_t.min), "other negative/group PIDs remain unknown")

        // Keep a real child alive with stdin, then let it exit normally at EOF.
        // No nonzero signal is needed by the probe or by this regression test.
        let input = Pipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/cat")
        child.standardInput = input
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        let pid = child.processIdentifier
        check(pid > 0 && !ProcessLiveness.hasExited(pid), "a running child must not be declared exited")
        try input.fileHandleForWriting.close()
        child.waitUntilExit()
        check(child.terminationStatus == 0, "the child exits normally after EOF")
        check(ProcessLiveness.hasExited(pid), "a reaped child's missing PID is recognized")
        check(!ProcessLiveness.hasExited(getpid()), "checking another PID does not affect the caller")
        print("PASS \(assertions) process liveness assertions; no termination signals sent")
    }
}
