"""Exercise Claude, ChatGPT/Codex and Kiro routing with synthetic credentials.

Uses the existing macOS sandbox harness: external network access is denied,
and every provider connection terminates at a rejecting loopback proxy. This
checks account adoption, model registration and the selected provider endpoint,
not actual upstream authentication or entitlement. No user data is read.
"""

import urllib.parse

import subscription_proxy_test as harness


class RecordingProxy(harness.RejectingProxy):
    attempts = []

    def reject(self):
        self.attempts.append((self.command, self.path))
        super().reject()

    do_CONNECT = reject
    do_GET = reject
    do_POST = reject


class SubscriptionRoutingChecks(harness.SubscriptionChecks):
    def run(self, plugin_ids, zcode_available):
        self.check("kiro" in plugin_ids, "isolated core includes the Kiro plugin")
        cases = [
            ("claude", "claude", "claude-sonnet-4-6", "/v1/messages", "api.anthropic.com:443"),
            ("gpt", "codex", "gpt-6.1-sol", "/v1/responses", "chatgpt.com:443"),
            ("kiro", "kiro", "claude-sonnet-4-6", "/v1/messages", "q.us-east-1.amazonaws.com:443"),
        ]
        for prefix, provider, model, endpoint, upstream in cases:
            credential = {
                "type": provider,
                "email": provider + "@example.invalid",
                "access_token": "synthetic-access-" + provider,
                "refresh_token": "synthetic-refresh-" + provider,
                "expired": harness.FUTURE,
                "last_refresh": harness.FUTURE,
                "prefix": prefix,
            }
            if provider == "codex":
                credential["account_id"] = "synthetic-chatgpt-account"
            elif provider == "kiro":
                credential.update({
                    "accessToken": credential["access_token"],
                    "refreshToken": credential["refresh_token"],
                    "expiresAt": harness.FUTURE,
                    "region": "us-east-1", "authMethod": "social", "provider": "Github",
                })
            name = provider + "-routing.json"
            self.imported(name, credential)
            account = self.files()[name]
            self.check(account.get("provider") == provider and account.get("adopted") is True,
                       provider + " native credential is adopted by its own provider")
            self.check(account.get("status") == "active" and not account.get("requires_sign_in"),
                       provider + " future-dated fixture does not trigger token renewal")
            self.check(account.get("inference_verified") is False,
                       provider + " loaded credential is not claimed to be verified")

            selected_model = prefix + "/" + model
            code, response = self.request(
                "/v8/management/credentials/models?" + urllib.parse.urlencode({"name": name}))
            self.check(code == 200 and selected_model in {item["id"] for item in response["models"]},
                       provider + " exposes its prefixed model on the account endpoint")
            code, response = self.request("/v1/models", key=harness.CLIENT_KEY)
            self.check(code == 200 and selected_model in {item["id"] for item in response["data"]},
                       provider + " prefixed model is discoverable by a local API client")

        # Verify coexistence before deliberately failing requests: the core can
        # hide a model while it is cooling down after an upstream error.
        code, response = self.request("/v1/models", key=harness.CLIENT_KEY)
        models = {item["id"] for item in response["data"]}
        self.check({"claude/claude-sonnet-4-6", "kiro/claude-sonnet-4-6"}.issubset(models),
                   "same-named Claude and Kiro models remain independently selectable")

        for prefix, provider, model, endpoint, upstream in cases:
            selected_model = prefix + "/" + model
            if provider == "codex":
                body = {"model": selected_model, "input": "offline fixture", "stream": False,
                        "max_output_tokens": 2}
            else:
                body = {"model": selected_model, "max_tokens": 2, "stream": False,
                        "messages": [{"role": "user", "content": "offline fixture"}]}
            before = len(RecordingProxy.attempts)
            code, _ = self.request(endpoint, "POST", body=body, key="incorrect-client-key")
            self.check(code == 401 and len(RecordingProxy.attempts) == before,
                       provider + " model cannot be called without the local client key")

            code, _ = self.request(endpoint, "POST", body=body, key=harness.CLIENT_KEY)
            self.check(code >= 500,
                       provider + " request fails at the intentionally rejecting local proxy")
            attempts = RecordingProxy.attempts[before:]
            self.check(("CONNECT", upstream) in attempts,
                       provider + " selected model routes to the expected provider endpoint")
            self.check(not any(method == "CONNECT" and host != upstream for method, host in attempts),
                       provider + " does not fall through to a different subscription provider")

        code, _ = self.request("/v1/messages", "POST", {
            "model": "claude-sonnet-4-6", "max_tokens": 2,
            "messages": [{"role": "user", "content": "offline fixture"}],
        }, key=harness.CLIENT_KEY)
        self.check(code >= 400,
                   "force-model-prefix rejects an ambiguous unprefixed subscription model")
        print("PASS {} offline subscription routing assertions; no request reached an upstream."
              .format(self.count), flush=True)
        return self.count


def main():
    # Reuse the exact sandbox/process cleanup harness; only the scenario and
    # local proxy recorder differ. These assignments exist in this test process.
    harness.RejectingProxy = RecordingProxy
    harness.SubscriptionChecks = SubscriptionRoutingChecks
    harness.main()


if __name__ == "__main__":
    main()
