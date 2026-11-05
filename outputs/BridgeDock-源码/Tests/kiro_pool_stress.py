#!/usr/bin/env python3
"""Kiro 多账号共享池压力测试：走 BridgeDock 网关（和 Cursor 同一条路径），检查轮流、粘性、并发、
热变更、进程崩溃恢复和持续负载下有没有账号掉线。

用法：python3 -I Tests/kiro_pool_stress.py [阶段 ...]
阶段：smoke rotation sticky burst hot crash soak（默认全部）

只读取本机 BridgeDock 数据目录里的网关 Key 和 kiro2cc 管理密码，不打印它们。
测试请求的 User-Agent 带 bd-stress 标记，统计时只计这些请求，不受同时在用的 Cursor 影响。
hot 阶段会临时把一个 Kiro 账号文件的 disabled 设为 true，结束后恢复原值。
"""
import json, os, signal, subprocess, sys, threading, time, urllib.error, urllib.request, uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

DATA = os.path.expanduser("~/Library/Application Support/BridgeDock")
RUNTIME = os.path.join(DATA, "kiro-runtime")
UA = "Cursor/3.27.22 bd-stress/" + uuid.uuid4().hex[:8]
MODEL = os.environ.get("BD_STRESS_MODEL", "claude-sonnet-4-6")
STATE = json.load(open(os.path.join(DATA, "state.json")))
GATEWAY = "http://127.0.0.1:%d" % STATE["port"]
results = {}


def admin_key():
    return json.load(open(os.path.join(RUNTIME, "config.json")))["adminPsw"]


def admin(path, method="GET", body=None):
    request = urllib.request.Request("http://127.0.0.1:18421/api/admin" + path, method=method,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={"x-api-key": admin_key(), "Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(request, timeout=20))


def kiro_pid():
    out = subprocess.run(["pgrep", "-f", "BridgeDock.app/Contents/Resources/kiro2cc-proxy"], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None


def now():
    return datetime.now(timezone.utc)


def chat(messages, max_tokens=40, timeout=180):
    """One streaming request through the BridgeDock gateway, the way Cursor sends it."""
    body = {"model": MODEL, "stream": True, "max_tokens": max_tokens, "messages": messages}
    request = urllib.request.Request(GATEWAY + "/v1/chat/completions", data=json.dumps(body).encode(), method="POST",
                                     headers={"Authorization": "Bearer " + STATE["clientKey"], "Content-Type": "application/json",
                                              "User-Agent": UA, "Accept": "text/event-stream"})
    started = time.time(); first = None; text = []; done = False; finish = None
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            for raw in response:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    done = True; break
                try:
                    chunk = json.loads(data)
                except ValueError:
                    continue
                for choice in chunk.get("choices", []):
                    piece = (choice.get("delta") or {}).get("content")
                    if piece:
                        first = first or time.time(); text.append(piece)
                    finish = choice.get("finish_reason") or finish
        return {"ok": done or finish is not None, "status": 200, "ttfb": (first or time.time()) - started,
                "total": time.time() - started, "ended": time.time(), "text": "".join(text), "finish": finish, "done": done}
    except urllib.error.HTTPError as error:
        return {"ok": False, "status": error.code, "error": error.read()[:300].decode("utf-8", "replace"), "total": time.time() - started}
    except Exception as error:  # noqa: BLE001 — every failure is a data point here
        return {"ok": False, "status": None, "error": repr(error)[:300], "total": time.time() - started}


def fresh(n, extra=""):
    """A brand-new conversation (unique first message), so kiro2cc schedules it as a new session."""
    return [{"role": "user", "content": "[%s] 第 %d 个独立对话。%s只回复：OK-%d" % (uuid.uuid4().hex, n, extra, n)}]


def my_records(since, until=None):
    """Test requests kiro2cc recorded between `since` and `until`, as (createdAt, credentialId)."""
    found = []
    for credential in admin("/credentials")["credentials"]:
        cid = credential["id"]
        try:
            records = admin("/credentials/%d/usage/records?limit=500" % cid).get("records", [])
        except Exception:  # noqa: BLE001
            records = []
        for record in records:
            stamp = record.get("createdAt", "")
            if record.get("userAgent") == UA and stamp >= iso(since) and (until is None or stamp <= iso(until)):
                found.append((record["createdAt"], record.get("credentialId", cid)))
    return sorted(found)


def iso(moment):
    return moment.isoformat().replace("+00:00", "Z")[:26]


def by_account(records):
    counts = {}
    for _, cid in records:
        counts[cid] = counts.get(cid, 0) + 1
    return dict(sorted(counts.items()))


def accounts_health():
    rows = []
    for c in admin("/credentials")["credentials"]:
        rows.append({k: c.get(k) for k in ("id", "disabled", "disabledReason", "failureCount", "refreshFailureCount", "expiresAt")})
    return rows


def summarize(name, outcomes, since=None, extra=None, until=None):
    ok = sum(1 for o in outcomes if o["ok"])
    failures = [o for o in outcomes if not o["ok"]]
    ttfb = sorted(o["ttfb"] for o in outcomes if o.get("ttfb"))
    total = sorted(o["total"] for o in outcomes if o["ok"])
    row = {"requests": len(outcomes), "ok": ok, "failed": len(failures),
           "ttfb_p50": round(ttfb[len(ttfb) // 2], 2) if ttfb else None,
           "total_p95": round(total[int(len(total) * 0.95) - 1 if len(total) > 1 else 0], 2) if total else None,
           "errors": sorted({"%s %s" % (f.get("status"), (f.get("error") or "")[:120]) for f in failures})[:5]}
    if since is not None:
        time.sleep(2)
        row["by_account"] = by_account(my_records(since, until))
    if extra:
        row.update(extra)
    results[name] = row
    print("\n== %s ==\n%s" % (name, json.dumps(row, ensure_ascii=False, indent=1)), flush=True)
    return row


def phase_smoke():
    since = now()
    summarize("smoke", [chat(fresh(0))], since)


def phase_rotation():
    """New conversations one after another: balanced mode should alternate accounts."""
    since = now()
    outcomes = [chat(fresh(i)) for i in range(12)]
    time.sleep(2)
    order = [cid for _, cid in my_records(since)]
    summarize("rotation_sequential", outcomes, since, {"order": order})


def phase_sticky():
    """Multi-turn conversations, Cursor style (full history each turn): every turn should stay on one account."""
    report = []
    for c in range(4):
        messages = fresh(100 + c, "这是一个多轮对话的开头。")
        seen = []
        for turn in range(3):
            since = now()
            outcome = chat(messages)
            time.sleep(1.5)
            seen.append([cid for _, cid in my_records(since)][-1:] or [None])
            messages = messages + [{"role": "assistant", "content": outcome.get("text") or "OK"},
                                   {"role": "user", "content": "第 %d 轮，继续只回复：OK" % (turn + 2)}]
        accounts = [s[0] for s in seen]
        report.append({"conversation": c, "accounts_per_turn": accounts, "sticky": len(set(accounts)) == 1})
    results["sticky"] = report
    print("\n== sticky ==\n" + json.dumps(report, ensure_ascii=False, indent=1), flush=True)


def phase_burst():
    for size in (10, 24, 48):
        since = now()
        with ThreadPoolExecutor(max_workers=size) as pool:
            outcomes = list(pool.map(lambda i: chat(fresh(1000 + i)), range(size)))
        summarize("burst_%d" % size, outcomes, since)


def account_file_for(cid):
    ids = json.load(open(os.path.join(RUNTIME, "bridgedock-ids.json")))
    name = next(n for n, i in ids.items() if i == cid)
    return os.path.join(DATA, "accounts", name)


def set_disabled(path, value):
    """Changes only `disabled`, re-reading the file first so rotated tokens are never reverted."""
    current = json.load(open(path))
    if value is None:
        current.pop("disabled", None)
    else:
        current["disabled"] = value
    tmp = path + ".bd-stress.tmp"
    with open(tmp, "w") as handle:
        json.dump(current, handle, ensure_ascii=False, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def wait_for(predicate, limit=60):
    deadline = time.time() + limit
    while time.time() < deadline:
        try:
            if predicate():
                return True
        except Exception:  # noqa: BLE001
            pass
        time.sleep(1)
    return False


def phase_hot():
    """Disable one account while long streams run on both, then enable it again: kiro2cc must not
    restart, in-flight streams must finish, and new conversations must avoid the disabled account."""
    pid = kiro_pid()
    credentials = sorted(c["id"] for c in admin("/credentials")["credentials"])
    victim = credentials[-1]
    path = account_file_for(victim)
    original = json.load(open(path)).get("disabled")
    long_prompt = lambda i: [{"role": "user", "content": "[%s] 从 1 数到 1500，每个数字之间用空格隔开，不要写别的。" % uuid.uuid4().hex}]
    since = now()
    with ThreadPoolExecutor(max_workers=8) as pool:
        streams = [pool.submit(chat, long_prompt(i), 9000, 900) for i in range(8)]
        time.sleep(4)
        set_disabled(path, True)
        applied = wait_for(lambda: any(c["id"] == victim and c["disabled"] for c in admin("/credentials")["credentials"]), 45)
        applied_at = time.time()
        in_flight = [f.result() for f in streams]
    streams_until = now()
    pid_after_disable = kiro_pid()
    during_since = now()
    during = [chat(fresh(2000 + i)) for i in range(6)]
    during_until = now()
    set_disabled(path, original)
    restored = wait_for(lambda: any(c["id"] == victim and not c["disabled"] for c in admin("/credentials")["credentials"]), 45)
    after_since = now()
    after = [chat(fresh(3000 + i)) for i in range(6)]
    summarize("hot_inflight_streams", in_flight, since, {
        "disable_applied_live": applied,
        "streams_still_running_when_disable_applied": sum(1 for o in in_flight if o.get("ended", 0) > applied_at),
        "stream_chars": sorted(len(o.get("text", "")) for o in in_flight)}, until=streams_until)
    summarize("hot_while_disabled", during, during_since, {"disabled_account": victim}, until=during_until)
    summarize("hot_after_enable", after, after_since, {"enable_applied_live": restored,
              "kiro2cc_restarted": len({pid, pid_after_disable, kiro_pid()}) != 1})


def phase_crash():
    """SIGKILL kiro2cc: BridgeDock must bring it back by itself, and requests must keep working."""
    old = kiro_pid()
    os.kill(old, signal.SIGKILL)
    killed_at = time.time()
    # Sent while kiro2cc is down: the gateway must hand them to the core's Kiro plugin, not fail them.
    with ThreadPoolExecutor(max_workers=6) as pool:
        gap = list(pool.map(lambda i: chat(fresh(4000 + i)), range(6)))
    recovered = wait_for(lambda: kiro_pid() not in (None, old) and
                         urllib.request.urlopen("http://127.0.0.1:18421/v1/ping", timeout=2).status == 200, 90)
    back_after = round(time.time() - killed_at, 1)
    time.sleep(13)  # let BridgeDock's next refresh republish the pool route
    since = now()
    with ThreadPoolExecutor(max_workers=8) as pool:
        after = list(pool.map(lambda i: chat(fresh(5000 + i)), range(8)))
    summarize("crash_gap_requests", gap)
    summarize("crash_after_restart", after, since, {"auto_restarted": recovered, "seconds_to_restart": back_after,
                                                   "old_pid": old, "new_pid": kiro_pid()})


def phase_soak():
    """Sustained load: concurrency 8 for BD_STRESS_SOAK seconds (default 300)."""
    duration = int(os.environ.get("BD_STRESS_SOAK", "300"))
    since = now(); stop = time.time() + duration
    outcomes = []; lock = threading.Lock(); counter = [0]

    def worker():
        while time.time() < stop:
            with lock:
                counter[0] += 1; n = counter[0]
            outcome = chat(fresh(10000 + n))
            with lock:
                outcomes.append(outcome)

    threads = [threading.Thread(target=worker) for _ in range(int(os.environ.get("BD_STRESS_WORKERS", "8")))]
    for t in threads: t.start()
    for t in threads: t.join()
    summarize("soak_%ds" % duration, outcomes, since)


def phase_refresh():
    """Force a token refresh on one account in the middle of steady traffic (what kiro2cc does on its
    own before a token expires): requests keep succeeding, the account stays enabled, and the new
    token reaches BridgeDock's account file within a minute."""
    target = sorted(c["id"] for c in admin("/credentials")["credentials"])[0]
    runtime = {e["id"]: e for e in json.load(open(os.path.join(RUNTIME, "credentials.json")))}
    before = runtime[target].get("expiresAt")
    since = now(); stop = time.time() + 90; outcomes = []; lock = threading.Lock()

    def worker():
        while time.time() < stop:
            outcome = chat(fresh(20000))
            with lock:
                outcomes.append(outcome)

    threads = [threading.Thread(target=worker) for _ in range(4)]
    for t in threads: t.start()
    time.sleep(30)
    body = {"refreshToken": runtime[target]["refreshToken"], "authMethod": runtime[target].get("authMethod", "social")}
    try:
        admin("/credentials/%d" % target, "PUT", body); refreshed = True
    except Exception as error:  # noqa: BLE001
        refreshed = repr(error)[:200]
    for t in threads: t.join()
    after = {e["id"]: e for e in json.load(open(os.path.join(RUNTIME, "credentials.json")))}[target].get("expiresAt")
    written = wait_for(lambda: json.load(open(account_file_for(target))).get("expiresAt") == after, 75)
    summarize("refresh_under_load", outcomes, since, {"account": target, "refresh_call": refreshed,
              "expires_before": before, "expires_after": after, "written_back_to_account_file": written})


PHASES = {"refresh": phase_refresh, "smoke": phase_smoke, "rotation": phase_rotation, "sticky": phase_sticky, "burst": phase_burst,
          "hot": phase_hot, "crash": phase_crash, "soak": phase_soak}

if __name__ == "__main__":
    chosen = sys.argv[1:] or list(PHASES)
    print("model=%s ua-tag=%s kiro2cc pid=%s" % (MODEL, UA.split()[-1], kiro_pid()), flush=True)
    print("accounts before: " + json.dumps(accounts_health(), ensure_ascii=False), flush=True)
    for name in chosen:
        PHASES[name]()
    results["accounts_after"] = accounts_health()
    print("\naccounts after: " + json.dumps(results["accounts_after"], ensure_ascii=False), flush=True)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "kiro-stress-result.json")
    json.dump(results, open(out, "w"), ensure_ascii=False, indent=1)
    print("saved " + os.path.normpath(out))
