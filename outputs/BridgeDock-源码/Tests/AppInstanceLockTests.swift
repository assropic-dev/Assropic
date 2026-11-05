import Foundation
import Darwin

/// Process fixture for app_instance_lock_test.py; never reads real app data.
@main
struct AppInstanceLockTests {
    static func main() throws {
        let mode = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        let lock = AppInstanceLock(directory: directory)
        let acquired = try lock.acquire()
        print(acquired ? "OWNER \(getpid())" : "OCCUPIED \(lock.ownerPID ?? 0)")
        fflush(stdout)
        guard acquired else { return }
        if mode == "exec" {
            let args = [strdup("sleep"), strdup("10"), nil]
            args.withUnsafeBufferPointer { buffer in
                _ = execv("/bin/sleep", buffer.baseAddress!)
            }
            fatalError("exec failed")
        }
        if mode == "hold" { _ = readLine() }
        withExtendedLifetime(lock) {}
    }
}
