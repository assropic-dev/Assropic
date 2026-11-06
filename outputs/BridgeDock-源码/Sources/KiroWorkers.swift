import Foundation

/// Stable slot numbers for Kiro accounts. A slot fixes an account's worker folder and port, so an
/// account keeps its usage history and its port across restarts; a removed account's slot is not
/// reused while its file name is remembered.
enum KiroWorkerSlots {
    static let basePort = 18430

    static func port(_ slot: Int) -> Int { basePort + slot }

    /// Assigns the next unused slot (from 1) to each name that has none; returns true when `slots` changed.
    @discardableResult
    static func assign(_ names: [String], to slots: inout [String: Int]) -> Bool {
        var used = Set(slots.values)
        var changed = false
        for name in names.sorted() where slots[name] == nil {
            var slot = 1
            while used.contains(slot) { slot += 1 }
            slots[name] = slot
            used.insert(slot)
            changed = true
        }
        return changed
    }
}

/// Appends routing decisions to `router.log` and keeps `router-state.json` current, so
/// "which conversation runs on which account, and why it moved" can always be read from disk.
final class KiroRouterJournal: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.bridgedock.kiro-router-journal", qos: .utility)
    private let log: URL
    private let state: URL
    private static let maximumLogBytes = 2 * 1024 * 1024

    init(directory: URL) {
        log = directory.appendingPathComponent("router.log")
        state = directory.appendingPathComponent("router-state.json")
    }

    /// Touched only on `queue`.
    private var statePending = false

    /// Rewrites router-state.json about a second after a change, coalescing bursts of requests.
    func scheduleState(_ snapshot: @escaping () -> KiroSessionRouter.Snapshot?) {
        queue.async { [self] in
            guard !statePending else { return }
            statePending = true
            queue.asyncAfter(deadline: .now() + 1) { [self] in
                statePending = false
                guard let value = snapshot() else { return }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? encoder.encode(value) { try? data.write(to: state, options: .atomic) }
            }
        }
    }

    func record(_ line: String, snapshot: KiroSessionRouter.Snapshot?) {
        let stamp = KiroRuntimeCredentials.timestamp()
        queue.async { [log, state] in
            try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            let size = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0
            if size > Self.maximumLogBytes { try? FileManager.default.removeItem(at: log) }
            let entry = Data("\(stamp) \(line)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: log) {
                handle.seekToEndOfFile(); handle.write(entry); try? handle.close()
            } else {
                try? entry.write(to: log)
            }
            if let snapshot {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? encoder.encode(snapshot) { try? data.write(to: state, options: .atomic) }
            }
        }
    }
}

/// One kiro2cc process per enabled Kiro account. Each worker has its own folder
/// (`kiro-runtime/workers/<slot>`), port, credentials file, HOME, log, token refresh and restart
/// backoff, so two accounts behave like two separate machines and never share a process. The
/// gateway's `KiroSessionRouter` decides which worker serves which conversation.
@MainActor
final class KiroWorkerPool {
    let directory: URL
    let accountsDirectory: URL
    private var workers: [String: KiroRuntime] = [:]
    private var details: [String: (slot: Int, prefix: String, pooled: Bool)] = [:]
    private var slots: [String: Int] = [:]
    private var slotsLoaded = false
    private var legacyStopped = false
    private var synchronizing = false
    private var resyncRequested = false
    private var desiredProxyURL: String?
    private let fileQueue = DispatchQueue(label: "local.bridgedock.kiro-workers.files", qos: .utility)
    /// The route the gateway should use now; nil while no worker is ready.
    var onRouteChange: ((KiroGatewayRoute?) -> Void)?
    private(set) var ready = false

    init(dataDirectory: URL) {
        directory = dataDirectory.appendingPathComponent("kiro-runtime")
        accountsDirectory = dataDirectory.appendingPathComponent("accounts")
    }

    /// The ports in use, slot by slot; for diagnostics.
    var ports: [String: Int] { workers.mapValues(\.port) }

    func synchronize(proxyURL: String) async {
        guard FileManager.default.isExecutableFile(atPath: KiroRuntime.executableURL.path) else { return }
        desiredProxyURL = proxyURL
        guard !synchronizing else { resyncRequested = true; return }
        synchronizing = true
        defer { synchronizing = false }
        repeat {
            resyncRequested = false
            await synchronizeOnce(proxyURL: desiredProxyURL ?? proxyURL)
        } while resyncRequested && desiredProxyURL != nil
    }

    func stop() {
        desiredProxyURL = nil
        for worker in workers.values { worker.stop() }
        workers = [:]
        details = [:]
        publish()
    }

    private func synchronizeOnce(proxyURL: String) async {
        if !legacyStopped {
            // Earlier BridgeDock versions ran every account in one kiro2cc from kiro-runtime/ itself.
            legacyStopped = true
            let legacy = directory, executable = KiroRuntime.executableURL
            await onFiles { KiroRuntime.stopOrphan(directory: legacy, executable: executable) }
        }
        let accountsDirectory = accountsDirectory
        let accounts = await onFiles { KiroRuntime.readKiroAccounts(accountsDirectory) }
        let enabled = accounts.filter { account in
            !(account.value["disabled"] as? Bool ?? false)
                && (KiroRuntimeCredentials.string(account.value["refreshToken"]) ?? KiroRuntimeCredentials.string(account.value["refresh_token"])) != nil
        }
        if !slotsLoaded { slots = await onFiles { [directory] in Self.loadSlots(directory) }; slotsLoaded = true }
        if KiroWorkerSlots.assign(enabled.map(\.name), to: &slots) {
            let snapshot = slots, directory = directory
            await onFiles { Self.saveSlots(snapshot, directory) }
        }
        let wanted = Set(enabled.map(\.name))
        for (name, worker) in workers where !wanted.contains(name) {
            worker.stop()
            workers[name] = nil
            details[name] = nil
        }
        for account in enabled {
            guard let slot = slots[account.name] else { continue }
            details[account.name] = (slot, KiroRuntimeCredentials.string(account.value["prefix"]) ?? "",
                                     account.value["pool"] as? Bool != false)
            guard workers[account.name] == nil else { continue }
            let worker = KiroRuntime(directory: directory.appendingPathComponent("workers").appendingPathComponent(String(slot)),
                                     accountsDirectory: accountsDirectory, port: KiroWorkerSlots.port(slot), accountName: account.name)
            worker.onReadyChange = { [weak self] _ in self?.publish() }
            workers[account.name] = worker
        }
        publish()
        // Workers start one after another; each launch waits at most a few seconds for its process.
        for name in workers.keys.sorted() {
            guard desiredProxyURL != nil, let worker = workers[name] else { continue }
            await worker.synchronize(proxyURL: proxyURL)
        }
        publish()
    }

    private func publish() {
        let routes = workers.compactMap { name, worker -> KiroWorkerRoute? in
            guard worker.ready, let detail = details[name],
                  let key = worker.keys[detail.prefix] ?? worker.keys.values.first else { return nil }
            return KiroWorkerRoute(id: String(detail.slot), port: worker.port, key: key, prefix: detail.prefix, pooled: detail.pooled)
        }.sorted { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
        ready = !routes.isEmpty
        onRouteChange?(routes.isEmpty ? nil : KiroGatewayRoute(workers: routes))
    }

    private func onFiles<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in fileQueue.async { done.resume(returning: work()) } }
    }

    nonisolated static func loadSlots(_ directory: URL) -> [String: Int] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("workers.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.compactMapValues { ($0 as? NSNumber)?.intValue }.filter { $0.value > 0 }
    }

    nonisolated static func saveSlots(_ slots: [String: Int], _ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONSerialization.data(withJSONObject: slots, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("workers.json"), options: .atomic)
        }
    }
}
