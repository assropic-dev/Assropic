import Foundation

/// Runs only against the loopback fixture server started by the test driver.
/// Never starts BridgeDock's core or loads a user's existing data directory.
@main
struct ClaudeOAuthFlowTests {
    static var assertions = 0

    static func check(_ condition: Bool, _ label: String) {
        guard condition else { fatalError(label) }
        assertions += 1
    }

    static func stats(port: Int) async throws -> [String: Any] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "http://127.0.0.1:\(port)/test/stats")!
        let (data, response) = try await session.data(from: url)
        check((response as? HTTPURLResponse)?.statusCode == 200, "Fixture stats endpoint is available")
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @MainActor
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BRIDGEDOCK_OAUTH_TEST_MODE"] == "loopback-fixtures-only",
              let root = environment["BRIDGEDOCK_DATA_DIR"],
              URL(fileURLWithPath: root).lastPathComponent.hasPrefix("bridgedock-oauth-flow-"),
              !FileManager.default.fileExists(atPath: root + "/state.json"),
              let portText = environment["BRIDGEDOCK_TEST_CORE_PORT"],
              let port = Int(portText), (1026...65533).contains(port), port != 18418 else {
            fatalError("Run using the isolated loopback OAuth fixture driver")
        }

        let store = BridgeStore()
        check(store.error == nil, "BridgeStore initializes an isolated fixture data directory")
        check(store.dataDirectory.path == root, "The real BridgeDock data directory is not loaded")
        store.settings.port = port - 2
        check(store.settings.corePort == port, "Requests target only the random fixture port")
        store.settings.managementKey = "fixture-management-key"
        let authorizationURL = "https://claude.ai/oauth/authorize?code=true&client_id=fixture-client&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback&code_challenge=fixture-challenge&code_challenge_method=S256&state=fixture-state"
        let login = LoginSession(provider: "claude", state: "fixture-state", url: authorizationURL,
                                 userCode: "", expiresAt: Date().addingTimeInterval(300), previousAccount: nil)
        store.login = login

        let invalidAccepted = await store.submitCallback(authorizationURL)
        check(!invalidAccepted, "Pasting the authorization page is rejected before submission")
        check(store.login?.id == login.id, "A rejected authorization page leaves the current login available")
        check(store.callbackSubmission == nil, "A rejected authorization page does not lock callback submission")
        check(store.error?.contains("授权") == true && store.error?.contains("回调") == true,
              "The user is told to copy the completed authorization result")
        check(store.error?.contains("fixture-challenge") == false && store.error?.contains("fixture-state") == false,
              "The error does not expose pasted authorization values")
        var observed = try await stats(port: port)
        check(observed["callback_posts"] as? Int == 0, "Invalid input causes no callback HTTP request")

        let accepted = await store.submitCallback("fixture-authorization-code#fixture-state")
        check(accepted, "The completed Claude code can be submitted after correcting the input")
        check(store.login?.id == login.id, "A submitted callback keeps the login until its result arrives")
        check(store.callbackSubmission == login.id, "A submitted callback locks further submission for this session")
        observed = try await stats(port: port)
        check(observed["callback_posts"] as? Int == 1, "The completed code causes exactly one callback POST")
        check(observed["codes"] as? [String] == ["fixture-authorization-code"], "Only the extracted code is sent")
        check(observed["states"] as? [String] == ["fixture-state"], "The current session state is sent")
        check(observed["providers"] as? [String] == ["claude"], "The callback uses the Claude provider")

        let duplicateAccepted = await store.submitCallback("fixture-authorization-code#fixture-state")
        check(!duplicateAccepted, "A repeated submission is rejected while the first result is pending")
        observed = try await stats(port: port)
        check(observed["callback_posts"] as? Int == 1, "A repeated submission causes no second callback request")

        await store.cancelLogin()
        check(store.login == nil && store.callbackSubmission == nil, "Cancellation clears login and callback submission state")
        check(store.loginStatus.isEmpty, "Cancellation clears the pending result message")
        observed = try await stats(port: port)
        check(observed["session_deletes"] as? Int == 1, "Cancellation closes only the fixture login session")
        print("PASS \(assertions) isolated Claude OAuth submission assertions")
    }
}
