import Foundation
import Darwin

/// All copies using one data directory share a kernel-owned lock. Keep the file
/// in place: unlinking it would let a new process lock a different inode.
final class AppInstanceLock {
    static var dataDirectory: URL {
        let override = ProcessInfo.processInfo.environment["BRIDGEDOCK_DATA_DIR"]
        return override.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BridgeDock")
    }

    private let directory: URL
    private let file: URL
    private var descriptor: Int32 = -1

    init(directory: URL = AppInstanceLock.dataDirectory) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        file = self.directory.appendingPathComponent("app-instance.lock")
    }

    var ownerPID: pid_t? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        return pid
    }

    func acquire() throws -> Bool {
        if descriptor >= 0 { return true }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Child runtimes must not inherit ownership when the app exits/crashes.
        let fd = Darwin.open(file.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return false }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("\(getpid())\n".utf8))
            descriptor = fd
            return true
        } catch {
            close(fd)
            throw error
        }
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }
}
