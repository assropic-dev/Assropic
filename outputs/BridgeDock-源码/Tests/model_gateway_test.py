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

kiro_seen = []

class Kiro(BaseHTTPRequestHandler):
    """Stands in for kiro2cc-proxy: streams Anthropic events with a pause between them."""
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        kiro_seen.append((self.path, body, dict(self.headers)))
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(b'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"kiro-first"}}\n\n')
        self.wfile.flush()
        time.sleep(.7)
        self.wfile.write(b'event: message_stop\ndata: {"type":"message_stop"}\n\n'); self.wfile.flush()
        self.close_connection = True

core = ThreadingHTTPServer(('127.0.0.1', 0), Core)
threading.Thread(target=core.serve_forever, daemon=True).start()
kiro = ThreadingHTTPServer(('127.0.0.1', 0), Kiro)
threading.Thread(target=kiro.serve_forever, daemon=True).start()
with socket.socket() as reserve:
    reserve.bind(('127.0.0.1', 0)); port = reserve.getsockname()[1]
process = subprocess.Popen([sys.argv[1], str(port), str(core.server_port), str(kiro.server_port)], stdout=subprocess.PIPE, text=True)
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
    rows = json.loads(data)['data']
    kiro_ids = sorted(r['id'] for r in rows if any(p['name'] == 'Kiro' for p in r['bridgedock_parameters']['providers']))
    opus = next(r for r in rows if r['id'] == 'claude-opus-5-5')
    kiro_provider = next(p['id'] for p in opus['bridgedock_parameters']['providers'] if p['name'] == 'Kiro')
    cursor_model = next(r for r in rows if r['owned_by'] == 'Cursor')
    rows = [r for r in rows if r['owned_by'] not in ('Kiro', 'Cursor', 'Claude')]; model = rows[0]['id']
    check(status == 200 and len(rows) == 1 and model == 'model-a', 'only selected model is published under its bare ID')
    check(cursor_model['id'] == 'gpt', 'Cursor effort variants publish as one base ID')
    picker = cursor_model['bridgedock_parameters']
    check(picker['version'] == 2 and [d['id'] for d in picker['definitions']] == ['fast', 'reasoning', 'provider'],
          'version 2 definitions: untested channels publish no context tiers')
    check(len(picker['providers']) == 2 and picker['providers'][1]['id'] == 'channel:gpt-relay'
          and picker['providers'][1]['reasoning_effort'] == ['medium'] and cursor_model['owned_by'] == 'Cursor',
          'same-name models from two sources merge with a providers list')
    check(sum(1 for r in json.loads(data)['data'] if r['id'] == 'gpt') == 1, 'merged model appears once')
    check(len(kiro_ids) == 2, 'Kiro models are published through the gateway catalog')
    check([p['name'] for p in opus['bridgedock_parameters']['providers']] == ['Claude', 'Kiro'],
          'Claude and Kiro version spellings share one picker entry')
    check(opus['bridgedock_parameters']['providers'][0]['context_options'] == [],
          'context tiers come only from long-context test results')
    check(cursor_model['capabilities']['reasoning_effort'] == ['low', 'high']
          and cursor_model['capabilities']['reasoning_default'] == 'low', 'Cursor catalog advertises its exact selectable efforts and default')
    for path, parameter in [('/v1/chat/completions', {'reasoning_effort': 'high'}),
                            ('/v1/responses', {'reasoning': {'effort': 'high'}}),
                            ('/v1/messages', {'output_config': {'effort': 'high'}})]:
        status, data = call(path, {'model': cursor_model['id'], **parameter})
        check(status == 200 and json.loads(data)['model'] == 'cursor-fixture/gpt-high', path + ' maps chosen Cursor effort to the exact account variant')
    status, data = call('/v1/chat/completions', {'model': cursor_model['id']})
    check(status == 200 and json.loads(data)['model'] == 'cursor-fixture/gpt-low', 'Cursor default effort retains the chosen model variant')
    requests_before = len(seen)
    check(call('/v1/chat/completions', {'model': cursor_model['id'], 'reasoning_effort': 'max'})[0] == 400
          and len(seen) == requests_before, 'Unsupported Cursor effort fails before any upstream call')
    def native_headers(parameters):
        return {'X-BridgeDock-Parameters': urllib.parse.quote(json.dumps([
            {'id': key, 'value': value} for key, value in parameters.items()]))}
    for path in ['/v1/chat/completions', '/v1/responses', '/v1/messages']:
        status, data = call(path, {'model': cursor_model['id']}, headers=native_headers({'reasoning': 'high', 'fast': 'true'}))
        check(status == 200 and json.loads(data)['model'] == 'cursor-fixture/gpt-high-fast', 'Native parameter header selects exact Fast and Effort variant')
        check('x-bridgedock-parameters' not in {key.lower() for key in seen[-1][2]}, 'Local parameter header is consumed before forwarding')
    before = len(seen)
    check(call('/v1/responses', {'model': cursor_model['id']}, headers=native_headers({'reasoning': 'low', 'fast': 'true'}))[0] == 400
          and len(seen) == before, 'Unsupported native combination does not silently downgrade')
    status, _ = call('/v1/responses', {'model': model}, headers=native_headers({'reasoning': 'ultra'}))
    check(status == 200 and 'reasoning' not in seen[-1][1], 'Unadvertised reasoning level falls back to the provider default')
    check(call('/v1/responses', {'model': model}, headers={'X-BridgeDock-Parameters': '%BAD'})[0] == 400,
          'Malformed parameter header is rejected')
    check(call('/v1/responses', {'model': model}, headers=native_headers({'context': '32768'}))[0] == 200,
          'Context returned directly by a provider is accepted without a static definition')
    check(call('/v1/responses', {'model': model}, headers=native_headers({'context': '65536'}))[0] == 200,
          'Context above the provider limit falls back to the provider default')
    relay = next(p['id'] for p in picker['providers'] if p['id'] == 'channel:gpt-relay')
    status, data = call('/v1/chat/completions', {'model': 'gpt'}, headers=native_headers({'provider': relay, 'reasoning': 'high'}))
    check(status == 200 and json.loads(data)['model'] == 'relay/gpt' and 'reasoning_effort' not in seen[-1][1],
          'provider parameter selects the channel and drops an effort it does not declare')
    status, data = call('/v1/chat/completions', {'model': 'gpt'}, headers=native_headers({'reasoning': 'high'}))
    check(status == 200 and json.loads(data)['model'] == 'cursor-fixture/gpt-high', 'missing provider selects the first source')
    check(call('/v1/chat/completions', {'model': 'gpt'}, headers=native_headers({'provider': 'gone'}))[0] == 400,
          'unknown provider is rejected')
    pooled = next(i for i in kiro_ids if i.endswith('claude-opus-5-5'))
    unprefixed = next(i for i in kiro_ids if i.endswith('claude-sonnet-5-5'))
    before = len(seen)
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=4)
    started = time.monotonic()
    conn.request('POST', '/v1/messages', json.dumps({'model': pooled, 'stream': True, 'max_tokens': 8, 'messages': []}),
                 {'Authorization': 'Bearer public-test-key', 'Content-Type': 'application/json', 'anthropic-version': '2023-06-01',
                  **native_headers({'provider': kiro_provider, 'context': '131072'})})
    response = conn.getresponse()
    first = response.readline() + response.readline()
    check(b'kiro-first' in first and time.monotonic() - started < .6, 'Kiro SSE reaches the client before the runtime finishes')
    check(b'message_stop' in response.read(), 'Kiro SSE completes intact'); conn.close()
    path, sent, headers = kiro_seen[-1]
    check(path == '/v1/messages' and sent['model'] == 'claude-opus-5.5', 'Kiro request reaches the runtime with the bare upstream model')
    check(headers.get('Authorization') == 'Bearer kiro-pool-key', 'prefixed Kiro model uses its own pool key, never the public or core key')
    check(len(seen) == before, 'Kiro inference does not pass through the core')
    status, data = call('/v1/messages', {'model': pooled, 'messages': []}, headers=native_headers({'provider': 'provider:anthropic', 'context': '524288'}))
    check(status == 200 and seen[-1][1]['model'] == 'claude-opus-5-5', 'same picker model selects the Claude upstream independently')
    status, _ = call('/v1/messages', {'model': 'claude-opus-5.5', 'messages': []})
    check(status == 200 and kiro_seen[-1][1]['model'] == 'claude-opus-5.5', 'old dotted public ID retains its Kiro route')
    status, _ = call('/v1/chat/completions', {'model': unprefixed, 'messages': []})
    check(status == 200 and kiro_seen[-1][0] == '/v1/chat/completions' and kiro_seen[-1][1]['model'] == 'claude-sonnet-5.5'
          and kiro_seen[-1][2].get('Authorization') == 'Bearer kiro-default-key', 'unprefixed Kiro model uses the default runtime key')
    kiro_count = len(kiro_seen)
    status, _ = call('/v1/embeddings', {'model': pooled, 'input': 'x'}, headers=native_headers({'provider': kiro_provider}))
    check(status == 200 and len(kiro_seen) == kiro_count and seen[-1][1]['model'] == 'kiro/claude-opus-5.5',
          'endpoints kiro2cc does not serve stay on the core')
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
    kiro.shutdown(); kiro.server_close()
