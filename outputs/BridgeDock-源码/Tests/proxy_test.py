"""Loopback-only integration tests. No real credentials or external model calls."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


seen = []
direct = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class MockProvider(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def send_json(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.send_json(200, {'object': 'list', 'data': [{'id': 'upstream-model', 'object': 'model'}, {'id': 'second-model', 'object': 'model'}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        seen.append((self.path, body, self.headers.get('Authorization')))
        if self.path != '/v1/chat/completions':
            self.send_json(404, {'error': {'message': 'Unexpected path'}})
            return
        if self.headers.get('Authorization') != 'Bearer mock-upstream-key':
            self.send_json(401, {'error': {'message': 'Wrong upstream key'}})
            return
        if body['model'] == 'second-model':
            self.send_json(429, {'error': {'message': 'Simulated quota exhausted', 'type': 'rate_limit_error'}})
            return
        tool = bool(body.get('tools'))
        tool_call = {'index': 0, 'id': 'call_mock', 'type': 'function', 'function': {'name': 'read_file', 'arguments': '{"path":"hello.txt"}'}}
        message = {'role': 'assistant', 'content': 'OK'}
        if tool:
            message = {'role': 'assistant', 'content': None, 'tool_calls': [tool_call]}
        if body.get('stream'):
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Connection', 'close')
            self.end_headers()
            deltas = [{'role': 'assistant'}, {'tool_calls': [tool_call]} if tool else {'content': 'O'}, {} if tool else {'content': 'K'}]
            for delta in deltas:
                chunk = {'id': 'chatcmpl-mock', 'object': 'chat.completion.chunk', 'created': 1730000000, 'model': 'upstream-model', 'choices': [{'index': 0, 'delta': delta, 'finish_reason': None}]}
                self.wfile.write(('data: ' + json.dumps(chunk) + '\n\n').encode())
                self.wfile.flush()
            final = {'id': 'chatcmpl-mock', 'object': 'chat.completion.chunk', 'created': 1730000000, 'model': 'upstream-model', 'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'tool_calls' if tool else 'stop'}], 'usage': {'prompt_tokens': 5, 'completion_tokens': 2, 'total_tokens': 7}}
            self.wfile.write(('data: ' + json.dumps(final) + '\n\ndata: [DONE]\n\n').encode())
            self.wfile.flush()
            self.close_connection = True
        else:
            self.send_json(200, {'id': 'chatcmpl-mock', 'object': 'chat.completion', 'created': 1730000000, 'model': 'upstream-model', 'choices': [{'index': 0, 'message': message, 'finish_reason': 'tool_calls' if tool else 'stop'}], 'usage': {'prompt_tokens': 5, 'completion_tokens': 2, 'total_tokens': 7}})


def call(path, body=None, key='local-test-key', method=None):
    request = urllib.request.Request('http://127.0.0.1:19417' + path,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'}, method=method)
    if path == '/v1/messages':
        request.add_header('anthropic-version', '2023-06-01')
    try:
        with direct.open(request, timeout=20) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 19419), MockProvider)
    if '--serve' in sys.argv:
        print('Mock provider listening on 127.0.0.1:19419', flush=True)
        server.serve_forever()
        return
    threading.Thread(target=server.serve_forever, daemon=True).start()
    root = Path(__file__).resolve().parents[1]
    scratch = Path(sys.argv[1]).resolve()
    plugin = scratch / 'plugins/darwin/arm64'
    plugin.mkdir(parents=True, exist_ok=True)
    (scratch / 'accounts').mkdir(exist_ok=True)
    shutil.copy2(root / 'Vendor/kiro.dylib', plugin / 'kiro.dylib')
    config = json.loads((scratch / 'config.yaml').read_text())
    config['oauth']['auth-dir'] = str(scratch / 'accounts')
    config['plugins']['dir'] = str(scratch / 'plugins')
    (scratch / 'config.yaml').write_text(json.dumps(config))
    output = open(scratch / 'core-test.log', 'w')
    core = subprocess.Popen([str(root / 'Vendor/cli-proxy-api'), '-config', str(scratch / 'config.yaml'), '-local-model'], cwd=scratch, stdout=output, stderr=output)
    count = 0

    def check(value, label):
        nonlocal count
        assert value, label
        print('PASS ' + label, flush=True)
        count += 1

    try:
        for _ in range(100):
            try:
                ready_status, ready_body = call('/v1/models')
                if ready_status == 200 and 'mock/test-model' in ready_body:
                    break
            except OSError:
                pass
            time.sleep(.1)
        else:
            raise AssertionError('core readiness response: ' + str((ready_status, ready_body)) + '\n' + (scratch / 'core-test.log').read_text()[-1500:])
        status, text = call('/v1/models')
        ids = [x['id'] for x in json.loads(text)['data']]
        check('mock/test-model' in ids, 'model prefix and alias registered')
        check(call('/v1/models', key='wrong-key')[0] == 401, 'invalid API key rejected')
        check(call('/v8/management/config', key='local-test-key')[0] in (401, 403), 'client key cannot access management')
        status, text = call('/v8/management/plugins', key='management-test-key')
        check(status == 200 and 'kiro' in text.lower(), 'bundled Kiro plugin loaded')
        check('load_error' not in text or '"load_error":""' in text, 'Kiro plugin has no load failure')

        for provider in ['claude', 'codex']:
            status, text = call('/v8/management/oauth/auth-url?provider=' + provider, key='management-test-key')
            oauth = json.loads(text)
            check(status == 200 and oauth.get('url', '').startswith('https://') and bool(oauth.get('state')), provider + ' OAuth URL creation')
            status, text = call('/v8/management/oauth/session?state=' + oauth['state'], key='management-test-key', method='DELETE')
            check(status == 200 and json.loads(text).get('cancelled'), provider + ' OAuth cancellation')
        messages = [{'role': 'user', 'content': 'Reply OK'}]
        chat = {'model': 'mock/test-model', 'messages': messages, 'max_tokens': 64}
        status, text = call('/v1/chat/completions', chat)
        check(status == 200 and json.loads(text)['choices'][0]['message']['content'] == 'OK', 'Chat Completions non-streaming')
        check(seen[-1][1]['model'] == 'upstream-model', 'alias rewritten to actual upstream model')
        check(seen[-1][2] == 'Bearer mock-upstream-key', 'upstream credential replaces local key')
        status, text = call('/v1/chat/completions', dict(chat, stream=True))
        check(status == 200 and '[DONE]' in text and 'chat.completion.chunk' in text, 'Chat Completions SSE')
        anthropic = {'model': 'mock/test-model', 'messages': messages, 'max_tokens': 64}
        status, text = call('/v1/messages', anthropic)
        check(status == 200 and json.loads(text)['content'][0]['text'] == 'OK', 'Anthropic request and response translation')
        status, text = call('/v1/messages', dict(anthropic, stream=True))
        check(status == 200 and 'message_stop' in text and 'content_block_delta' in text, 'Anthropic streaming translation')
        responses = {'model': 'mock/test-model', 'input': 'Reply OK', 'max_output_tokens': 64}
        status, text = call('/v1/responses', responses)
        check(status == 200 and 'OK' in text and 'output' in json.loads(text), 'Responses request and response translation')
        status, text = call('/v1/responses', dict(responses, stream=True))
        check(status == 200 and 'response.completed' in text and 'response.output_text.delta' in text, 'Responses streaming translation')
        schema = {'type': 'object', 'properties': {'path': {'type': 'string'}}, 'required': ['path']}
        tools = [{'type': 'function', 'function': {'name': 'read_file', 'parameters': schema}}]
        status, text = call('/v1/chat/completions', dict(chat, tools=tools))
        check(status == 200 and json.loads(text)['choices'][0]['message']['tool_calls'][0]['function']['name'] == 'read_file', 'Chat tool call')
        status, text = call('/v1/messages', dict(anthropic, tools=[{'name': 'read_file', 'input_schema': schema}]))
        check(status == 200 and any(x['type'] == 'tool_use' for x in json.loads(text)['content']), 'Anthropic tool call translation')
        status, text = call('/v1/responses', dict(responses, tools=[{'type': 'function', 'name': 'read_file', 'parameters': schema}]))
        check(status == 200 and any(x['type'] == 'function_call' for x in json.loads(text)['output']), 'Responses function call translation')
        status, text = call('/v1/messages', dict(anthropic, stream=True, tools=[{'name': 'read_file', 'input_schema': schema}]))
        check(status == 200 and 'tool_use' in text and 'input_json_delta' in text, 'Anthropic streamed tool call')
        status, text = call('/v1/responses', dict(responses, stream=True, tools=[{'type': 'function', 'name': 'read_file', 'parameters': schema}]))
        check(status == 200 and 'function_call' in text and 'response.completed' in text, 'Responses streamed tool call')
        status, text = call('/v1/chat/completions', dict(chat, model='unknown-model'))
        check(status >= 400, 'unknown model fails explicitly')
        status, text = call('/v1/chat/completions', dict(chat, model='mock/second-model'))
        check(status == 429, 'upstream rate-limit status propagated')
        config['api-keys']['openai-compatibility'][0]['models'][0]['alias'] = 'renamed'
        status, _ = call('/v8/management/config.yaml', config, key='management-test-key', method='PUT')
        check(status == 200, 'live configuration write accepted')
        time.sleep(.7)
        status, text = call('/v1/models')
        check('mock/renamed' in text and 'mock/test-model' not in text, 'model change hot reloads')
        print(f'PASS {count} proxy integration checks', flush=True)
    finally:
        core.terminate()
        try:
            core.wait(timeout=8)
        except subprocess.TimeoutExpired:
            core.kill()
            core.wait()
        output.close()
        server.shutdown()


if __name__ == '__main__':
    main()
