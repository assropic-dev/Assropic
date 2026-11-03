"""Offline subscription-management integration checks against the bundled core.

Every credential is synthetic, disabled and dated far in the future. The core
runs with a macOS network sandbox permitting loopback only; a local rejecting
proxy also catches background version lookups. Browser-login sessions are
created and cancelled locally. No upstream OAuth, refresh, verification or
inference request succeeds, and no installed BridgeDock data is read.
"""

import json
import os
from pathlib import Path
import platform
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


FUTURE = "2099-01-01T00:00:00Z"
MANAGEMENT_KEY = "subscription-test-management-only"
CLIENT_KEY = "subscription-test-client-only"


class RejectingProxy(BaseHTTPRequestHandler):
    """Never forwards traffic, including the core's automatic version checks."""

    def log_message(self, *args):
        pass

    def reject(self):
        self.server.blocked_requests.append(self.path)
        self.send_response(502)
        self.send_header("Content-Length", "0")
        self.end_headers()

    do_CONNECT = reject
    do_GET = reject
    do_POST = reject


class SubscriptionChecks:
    def __init__(self, base_url):
        self.base_url = base_url
        self.direct = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.count = 0

    def check(self, condition, label):
        if not condition:
            raise AssertionError(label)
        self.count += 1
        print("PASS " + label, flush=True)

    def request(self, path, method="GET", body=None, key=MANAGEMENT_KEY):
        request = urllib.request.Request(
            self.base_url + path,
            data=None if body is None else json.dumps(body).encode(),
            headers={"Authorization": "Bearer " + key,
                     "Content-Type": "application/json"},
            method=method,
        )
        try:
            response = self.direct.open(request, timeout=8)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            raw = response.read()
            return response.code, json.loads(raw) if raw else None

    def files(self):
        code, response = self.request("/v8/management/credentials")
        if code != 200:
            raise AssertionError("credential list unavailable")
        return {item["name"]: item for item in response["files"]
                if item.get("provider") not in ("api-key", "apikey")}

    def imported(self, name, credential):
        code, response = self.request(
            "/v8/management/credentials?" + urllib.parse.urlencode({"name": name}),
            method="POST", body=credential,
        )
        self.check(code == 200 and response.get("status") == "ok",
                   "v8 imports " + name)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if name in self.files():
                return
            time.sleep(0.05)
        raise AssertionError("imported credential did not become visible: " + name)

    def run(self, plugin_ids, zcode_available):
        code, response = self.request("/v8/management/plugins")
        self.check(code == 200, "plugin management is reachable")
        plugins = {item["id"]: item for item in response["plugins"]}
        for plugin_id in plugin_ids:
            plugin = plugins.get(plugin_id, {})
            self.check(plugin.get("registered") is True
                       and plugin.get("effective_enabled") is True
                       and not plugin.get("load_error"),
                       plugin_id + " is loaded and enabled")
        if zcode_available:
            self.check(set(plugins["omc-zcode-oauth"]["oauth_providers"])
                       == {"zcode-zai", "zcode-bigmodel"},
                       "ZCode exposes separate Z.ai and BigModel login entries")

        code, response = self.request("/v8/management/credentials", key=CLIENT_KEY)
        self.check(code in (401, 403), "client key cannot manage subscriptions")

        login_states = []
        for _ in range(2):
            code, response = self.request("/v8/management/oauth/auth-url", "POST", {
                "provider": "cursor-agent-v1", "is_webui": True,
            })
            self.check(code == 200 and isinstance(response, dict),
                       "Cursor plugin creates a browser-login session")
            login_url = urllib.parse.urlparse(response["url"])
            query = urllib.parse.parse_qs(login_url.query)
            self.check(login_url.netloc == "cursor.com"
                       and login_url.path == "/loginDeepControl"
                       and query.get("redirectTarget") == ["sand"]
                       and query.get("mode") == ["login"],
                       "Grok Bot receives the project's deep-login page and target")
            self.check(len(query.get("challenge", [""])[0]) == 43
                       and query.get("uuid") == [response["state"]]
                       and "verifier" not in json.dumps(response),
                       "Browser receives a proof-key challenge without the private verifier")
            login_states.append(response["state"])
            code, _ = self.request("/v8/management/oauth/session?"
                                   + urllib.parse.urlencode({"state": response["state"]}), "DELETE")
            self.check(code == 200, "Browser-login session can be cancelled")
        self.check(login_states[0] != login_states[1],
                   "Every browser-login attempt has a fresh independent session")

        first_name, second_name = "codex-one.json", "codex-two.json"
        for name, account_id in ((first_name, "fixture-one"),
                                 (second_name, "fixture-two")):
            self.imported(name, {
                "type": "codex", "email": "same@example.invalid",
                "account_id": account_id, "access_token": "synthetic-" + account_id,
                "refresh_token": "synthetic-refresh-" + account_id,
                "disabled": True, "expired": FUTURE, "last_refresh": FUTURE,
            })
        files = self.files()
        first, second = files[first_name], files[second_name]
        self.check(first["email"] == second["email"] == "same@example.invalid",
                   "two accounts sharing an email coexist")
        self.check(first["auth_index"] != second["auth_index"]
                   and first["auth_index"] and second["auth_index"],
                   "coexisting accounts have distinct stable identities")
        self.check(first["disabled"] and second["disabled"],
                   "imported synthetic accounts remain disabled")

        fields = {"prefix": "fixture-one", "proxy_url": self.base_url,
                  "priority": 7, "note": "独立账号备注"}
        code, response = self.request("/v8/management/credentials/fields", "PATCH",
                                      dict(fields, name=first_name))
        self.check(code == 200 and response.get("status") == "ok",
                   "per-account fields can be updated")
        code, downloaded = self.request(
            "/v8/management/credentials/download?name=" + first_name)
        self.check(code == 200, "v8 downloads the selected credential")
        for field, value in fields.items():
            self.check(downloaded.get(field) == value,
                       field + " survives download roundtrip")
        self.check(downloaded["disabled"] is True,
                   "editing account fields does not enable an account")
        code, untouched = self.request(
            "/v8/management/credentials/download?name=" + second_name)
        self.check(code == 200 and untouched.get("account_id") == "fixture-two"
                   and not untouched.get("prefix") and not untouched.get("note"),
                   "editing and downloading one account leaves its neighbor intact")

        # Verify both matching and stale identity paths without ever enabling
        # a fake account, which would allow the core's refresh scheduler to run.
        code, response = self.request("/v8/management/credentials/status", "PATCH", {
            "name": first_name, "auth_index": second["auth_index"], "disabled": True,
        })
        self.check(code == 404, "status changes reject another account's auth_index")
        code, response = self.request("/v8/management/credentials/status", "PATCH", {
            "name": first_name, "auth_index": first["auth_index"], "disabled": True,
        })
        self.check(code == 200 and response.get("disabled") is True,
                   "status changes accept the matching auth_index")
        self.check(self.files()[second_name]["disabled"] is True,
                   "targeted status updates leave the other account disabled")

        code, response = self.request("/v8/management/credentials/models?name=" + first_name)
        self.check(code == 200 and isinstance(response.get("models"), list),
                   "per-account models endpoint returns a list while disabled")
        code, response = self.request("/v1/models", key=CLIENT_KEY)
        self.check(code == 200 and any(model["id"] == "fixture/static-model"
                                     for model in response.get("data", [])),
                   "client model catalogue exposes the configured prefixed model")

        self.imported("cursor-fixture.json", {
            "type": "cursor-agent-v1", "api_key": "key_synthetic_never_used",
            "email": "cursor@example.invalid", "runtime_profile": "agent_v1",
            "prefix": "cursor-fixture",
            "disabled": True, "expired": FUTURE, "last_refresh": FUTURE,
        })
        cursor = self.files()["cursor-fixture.json"]
        self.check(cursor["provider"] == "cursor-agent-v1" and cursor["disabled"],
                   "Cursor key import is recognized as a disabled subscription")

        self.imported("grok-bot-fixture.json", {
            "type": "cursor-agent-v1", "api_key": "key_synthetic_never_used",
            "email": "cursor@example.invalid", "runtime_profile": "sand",
            "prefix": "grok-bot-fixture",
            "disabled": True, "expired": FUTURE, "last_refresh": FUTURE,
        })
        grok_bot = self.files()["grok-bot-fixture.json"]
        self.check(grok_bot["provider"] == "cursor-agent-v1" and grok_bot["disabled"]
                   and grok_bot["auth_index"] != cursor["auth_index"],
                   "Grok Bot uses the shared Cursor provider as a separate channel")
        catalogs = {}
        for name, profile, prefix in [("cursor-fixture.json", "agent_v1", "cursor-fixture"),
                                      ("grok-bot-fixture.json", "sand", "grok-bot-fixture")]:
            code, credential = self.request("/v8/management/credentials/download?name=" + name)
            self.check(code == 200 and credential.get("runtime_profile") == profile
                       and credential.get("prefix") == prefix,
                       name + " retains its own transport and routing prefix")
            # Disabled credentials have no registered models. Enable only these
            # synthetic fixtures while inspecting the catalog; the sandbox and
            # rejecting proxy prevent upstream access, and no inference is sent.
            try:
                code, response = self.request("/v8/management/credentials/status", "PATCH", {
                    "name": name, "disabled": False,
                })
                self.check(code == 200, name + " is enabled for offline catalog inspection")
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    code, response = self.request("/v8/management/credentials/models?name=" + name)
                    if code == 200 and response.get("models"):
                        break
                    time.sleep(0.05)
                self.check(code == 200 and bool(response.get("models")),
                           name + " exposes its own model catalog")
                catalogs[profile] = {model["id"].rsplit("/", 1)[-1] for model in response["models"]}
            finally:
                self.request("/v8/management/credentials/status", "PATCH", {
                    "name": name, "disabled": True,
                })
        self.check("grok-4.6" in catalogs["sand"] and "grok-4.6" not in catalogs["agent_v1"],
                   "Grok Bot selects the plugin's Grok-capable catalog without changing Cursor")

        if zcode_available:
            self.imported("zcode-fixture.json", {
                "type": "zcode", "site": "zai", "device": "synthetic-device",
                "key": "synthetic-coding-plan-key", "uid": "synthetic-user",
                "email": "zcode@example.invalid", "disabled": True,
                "expired": FUTURE, "last_refresh": FUTURE,
            })
            zcode = self.files()["zcode-fixture.json"]
            self.check(zcode["provider"] == "zcode" and zcode["disabled"],
                       "ZCode native credential import remains disabled")
            code, response = self.request("/v0/management/quota/providers")
            self.check(code == 200 and "zcode" in json.dumps(response),
                       "ZCode registers its normalized quota provider")
            code, response = self.request("/v0/management/quota/fetch", "POST", {
                "auth_index": zcode["auth_index"],
            })
            self.check(code == 200 and isinstance(response, dict)
                       and isinstance(response.get("subscription"), dict),
                       "ZCode normalized quota route returns subscription metadata")
            self.check(not response.get("groups") and not response.get("summary"),
                       "blocked ZCode upstream leaves quota unknown, not a zero balance")
            self.check(self.files()["zcode-fixture.json"]["disabled"] is True,
                       "fetching ZCode quota does not enable the synthetic account")

        code, response = self.request(
            "/v8/management/credentials?name=" + first_name, "DELETE")
        self.check(code == 200, "v8 deletes the selected credential")
        files = self.files()
        self.check(first_name not in files and second_name in files
                   and "cursor-fixture.json" in files,
                   "deleting one account preserves all other accounts")
        code, response = self.request(
            "/v8/management/credentials/download?name=" + first_name)
        self.check(code == 404, "removed account can no longer be downloaded")
        self.check(all(account["disabled"] for account in files.values()),
                   "all synthetic subscriptions are disabled after offline inspection")
        return self.count


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("This integration test needs macOS arm64 and the bundled core.")
    sandbox = Path("/usr/bin/sandbox-exec")
    if not sandbox.is_file():
        raise SystemExit("sandbox-exec is required to enforce the offline test.")
    source = Path(__file__).resolve().parents[1]
    zcode_available = int(platform.mac_ver()[0].split(".")[0]) >= 15
    plugin_ids = ["kiro", "cursor-agent2api"]
    if zcode_available:
        plugin_ids.append("omc-zcode-oauth")
    else:
        print("SKIP ZCode: its bundled library requires macOS 15 or later.")

    with tempfile.TemporaryDirectory(prefix="bridgedock-subscriptions-") as work:
        root = Path(work)
        plugin_dir = root / "plugins" / "darwin" / "arm64"
        plugin_dir.mkdir(parents=True)
        (root / "accounts").mkdir()
        for plugin_id in plugin_ids:
            shutil.copyfile(source / "Vendor" / (plugin_id + ".dylib"),
                            plugin_dir / (plugin_id + ".dylib"))
        rejector = ThreadingHTTPServer(("127.0.0.1", 0), RejectingProxy)
        rejector.blocked_requests = []
        rejector.daemon_threads = True
        threading.Thread(target=rejector.serve_forever, daemon=True).start()
        proxy = "http://127.0.0.1:" + str(rejector.server_address[1])
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        base_url = "http://127.0.0.1:" + str(port)
        plugin_configs = {plugin_id: {"enabled": True} for plugin_id in plugin_ids}
        plugin_configs["cursor-agent2api"]["state_dir"] = str(root / "cursor-state")
        if zcode_available:
            plugin_configs["omc-zcode-oauth"]["mode"] = "own"
        config = {
            "config-version": 8,
            "server": {"host": "127.0.0.1", "port": port},
            "management": {"secret-key": MANAGEMENT_KEY, "allow-remote": False,
                           "disable-control-panel": True, "disable-auto-update-panel": True},
            "access": {"api-keys": [CLIENT_KEY]},
            "api-keys": {"openai-compatibility": [{
                "name": "Offline model catalogue", "prefix": "fixture",
                "base-url": proxy + "/v1", "keys": [{"api-key": "catalogue-only"}],
                "models": [{"name": "unused-upstream-model", "alias": "static-model"}],
            }]},
            "oauth": {"auth-dir": str(root / "accounts")},
            "routing": {"strategy": "round-robin", "force-model-prefix": True},
            "requests": {"proxy-url": proxy},
            "plugins": {"enabled": True, "dir": str(root / "plugins"),
                        "configs": plugin_configs},
        }
        (root / "config.json").write_text(json.dumps(config))
        # Deny direct outbound access even if an upstream component ignores
        # HTTP_PROXY. Loopback is needed by the core and the rejecting proxy.
        profile = root / "offline.sb"
        profile.write_text('(version 1)\n(allow default)\n(deny network*)\n'
                           '(allow network-bind (local ip "localhost:*"))\n'
                           '(allow network-inbound (local ip "localhost:*"))\n'
                           '(allow network-outbound (remote ip "localhost:*"))\n')
        environment = os.environ.copy()
        environment.update({"HTTP_PROXY": proxy, "HTTPS_PROXY": proxy,
                            "ALL_PROXY": proxy, "http_proxy": proxy, "https_proxy": proxy,
                            "all_proxy": proxy, "NO_PROXY": "127.0.0.1,localhost",
                            "no_proxy": "127.0.0.1,localhost"})
        log_path = root / "core.log"
        core = None
        try:
            with log_path.open("w") as log:
                core = subprocess.Popen([
                    str(sandbox), "-f", str(profile), str(source / "Vendor" / "cli-proxy-api"),
                    "-config", str(root / "config.json"), "-local-model",
                ], cwd=root, env=environment, stdout=log, stderr=log)
                checks = SubscriptionChecks(base_url)
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    if core.poll() is not None:
                        raise AssertionError("isolated core exited before readiness")
                    try:
                        if checks.request("/v8/management/config")[0] == 200:
                            break
                    except (OSError, urllib.error.URLError):
                        pass
                    time.sleep(0.1)
                else:
                    raise AssertionError("isolated core did not start")
                count = checks.run(plugin_ids, zcode_available)
                print("PASS {} subscription integration assertions; no real credentials or model calls."
                      .format(count), flush=True)
        except Exception:
            print(log_path.read_text()[-6000:], flush=True)
            raise
        finally:
            if core is not None and core.poll() is None:
                core.terminate()
                try:
                    core.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    core.kill()
                    core.wait(timeout=5)
            rejector.shutdown()
            rejector.server_close()


if __name__ == "__main__":
    main()
