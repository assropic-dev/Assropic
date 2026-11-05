"""Run diagnostic protocol/error checks entirely against a loopback fixture."""
import json
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert self.headers["Authorization"] == "Bearer test-key"
        model = body["model"]
        if model == "rate-limit":
            self.send_json(429, {"error": {"message": "fixture quota limit"}})
            return
        if model == "redirect":
            self.send_response(302)
            self.send_header("Location", "/forbidden-redirect")
            self.end_headers()
            return
        if model == "bad-json":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b"not a model response")
            return
        if model.startswith("thinking-"):
            assert body["thinking"]["type"] == "adaptive" and body["output_config"]["effort"] == "high"
            content = [{"type": "text", "text": "推理过程略。\n{\"answer\": 21}"}]
            if model == "thinking-signed":
                content.insert(0, {"type": "thinking", "thinking": "...", "signature": "S" * 400})
            self.send_json(200, {"model": "upstream-fixture", "content": content, "stop_reason": "end_turn"})
            return
        text = "" if model == "empty" else ("wrong" if model == "wrong-marker" else "BD_FIXTURE")
        if not body["stream"]:
            value = {"model": "upstream-fixture"}
            if self.path == "/v1/chat/completions":
                value["choices"] = [{"message": {"content": text}, "finish_reason": "stop"}]
            elif self.path == "/v1/messages":
                value["content"] = [{"type": "text", "text": text}]
            else:
                value["output"] = [{"content": [{"type": "output_text", "text": text}]}]
            self.send_json(200, value)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        self.wfile.write(b": keepalive\r\n\r\n")
        self.wfile.flush()
        time.sleep(3 if model == "slow" else 0.15)
        try:
            if model == "stream-error":
                self.event({"type": "error", "error": {"message": "fixture error"}})
                return
            if self.path == "/v1/chat/completions":
                self.event({"model": "upstream-fixture", "choices": [{"delta": {"content": text}}]})
                if model == "cutoff":
                    return
                self.event({"choices": [{"delta": {}, "finish_reason": "length" if model == "truncated" else "stop"}], "usage": {"completion_tokens": 4}})
                time.sleep(0.1)
                self.wfile.write(b"data: [DONE]\r\n\r\n")
            elif self.path == "/v1/messages":
                assert self.headers["anthropic-version"] == "2023-06-01"
                self.event({"type": "message_start", "message": {"model": "upstream-fixture"}})
                self.event({"type": "content_block_delta", "delta": {"type": "text_delta", "text": text}})
                time.sleep(0.1)
                self.event({"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 4}})
                self.event({"type": "message_stop"})
            else:
                self.event({"type": "response.created", "response": {"model": "upstream-fixture"}})
                self.event({"type": "response.output_text.delta", "delta": text})
                time.sleep(0.1)
                self.event({"type": "response.completed", "response": {"model": "upstream-fixture", "status": "completed", "output": [{"content": [{"type": "output_text", "text": text}]}], "usage": {"output_tokens": 4}}})
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def event(self, value):
        self.wfile.write(("data: " + json.dumps(value) + "\r\n\r\n").encode())
        self.wfile.flush()

    def send_json(self, status, value):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run([sys.argv[1], f"http://127.0.0.1:{server.server_port}"], check=True, timeout=40)
    finally:
        server.shutdown()
        server.server_close()
