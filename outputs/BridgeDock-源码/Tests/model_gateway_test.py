"""Loopback-only publishing gateway assertions; no live accounts or client apps."""
import http.client
import json
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

seen = []

class Core(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def do_POST(self):
        raw = self.rfile.read(int(self.headers['Content-Length']))
        if self.headers['Content-Type'].startswith('multipart/form-data'):
            seen.append((self.path, raw, dict(self.headers)))
            data = json.dumps({'data': [{'b64_json': 'AAAA'}]}).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
            return
        body = json.loads(raw)
        seen.append((self.path, body, dict(self.headers)))
        assert self.headers['Authorization'] == 'Bearer internal-test-key'
        if body.get('stream'):
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(b'data: {"choices":[{"delta":{"content":"first"}}]}\n\n')
            self.wfile.flush()
            time.sleep(.7)
            self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
            self.close_connection = True
        else:
            data = json.dumps({'ok': True, 'model': body['model'], 'parameters': body.get('reasoning_effort')}).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)

core = ThreadingHTTPServer(('127.0.0.1', 0), Core)
threading.Thread(target=core.serve_forever, daemon=True).start()
with socket.socket() as reserve:
    reserve.bind(('127.0.0.1', 0)); port = reserve.getsockname()[1]
process = subprocess.Popen([sys.argv[1], str(port), str(core.server_port)], stdout=subprocess.PIPE, text=True)
count = 0

def check(condition, label):
    global count
    assert condition, label
    count += 1
    print('PASS ' + label, flush=True)

def call(path, body=None, key='public-test-key', headers=None, chunks=False):
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=4)
    h = {'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'}
    h.update(headers or {})
    payload = json.dumps(body).encode() if body is not None else None
    if chunks: payload = [payload[:11], payload[11:]]
    conn.request('POST' if body is not None else 'GET', path, payload, h, encode_chunked=chunks)
    response = conn.getresponse(); data = response.read(); conn.close()
    return response.status, data

try:
    assert process.stdout.readline().strip() == 'READY'
    status, data = call('/v1/models')
    rows = json.loads(data)['data']; model = rows[0]['id']
    check(status == 200 and len(rows) == 1 and model == '测试渠道/model-a', 'only selected model is published using first four channel characters')
    check(rows[0]['context_length'] == 32768, 'upstream model metadata is preserved')
    check(call('/v1/models', key='wrong')[0] == 401, 'public key is mandatory')
    check(call('/v1/models', key='internal-test-key')[0] == 401, 'internal key is not a public credential')
    check(call('/v8/management/config')[0] == 404, 'management endpoints are inaccessible through public gateway')
    check(call('/v1/models/' + urllib.parse.quote(model, safe=''))[0] == 200, 'single model lookup accepts encoded Unicode IDs')
    before = len(seen)
    check(call('/v1/chat/completions', {'model': 'fixture/model-a'})[0] == 404 and len(seen) == before, 'raw core ID cannot bypass public catalog')
    check(call('/v1/messages', {'model': '测试渠道/model-b'})[0] == 404 and len(seen) == before, 'unselected model is blocked before reaching core')
    for path in ['/v1/chat/completions', '/v1/messages?beta=true', '/v1/responses', '/v1/messages/count_tokens']:
        status, data = call(path, {'model': model, 'reasoning_effort': 'high', 'messages': [], 'metadata': {'safe': True}}, headers={'anthropic-version': '2023-06-01'})
        check(status == 200 and json.loads(data)['model'] == 'fixture/model-a', path + ' routes public ID to core ID')
        check(seen[-1][1]['reasoning_effort'] == 'high' and seen[-1][2].get('Anthropic-Version', seen[-1][2].get('anthropic-version')) == '2023-06-01', 'reasoning and protocol headers survive forwarding')
    check(call('/v1/chat/completions', {'model': model}, chunks=True)[0] == 200, 'chunked JSON input is accepted')
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=4)
    started = time.monotonic()
    conn.request('POST', '/v1/chat/completions', json.dumps({'model': model, 'stream': True}), {'Authorization': 'Bearer public-test-key', 'Content-Type': 'application/json'})
    response = conn.getresponse(); first = response.readline()
    check(b'first' in first and time.monotonic() - started < .6, 'SSE reaches client before upstream completes')
    check(b'[DONE]' in response.read(), 'SSE completes with intact terminator'); conn.close()
    # A valid request may close only its write side while continuing to read.
    body = json.dumps({'model': model}).encode()
    with socket.create_connection(('127.0.0.1', port), timeout=4) as sock:
        sock.sendall(b'POST /v1/responses HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer public-test-key\r\nContent-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body)
        sock.shutdown(socket.SHUT_WR)
        chunks = []
        while chunk := sock.recv(4096): chunks.append(chunk)
        check(b'200' in b''.join(chunks) and b'fixture/model-a' in b''.join(chunks), 'TCP half-close preserves response')
    with socket.create_connection(('127.0.0.1', port), timeout=4) as sock:
        sock.sendall(b'POST /v1/responses HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer public-test-key\r\nTransfer-Encoding: chunked\r\n\r\n\r\n\r\n')
        check(b'400' in sock.recv(4096), 'empty chunk-size line returns 400 without crashing gateway')
    check(call('/v1/models')[0] == 200, 'gateway remains healthy after malformed chunk input')
    with socket.create_connection(('127.0.0.1', port), timeout=4) as sock:
        sock.sendall(b'POST /v1/responses HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer public-test-key\r\nExpect: 100-continue\r\nContent-Length: ' + str(len(body)).encode() + b'\r\n\r\n')
        check(b'100 Continue' in sock.recv(4096), 'Expect 100-continue responds before reading body')
        sock.sendall(body)
        check(b'200' in sock.recv(4096), 'Expect request completes after sending body')
    status, _ = call('/v1/images/generations', {'model': 'grok-imagine-image-2.0', 'prompt': 'cat', 'aspect_ratio': '3:4', 'resolution': '1k', 'response_format': 'b64_json'})
    sent = seen[-1][1]
    check(status == 200 and seen[-1][0] == '/v1/images/generations' and sent['model'] == 'gpt/gpt-image-2.5', 'any image request is routed to the newest GPT image model')
    check(sent['size'] == '1024x1536' and 'aspect_ratio' not in sent and 'response_format' not in sent, 'xAI-style image parameters are converted for GPT')
    call('/v1/images/generations', {'prompt': 'dog'})
    check(seen[-1][1]['model'] == 'gpt/gpt-image-2.5', 'image request without a model still uses GPT')
    check(call('/v1/images/generations', {'prompt': 'dog'}, key='wrong')[0] == 401, 'image endpoint requires the public key')
    before = len(seen)
    check(call('/v1/images/generations')[0] == 405 and len(seen) == before, 'image endpoint only accepts POST')
    boundary = 'bdtestboundary'
    form = (f'--{boundary}\r\nContent-Disposition: form-data; name="model"\r\n\r\ndall-e-2\r\n'
            f'--{boundary}\r\nContent-Disposition: form-data; name="prompt"\r\n\r\nadd a hat\r\n'
            f'--{boundary}\r\nContent-Disposition: form-data; name="image"; filename="a.png"\r\nContent-Type: image/png\r\n\r\n').encode() + b'\x89PNG\r\n\x00\xff' + f'\r\n--{boundary}--\r\n'.encode()
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=4)
    conn.request('POST', '/v1/images/edits', form, {'Authorization': 'Bearer public-test-key', 'Content-Type': f'multipart/form-data; boundary={boundary}'})
    response = conn.getresponse(); response.read(); conn.close()
    sent = seen[-1][1]
    check(response.status == 200 and seen[-1][0] == '/v1/images/edits' and b'gpt/gpt-image-2.5' in sent and b'dall-e-2' not in sent, 'multipart image edit model is replaced')
    check(b'\x89PNG\r\n\x00\xff' in sent and b'add a hat' in sent and sent.endswith(f'--{boundary}--\r\n'.encode()), 'multipart image bytes and fields survive')
    print(f'PASS {count} gateway assertions; isolated loopback only.')
finally:
    process.terminate(); process.wait(timeout=5)
    core.shutdown(); core.server_close()
