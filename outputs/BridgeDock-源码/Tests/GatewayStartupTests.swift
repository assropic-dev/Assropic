import Foundation
import Network

@main
struct GatewayStartupTests {
    static func main() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let occupied = try NWListener(using: parameters)
        occupied.newConnectionHandler = { $0.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            occupied.stateUpdateHandler = { state in
                switch state {
                case .ready: occupied.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): occupied.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            occupied.start(queue: DispatchQueue(label: "test.occupied-port"))
        }
        let port = Int(occupied.port!.rawValue)
        let gateway = ModelGateway()
        gateway.update(port: port, corePort: 1, clientKey: "test", coreKey: "test", catalog: [])
        do {
            try await gateway.start()
            preconditionFailure("an occupied port must fail")
        } catch {
            precondition(error.localizedDescription.contains("\(port)"))
            precondition(error.localizedDescription.contains("已被占用"))
        }
        precondition(occupied.state == .ready, "failed startup must leave the existing listener alive")
        occupied.cancel()
        // NWListener cancellation is asynchronous; retry the same failed gateway.
        var started = false
        for _ in 0..<30 {
            do { try await gateway.start(); started = true; break }
            catch { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        precondition(started, "gateway must recover after the port is released")
        gateway.stop()
        print("PASS occupied port message, existing listener preservation and startup retry")
    }
}
