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
# Pool credentials for the routing checks: which key served each request, and scripted failures.
pool_seen = []
pool_failures = {}
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
        auth = self.headers.get('Authorization')
        if body.get('model') in ('pool-model', 'slow-model'):
            self.pool(body, auth)
            return
        if auth != 'Bearer mock-upstream-key':
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


    def pool(self, body, auth):
        pool_seen.append((auth, body.get('stream', False)))
        if auth not in ('Bearer pool-key-1', 'Bearer pool-key-2'):
            self.send_json(401, {'error': {'message': 'Wrong pool key'}})
            return
        if pool_failures.get(auth, 0) > 0:
            pool_failures[auth] -= 1
            self.send_json(503, {'error': {'message': 'Simulated transient overload', 'type': 'server_error'}})
            return
        if not body.get('stream'):
            self.send_json(200, {'id': 'chatcmpl-pool', 'object': 'chat.completion', 'created': 1730000000, 'model': body['model'], 'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': 'OK'}, 'finish_reason': 'stop'}], 'usage': {'prompt_tokens': 5, 'completion_tokens': 1, 'total_tokens': 6}})
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Connection', 'close')
        self.end_headers()
        for index, delta in enumerate([{'role': 'assistant'}, {'content': 'O'}, {'content': 'K'}]):
            if body['model'] == 'slow-model' and index == 1:
                time.sleep(2.6)  # a long silence after the first event, like extended thinking
            chunk = {'id': 'chatcmpl-pool', 'object': 'chat.completion.chunk', 'created': 1730000000, 'model': body['model'], 'choices': [{'index': 0, 'delta': delta, 'finish_reason': None}]}
            self.wfile.write(('data: ' + json.dumps(chunk) + '\n\n').encode())
            self.wfile.flush()
        final = {'id': 'chatcmpl-pool', 'object': 'chat.completion.chunk', 'created': 1730000000, 'model': body['model'], 'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}]}
        self.wfile.write(('data: ' + json.dumps(final) + '\n\ndata: [DONE]\n\n').encode())
        self.wfile.flush()
        self.close_connection = True


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
    (scratch / 'accounts/kiro-offline.json').write_text(json.dumps({
        'type': 'kiro', 'disabled': True, 'email': 'offline@example.invalid', 'auth_method': 'social',
        'refresh_token': 'placeholder', 'access_token': 'placeholder'}))
    shutil.copy2(root / 'Vendor/kiro.dylib', plugin / 'kiro.dylib')
    config = json.loads((scratch / 'config.yaml').read_text())
    config['oauth']['auth-dir'] = str(scratch / 'accounts')
    config['plugins']['dir'] = str(scratch / 'plugins')
    # Two credentials of one provider, so the generated routing (session affinity, failover) has a choice.
    config['api-keys']['openai-compatibility'].append({
        'name': 'Pool', 'prefix': 'pool', 'base-url': 'http://127.0.0.1:19419/v1',
        'keys': [{'api-key': 'pool-key-1'}, {'api-key': 'pool-key-2'}],
        'models': [{'name': 'pool-model', 'alias': 'pool-model'}, {'name': 'slow-model', 'alias': 'slow-model'}]})
    generated_routing = json.loads(json.dumps(config['routing']))
    generated_streaming = dict(config['requests']['streaming'])
    # Same streaming behaviour as generated, with a 1 s heartbeat so the check runs quickly.
    config['requests']['streaming']['keepalive-seconds'] = 1
    # And a 2 s transient-error rest instead of 15 s, for the same reason.
    config['routing']['cooldown']['transient-error-cooldown-seconds'] = 2
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
        # Generated routing: one conversation stays on one credential (prompt cache), new ones spread out.
        check(generated_routing.get('session-affinity') is True and generated_routing.get('session-affinity-rebind-on') == 'quota'
              and generated_streaming == {'keepalive-seconds': 15, 'bootstrap-retries': 1}, 'generated routing and streaming settings')
        conversation = [{'role': 'system', 'content': 'You are a pool test.'}, {'role': 'user', 'content': 'Conversation one'}]
        pool_seen.clear()
        for turn in range(6):
            turns = conversation + [{'role': 'assistant', 'content': 'OK'}, {'role': 'user', 'content': 'turn %d' % turn}] if turn else conversation
            status, _ = call('/v1/chat/completions', {'model': 'pool/pool-model', 'messages': turns})
            assert status == 200, status
        home = pool_seen[0][0]
        check(len(pool_seen) == 6 and all(auth == home for auth, _ in pool_seen), 'every turn of one conversation stays on one credential')
        pool_seen.clear()
        separate = {}
        for n in range(6):
            status, _ = call('/v1/chat/completions', {'model': 'pool/pool-model', 'messages': [{'role': 'user', 'content': 'Separate conversation %d' % n}]})
            assert status == 200, status
            separate[n] = pool_seen[-1][0]
        check(set(separate.values()) == {'Bearer pool-key-1', 'Bearer pool-key-2'}, 'new conversations are spread over both credentials')
        neighbour = next(n for n, auth in separate.items() if auth == home)

        def turn(messages, text, stream=False):
            pool_seen.clear()
            history = messages + [{'role': 'assistant', 'content': 'OK'}, {'role': 'user', 'content': text}]
            status, body = call('/v1/chat/completions', {'model': 'pool/pool-model', 'messages': history, 'stream': stream})
            return status, body, [auth for auth, _ in pool_seen]

        # A transient 5xx before any output: that request fails over silently.
        pool_failures[home] = 1
        status, text, served = turn(conversation, 'after overload', stream=True)
        check(status == 200 and '[DONE]' in text and 'error' not in text, 'a stream failing before its first byte is retried silently')
        check(len(served) >= 2 and served[0] == home and served[-1] != home, 'the retry is served by the other credential')
        rescuer = served[-1]
        # The cooldown is persisted next to the accounts, and BridgeDock's "立即解除冷却" clears it.
        def pool_cooldowns():
            found = {}
            for path in (scratch / 'accounts').glob('*.cds'):
                document = json.loads(path.read_text())
                if 'pool' in document.get('auth_id', ''):
                    found[document['auth_id']] = [r for r in document.get('records', []) if r.get('status') == 'cooling']
            return found
        cooling = {key: value for key, value in pool_cooldowns().items() if value}
        check(len(cooling) == 1 and all(r.get('next_retry_after') and r.get('last_error', {}).get('http_status') == 503
                                        for r in next(iter(cooling.values()))),
              'the failed credential\'s cooldown is saved with its end time and cause')
        # "立即解除冷却" resets a subscription account by its auth index. The account here is disabled,
        # so the core never contacts Kiro with its placeholder token.
        status, text = call('/v8/management/credentials', key='management-test-key')
        offline = [r for r in json.loads(text).get('files', []) if r.get('name') == 'kiro-offline.json']
        check(status == 200 and len(offline) == 1 and offline[0].get('auth_index'), 'subscription accounts are listed with the auth index the reset needs')
        status, text = call('/v8/management/routing/cooldown/reset', {'auth_index': offline[0]['auth_index']}, key='management-test-key', method='POST')
        check(status == 200 and json.loads(text).get('status') == 'ok', 'the core accepts a cooldown reset for an account')
        status, _ = call('/v8/management/routing/cooldown/reset', {'auth_index': 'ffffffffffffffff'}, key='management-test-key', method='POST')
        check(status == 404, 'a reset for an unknown account is refused')
        # The conversation continues where its context was last sent, without bouncing back and forth.
        followups = [turn(conversation, 'next turn %d' % n)[2] for n in range(3)]
        check(all(s and s[-1] == rescuer for s in followups), 'after a failover the conversation stays on one credential')
        # Other conversations on the resting credential are not dragged along once its short rest is over.
        time.sleep(2.5)
        status, _, served = turn([{'role': 'user', 'content': 'Separate conversation %d' % neighbour}], 'follow-up')
        check(status == 200 and served == [home], 'a transient error does not move the credential\'s other conversations')
        # A long silence mid-stream is bridged by SSE comment heartbeats; the content still arrives intact.
        status, text = call('/v1/chat/completions', {'model': 'pool/slow-model', 'messages': [{'role': 'user', 'content': 'think slowly'}], 'stream': True})
        lines = text.splitlines()
        check(status == 200 and any(line.startswith(':') for line in lines), 'heartbeats are sent during a silent stretch')
        check('[DONE]' in text and text.count('chat.completion.chunk') >= 4, 'the slow stream is delivered complete')
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
