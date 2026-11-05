"""Exercise the real bundled core and Swift gateway using a loopback Work upstream."""
import json, pathlib, socket, subprocess, sys, tempfile, threading, time, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

seen = []
class Upstream(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        seen.append((dict(self.headers), body))
        response = {'id': 'chatcmpl-work-test', 'object': 'chat.completion', 'created': 1, 'model': 'k3d1-agent',
                    'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': 'WORK_OK'}, 'finish_reason': 'stop'}],
                    'usage': {'prompt_tokens': 2, 'completion_tokens': 2, 'total_tokens': 4}}
        if body.get('stream'):
            chunks = [{'id': response['id'], 'object': 'chat.completion.chunk', 'created': 1, 'model': 'k3d1-agent',
                       'choices': [{'index': 0, 'delta': {'role': 'assistant', 'content': 'WORK_OK'}, 'finish_reason': None}]},
                      {'id': response['id'], 'object': 'chat.completion.chunk', 'created': 1, 'model': 'k3d1-agent',
                       'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}], 'usage': response['usage']}]
            data = ''.join('data: '+json.dumps(c)+'\n\n' for c in chunks).encode()+b'data: [DONE]\n\n'
        else: data = json.dumps(response).encode()
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream' if body.get('stream') else 'application/json')
        self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)

def free_port():
    with socket.socket() as sock: sock.bind(('127.0.0.1', 0)); return sock.getsockname()[1]

def request(port, path, payload=None, headers=None):
    headers = {'Authorization': 'Bearer work-public-test', 'Content-Type': 'application/json', **(headers or {})}
    req = urllib.request.Request(f'http://127.0.0.1:{port}{path}', data=None if payload is None else json.dumps(payload).encode(), headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as r: return r.status, r.read()
    except urllib.error.HTTPError as e: return e.code, e.read()

core_binary = str(pathlib.Path(sys.argv[2]).resolve())
upstream = ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
threading.Thread(target=upstream.serve_forever, daemon=True).start()
core_port, gateway_port = free_port(), free_port()
with tempfile.TemporaryDirectory(prefix='work-proxy-test-') as scratch:
    config = {'config-version': 8, 'server': {'host': '127.0.0.1', 'port': core_port},
              'management': {'secret-key': 'work-test-management', 'disable-control-panel': True, 'disable-auto-update-panel': True},
              'access': {'api-keys': ['work-core-test']}, 'oauth': {'auth-dir': scratch+'/accounts'},
              'routing': {'force-model-prefix': True}, 'plugins': {'enabled': False},
              'api-keys': {'openai-compatibility': [{'name': 'work-test', 'prefix': 'work', 'base-url': f'http://127.0.0.1:{upstream.server_port}/v1',
                            'keys': [{'api-key': 'synthetic-upstream-key'}], 'models': [{'name': 'k3d1-agent', 'alias': 'kimi-k3.1-pro', 'thinking': {'levels': ['low', 'high', 'max']}}],
                            'headers': {'X-Kimi-Model-Speed': '$X-Kimi-Model-Speed', 'X-Kimi-Context-Length': '$X-Kimi-Context-Length'}}]}}
    path = pathlib.Path(scratch)/'config.json';path.write_text(json.dumps(config))
    log = open(pathlib.Path(scratch)/'core.log','w+')
    core = subprocess.Popen([core_binary, '-config', str(path), '-local-model'], cwd=scratch, stdout=log, stderr=log)
    gateway = subprocess.Popen([sys.argv[1], str(gateway_port), str(core_port)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        for _ in range(80):
            try:
                status, data = request(core_port, '/v1/models', headers={'Authorization': 'Bearer work-core-test'})
                if status == 200: break
            except OSError: pass
            time.sleep(.1)
        else: log.seek(0);raise AssertionError(log.read())
        for _ in range(80):
            try:
                status, data = request(gateway_port, '/v1/models')
                if status == 200: break
            except OSError: pass
            time.sleep(.1)
        else: raise AssertionError('gateway did not start')
        catalog = json.loads(data)['data'];assert catalog[0]['display_name'] == 'K3.1 Pro'
        params = json.dumps([{'id':'fast','value':'true'},{'id':'context','value':'1000000'},{'id':'reasoning','value':'max'}])
        for route in ['chat/completions','responses','messages']:
            for stream in [False, True]:
                payload = {'model':'Work/kimi-k3.1-pro','stream':stream,'max_tokens':64}
                if route == 'responses': payload['input'] = 'Say WORK_OK'
                else: payload['messages'] = [{'role':'user','content':'Say WORK_OK'}]
                status, data = request(gateway_port, '/v1/'+route, payload, {'X-BridgeDock-Parameters':params})
                assert status == 200 and b'WORK_OK' in data, (route, stream, status, data[:600])
                headers, body = seen[-1];headers = {k.lower():v for k,v in headers.items()}
                assert headers['x-kimi-model-speed'] == 'fast' and headers['x-kimi-context-length'] == '1000000', headers
                assert body['model'] == 'k3d1-agent' and headers['authorization'] == 'Bearer synthetic-upstream-key'
                assert body.get('reasoning_effort') == 'max', (route, body)
                assert 'x-bridgedock-parameters' not in headers
                print('PASS',route,'stream' if stream else 'non-stream','Fast/context/reasoning reached upstream')
        status, data = request(gateway_port, '/v1/chat/completions', {'model':'Work/kimi-k3.1-pro','messages':[{'role':'user','content':'OK'}]})
        headers = {k.lower():v for k,v in seen[-1][0].items()}
        assert status == 200 and headers['x-kimi-model-speed'] == 'standard' and headers['x-kimi-context-length'] == '262144'
        count=len(seen)
        status, _ = request(gateway_port, '/v1/chat/completions', {'model':'Work/kimi-k3.1-pro','messages':[]}, {'X-Kimi-Model-Speed':'turbo'})
        assert status == 400 and len(seen) == count
        print('PASS defaults and invalid speed blocked before upstream')
    finally:
        gateway.terminate(); core.terminate();gateway.wait(timeout=10);core.wait(timeout=10);upstream.shutdown();log.close()
