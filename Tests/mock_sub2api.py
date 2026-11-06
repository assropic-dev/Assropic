#!/usr/bin/env python3
"""本地模拟的 Sub2API 中转站，用于端到端测试 BridgeDock 的“登录中转站”和模型核验。

只用标准库。用法：python3 -I Tests/mock_sub2api.py 18990
- /login 是一个登录页（密码框已预填测试密码 test-password，自动化测试只需点登录），登录后写入 localStorage 并跳到 /dashboard（与真实站点相同的键名）。
- /api/v1/... 实现 BD 用到的用户端接口：settings/public、auth/me、auth/refresh（轮换刷新令牌）、auth/logout、
  keys（列表 / 新建 / 删除）、groups/available、usage/dashboard/stats、usage（计费记录）。
- /v1/messages、/v1/responses、/v1/models 是模型接口。分组“Claude 官方”和“GPT 官方”按原生格式返回、
  带 thinking 签名和缓存；分组“Claude 伪装”返回 chat 格式、无签名、无缓存，用来验证核验能识别异常。
- GET /__state 返回内部状态（令牌轮换次数、Key 数、调用次数），供测试脚本断言。
"""
import base64, json, sys, threading, time, uuid, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 18990
# --auto-login：登录页加载后自动提交预填的测试账号，代替人工点“登录”（自动化测试用）。
AUTO_LOGIN = "--auto-login" in sys.argv
# --state PATH：把账号、令牌、Key 和计费记录存到文件，重启后保留。
STATE_FILE = sys.argv[sys.argv.index("--state") + 1] if "--state" in sys.argv else None
LOCK = threading.Lock()
TZ = datetime.timezone(datetime.timedelta(hours=8))

GROUPS = [
    {"id": 11, "name": "Claude 官方", "platform": "anthropic", "models": ["claude-opus-5-5", "claude-sonnet-5-5"], "rate_multiplier": 0.5, "status": "active", "description": "原生 Anthropic"},
    {"id": 12, "name": "GPT 官方", "platform": "openai", "models": ["gpt-6-sol"], "rate_multiplier": 0.14, "status": "active", "description": "原生 Responses"},
    {"id": 13, "name": "Claude 伪装", "platform": "anthropic", "models": ["claude-opus-5-5"], "rate_multiplier": 0.05, "status": "active", "description": "其实是别家模型"},
    {"id": 14, "name": "Gemini", "platform": "gemini", "models": ["gemini-3-pro"], "rate_multiplier": 1, "status": "active", "description": ""},
]

state = {
    "user": {"id": 1000028, "email": "tester@example.com", "username": "", "balance": 157.68, "frozen_balance": 0,
             "total_recharged": 2150, "concurrency": 2000, "status": "active", "role": "user"},
    "access": {},      # token -> expiry epoch
    "refresh": {},     # refresh token -> True (valid)
    "rotations": 0, "logins": 0, "logouts": 0,
    "keys": [], "next_key": 500, "calls": 0, "logs": [], "seen_prompts": set(),
}


def now_iso():
    return datetime.datetime.now(TZ).isoformat(timespec="microseconds")


def jwt(user_id):
    def b64(obj):
        return base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip("=")
    exp = int(time.time()) + 86400
    payload = {"user_id": user_id, "email": state["user"]["email"], "role": "user", "exp": exp, "iat": int(time.time()),
               "sid": uuid.uuid4().hex, "bnd": uuid.uuid4().hex}
    return b64({"alg": "HS256", "typ": "JWT"}) + "." + b64(payload) + "." + uuid.uuid4().hex, exp


def issue():
    token, exp = jwt(state["user"]["id"])
    refresh = "rt_" + uuid.uuid4().hex + uuid.uuid4().hex[:32]
    state["access"][token] = exp
    state["refresh"][refresh] = True
    return {"access_token": token, "refresh_token": refresh, "expires_in": 86400, "token_type": "Bearer"}


def add_key(name, group_id, quota=0):
    state["next_key"] += 1
    group = next(g for g in GROUPS if g["id"] == group_id)
    key = {"id": state["next_key"], "name": name, "key": "sk-mock" + uuid.uuid4().hex + uuid.uuid4().hex[:24], "status": "active",
           "group_id": group_id, "group": group, "quota": quota, "quota_used": 0, "expires_at": None,
           "created_at": now_iso(), "last_used_at": None, "user_id": state["user"]["id"]}
    state["keys"].append(key)
    return key


add_key("已有的 Key", 12)
state["keys"][-1]["key"] = "sk-mock-existing-gpt-key-0001"
add_key("masked", 11)
state["keys"][-1]["key"] = "sk-mock****masked"
PERSISTED = ("user", "access", "refresh", "rotations", "logins", "logouts", "keys", "next_key", "calls", "logs")


def load_state():
    if STATE_FILE:
        try:
            saved = json.load(open(STATE_FILE))
            for name in PERSISTED:
                if name in saved:
                    state[name] = saved[name]
            for key in state["keys"]:
                key["group"] = next(g for g in GROUPS if g["id"] == key["group_id"])
        except FileNotFoundError:
            pass


def save_state():
    if STATE_FILE:
        with open(STATE_FILE + ".tmp", "w") as f:
            json.dump({name: state[name] for name in PERSISTED}, f, ensure_ascii=False)
        import os
        os.replace(STATE_FILE + ".tmp", STATE_FILE)


load_state()

LOGIN_PAGE = """<!doctype html><html><head><meta charset=utf-8><title>登录 - Mock Sub2API</title></head>
<body style="font-family:-apple-system;padding:40px">
<h2>Mock Sub2API 登录</h2>
<form id=f><p><input id=email name=email placeholder=邮箱 value="tester@example.com"></p>
<p><input id=password name=password type=password placeholder=密码 value="test-password"></p>
<p><button id=submit type=submit>登录</button></p><p id=msg style="color:#b00"></p></form>
<script>
document.getElementById('f').onsubmit = async (e) => {
  e.preventDefault();
  const r = await fetch('/api/v1/auth/login', {method:'POST', headers:{'Content-Type':'application/json'},
    body: JSON.stringify({email: document.getElementById('email').value, password: document.getElementById('password').value})});
  const j = await r.json();
  if (j.code !== 0) { document.getElementById('msg').textContent = j.message; return; }
  const d = j.data;
  localStorage.setItem('auth_token', d.access_token);
  localStorage.setItem('refresh_token', d.refresh_token);
  localStorage.setItem('token_expires_at', String(Date.now() + d.expires_in * 1000));
  localStorage.setItem('auth_user', JSON.stringify(d.user));
  location.href = '/dashboard';
};
</script></body></html>"""

DASHBOARD = "<!doctype html><html><head><meta charset=utf-8><title>仪表盘</title></head><body><h2>已登录</h2></body></html>"


def tokens_of(text):
    """确定性的“分词器”：官方组按 4 字符一个 token；伪装组按 3 字符，模拟换了分词器。"""
    return max(1, (len(text) + 3) // 4)


def text_of(content):
    if isinstance(content, str):
        return content
    return "".join(part.get("text", "") for part in content if isinstance(part, dict))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("[mock] " + (fmt % args) + "\n")

    def send(self, status, body, content_type="application/json"):
        data = body if isinstance(body, bytes) else (body.encode() if isinstance(body, str) else json.dumps(body, ensure_ascii=False).encode())
        self.send_response(status)
        self.send_header("Content-Type", content_type + ("; charset=utf-8" if "html" in content_type or "json" in content_type else ""))
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def ok(self, data):
        self.send(200, {"code": 0, "message": "success", "data": data})

    def fail(self, status, message):
        self.send(status, {"code": status, "message": message})

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            return json.loads(raw or b"{}")
        except Exception:
            return {}

    def bearer(self):
        value = self.headers.get("Authorization", "")
        return value[7:] if value.startswith("Bearer ") else (self.headers.get("x-api-key") or "")

    def authed(self):
        token = self.bearer()
        exp = state["access"].get(token)
        return exp is not None and exp > time.time()

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_DELETE(self):
        self.route("DELETE")

    def route(self, method):
        url = urlparse(self.path)
        path, query = url.path, parse_qs(url.query)
        with LOCK:
            if path in ("/login", "/") and method == "GET":
                page = LOGIN_PAGE
                if AUTO_LOGIN:
                    page = page.replace("</body>", "<script>setTimeout(() => document.getElementById('submit').click(), 1500)</script></body>")
                return self.send(200, page, "text/html")
            if path == "/dashboard":
                return self.send(200, DASHBOARD, "text/html")
            if path == "/__state":
                return self.send(200, {"rotations": state["rotations"], "logins": state["logins"], "logouts": state["logouts"],
                                       "keys": [{k: v for k, v in key.items() if k != "group"} for key in state["keys"]],
                                       "calls": state["calls"], "logs": len(state["logs"]), "valid_refresh": len(state["refresh"])})
            if path == "/__expire":  # 让所有登录令牌立即过期，测试 BD 的强制刷新
                for token in state["access"]:
                    state["access"][token] = 0
                return self.send(200, {"ok": True})
            if path.startswith("/api/v1/"):
                try:
                    return self.api(method, path[len("/api/v1"):], query)
                finally:
                    save_state()
            if path.startswith("/v1/"):
                try:
                    return self.model(method, path)
                finally:
                    save_state()
            return self.send(404, {"error": "not found"})

    # --- 用户端接口 ---
    def api(self, method, path, query):
        if path == "/settings/public":
            return self.ok({"site_name": "Mock Relay", "version": "1.0.999", "api_base_url": "", "site_logo": "",
                            "turnstile_enabled": False, "linuxdo_oauth_enabled": False, "passkey_enabled": False,
                            "registration_email_suffix_whitelist": []})
        if path == "/auth/login" and method == "POST":
            body = self.body()
            if body.get("password") != "test-password":
                return self.fail(401, "邮箱或密码错误")
            state["logins"] += 1
            data = issue()
            data["user"] = state["user"]
            return self.ok(data)
        if path == "/auth/refresh" and method == "POST":
            token = self.body().get("refresh_token", "")
            if not state["refresh"].pop(token, None):
                return self.fail(401, "refresh token invalid")
            state["rotations"] += 1
            return self.ok(issue())
        if path == "/auth/logout" and method == "POST":
            state["refresh"].pop(self.body().get("refresh_token", ""), None)
            state["logouts"] += 1
            return self.ok({})
        if not self.authed():
            return self.fail(401, "unauthorized")
        if path == "/auth/me":
            return self.ok(state["user"])
        if path == "/groups/available":
            return self.ok(GROUPS)
        if path == "/usage/dashboard/stats":
            return self.ok({"today_actual_cost": 0.13, "total_actual_cost": 915.67, "today_requests": state["calls"]})
        if path == "/usage":
            key_id = int((query.get("api_key_id") or ["0"])[0])
            items = [log for log in reversed(state["logs"]) if not key_id or log["api_key_id"] == key_id]
            size = int((query.get("page_size") or ["20"])[0])
            return self.ok({"items": items[:size], "total": len(items), "page": 1, "page_size": size, "pages": 1})
        if path == "/keys" and method == "GET":
            page = int((query.get("page") or ["1"])[0]); size = int((query.get("page_size") or ["10"])[0])
            items = state["keys"][(page - 1) * size: page * size]
            pages = max(1, (len(state["keys"]) + size - 1) // size)
            return self.ok({"items": items, "total": len(state["keys"]), "page": page, "page_size": size, "pages": pages})
        if path == "/keys" and method == "POST":
            body = self.body()
            group_id = int(body.get("group_id") or 0)
            if not any(g["id"] == group_id for g in GROUPS):
                return self.fail(400, "group not found")
            return self.ok(add_key(body.get("name") or "unnamed", group_id, float(body.get("quota") or 0)))
        if path.startswith("/keys/") and method == "DELETE":
            key_id = int(path.split("/")[-1])
            state["keys"] = [k for k in state["keys"] if k["id"] != key_id]
            return self.ok({})
        return self.fail(404, "no route " + path)

    # --- 模型接口 ---
    def model(self, method, path):
        key = next((k for k in state["keys"] if k["key"] == self.bearer() and k["status"] == "active"), None)
        if not key:
            return self.send(401, {"error": {"type": "authentication_error", "message": "invalid api key"}})
        if path == "/v1/models":
            return self.send(200, {"object": "list", "data": [{"id": m, "object": "model"} for m in key["group"]["models"]]})
        body = self.body()
        model = body.get("model", "")
        if model not in key["group"]["models"]:
            return self.send(404, {"error": {"type": "not_found_error", "message": "model not found: " + model}})
        fake = key["group_id"] == 13
        state["calls"] += 1
        if path == "/v1/messages":
            blocks = [b for m in body.get("messages", []) for b in (m["content"] if isinstance(m["content"], list) else [{"type": "text", "text": m["content"]}])]
            prompt = "".join(b.get("text", "") for b in blocks)
            cacheable = "".join(b.get("text", "") for b in blocks if b.get("cache_control"))
            per = 3 if fake else 4
            total = max(1, (len(prompt) + per - 1) // per) + 8
            cached = 0
            if cacheable and not fake:
                cache_key = (key["id"], model, cacheable)
                cached = tokens_of(cacheable) if cache_key in state["seen_prompts"] else 0
                state["seen_prompts"].add(cache_key)
            question = blocks[-1].get("text", "") if blocks else ""
            answer = "391" if "17 * 23" in question else (question.split(": ")[-1] if ": " in question else "ok")
            out_tokens = tokens_of(answer)
            if fake:
                log = self.record(key, model, total, 0, out_tokens)
                return self.send(200, {"id": "chatcmpl-" + uuid.uuid4().hex[:10], "object": "chat.completion", "model": "deepseek-v4",
                                       "choices": [{"message": {"role": "assistant", "content": answer}}],
                                       "usage": {"prompt_tokens": total, "completion_tokens": out_tokens}})
            content = []
            thinking = body.get("thinking")
            if thinking and thinking.get("type") == "adaptive" and model == "claude-sonnet-5-5":
                return self.send(400, {"type": "error", "error": {"type": "invalid_request_error", "message": "adaptive thinking not supported"}})
            if thinking:
                content.append({"type": "thinking", "thinking": "17*23 = 391", "signature": base64.b64encode(uuid.uuid4().bytes * 12).decode()})
                out_tokens += 20
            content.append({"type": "text", "text": answer})
            uncached = total - cached
            self.record(key, model, uncached, cached, out_tokens)
            return self.send(200, {"id": "msg_" + uuid.uuid4().hex[:20], "type": "message", "role": "assistant", "model": model + "-20261001",
                                   "content": content, "stop_reason": "end_turn",
                                   "usage": {"input_tokens": uncached, "cache_read_input_tokens": cached, "cache_creation_input_tokens": 0,
                                             "output_tokens": out_tokens}})
        if path == "/v1/responses":
            parts = [p for item in body.get("input", []) for p in (item.get("content") if isinstance(item.get("content"), list) else [{"text": item.get("content", "")}])]
            prompt = "".join(p.get("text", "") for p in parts)
            total = tokens_of(prompt) + 6
            cache_key = (key["id"], model, body.get("prompt_cache_key"), prompt[:200]) if len(prompt) > 4000 else None
            cached = 0
            if cache_key:
                cached = (total // 128) * 128 if cache_key in state["seen_prompts"] else 0
                state["seen_prompts"].add(cache_key)
            question = parts[-1].get("text", "") if parts else ""
            answer = "391" if "17 * 23" in question else (question.split(": ")[-1] if ": " in question else "ok")
            reasoning = 48 if body.get("reasoning") else 0
            out_tokens = tokens_of(answer) + reasoning
            self.record(key, model, total - cached, cached, out_tokens)
            response = {"id": "resp_" + uuid.uuid4().hex[:20], "object": "response", "status": "completed", "model": model,
                        "output": [{"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": answer}]}],
                        "usage": {"input_tokens": total, "input_tokens_details": {"cached_tokens": cached},
                                  "output_tokens": out_tokens, "output_tokens_details": {"reasoning_tokens": reasoning}}}
            if body.get("stream"):
                events = [("response.created", {"type": "response.created", "response": {**response, "status": "in_progress", "output": []}}),
                          ("response.output_text.delta", {"type": "response.output_text.delta", "delta": answer, "output_index": 0, "content_index": 0}),
                          ("response.completed", {"type": "response.completed", "response": response})]
                data = "".join(f"event: {name}\ndata: {json.dumps(obj, ensure_ascii=False)}\n\n" for name, obj in events).encode()
                return self.send(200, data, "text/event-stream")
            return self.send(200, response)
        return self.send(404, {"error": {"message": "unsupported " + path}})

    def record(self, key, model, uncached, cached, output):
        log = {"id": len(state["logs"]) + 1, "api_key_id": key["id"], "model": model, "created_at": now_iso(),
               "input_tokens": uncached, "cache_read_tokens": cached, "cache_creation_tokens": 0, "output_tokens": output,
               "rate_multiplier": key["group"]["rate_multiplier"], "total_cost": 0.001}
        state["logs"].append(log)
        key["last_used_at"] = log["created_at"]
        return log


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"mock sub2api on http://localhost:{PORT}", flush=True)
    server.serve_forever()
