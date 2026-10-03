#!/usr/bin/env python3
"""A local OpenAI-compatible endpoint that streams fixed demo answers.

The demo config points QDuo at it (provider "ollama", no key), so the real popup
and result panel run end to end without a real model: same request, same SSE
stream, same rendering — only the words are scripted. The action's system prompt
is "DEMO:<name>"; that name picks the answer.
"""
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
ANSWERS = {
    'translate': '好的想法，很少一出现就是完整的；给它们一点空间，它们自然会长大。',
    'polish': '这个工具让写作更快一步，也省去了在窗口之间来回切换。',
    'write': '本周五，新版本正式上线。\n\n这次带来水玻璃、3D 玻璃和胶囊三种弹窗风格：选中文字，下一步就在手边。\n\n欢迎升级体验，也期待听到你的反馈。',
    'explain': '一句提醒：给新想法留出位置。',
    'summarize': '留白，让好想法出现。',
    'toEnglish': 'Make room for better ideas.',
}
CHAR_DELAY = float(sys.argv[2]) if len(sys.argv) > 2 else 0.03

class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        system = next((m['content'] for m in body['messages'] if m['role'] == 'system'), '')
        key = system.split('DEMO:')[-1].strip() if 'DEMO:' in system else ''
        text = ANSWERS.get(key, '（演示）')
        sys.stderr.write(f'{time.time():.3f} request {key}\n')
        if not body.get('stream'):
            out = json.dumps({'choices': [{'message': {'role': 'assistant', 'content': text}}]}).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(out))); self.end_headers(); self.wfile.write(out); return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream'); self.send_header('Transfer-Encoding', 'chunked'); self.end_headers()
        def send(s):
            b = s.encode(); self.wfile.write(b'%x\r\n%s\r\n' % (len(b), b)); self.wfile.flush()
        time.sleep(0.12)  # a model's first-token latency, kept short
        for ch in text:
            send('data: ' + json.dumps({'choices': [{'delta': {'content': ch}}]}, ensure_ascii=False) + '\n\n')
            time.sleep(CHAR_DELAY)
        send('data: [DONE]\n\n'); self.wfile.write(b'0\r\n\r\n'); self.wfile.flush()

ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1]) if len(sys.argv) > 1 else 11555), H).serve_forever()
