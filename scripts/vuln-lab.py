#!/usr/bin/env python3
"""
Deliberately vulnerable HTTP server for testing dodexabash security toolkit.
Run: python3 scripts/vuln-lab.py
Then: sec report localhost:8888
"""

from http.server import HTTPServer, BaseHTTPRequestHandler
import urllib.parse
import json
import sys

class VulnerableHandler(BaseHTTPRequestHandler):
    """Intentionally vulnerable for security testing. DO NOT deploy."""

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)

        # Reflected XSS — no input sanitization
        if parsed.path == '/search':
            query = params.get('q', [''])[0]
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            # Missing security headers (intentional)
            self.end_headers()
            # XSS: directly embedding user input
            self.wfile.write(f'<html><body>Results for: {query}</body></html>'.encode())
            return

        # Open redirect
        if parsed.path == '/redirect':
            url = params.get('url', ['/'])[0]
            self.send_response(302)
            self.send_header('Location', url)  # No validation
            self.end_headers()
            return

        # Directory listing
        if parsed.path == '/files/':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(b'<html><body><h1>Index of /files/</h1><a href="secret.txt">secret.txt</a></body></html>')
            return

        # Exposed config
        if parsed.path == '/.env':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'DB_PASSWORD=hunter2\nAPI_KEY=sk-test-12345\nSECRET=supersecret\n')
            return

        if parsed.path == '/.git/config':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'[core]\n\trepositoryformatversion = 0\n[remote "origin"]\n\turl = https://github.com/test/repo.git\n')
            return

        # Server info leakage
        if parsed.path == '/':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Server', 'Apache/2.4.49')  # Known vulnerable version
            self.send_header('X-Powered-By', 'PHP/7.4.3')
            # No security headers
            self.end_headers()
            self.wfile.write(b'''<html><head><title>Vuln Lab</title></head><body>
<h1>dodexabash Vulnerability Lab</h1>
<p>This server is intentionally vulnerable for security testing.</p>
<ul>
<li><a href="/search?q=test">Search (XSS)</a></li>
<li><a href="/redirect?url=https://evil.com">Redirect (Open Redirect)</a></li>
<li><a href="/files/">Files (Directory Listing)</a></li>
<li><a href="/.env">Config (Exposed .env)</a></li>
</ul>
</body></html>''')
            return

        # Default 404
        self.send_response(404)
        self.end_headers()

    def do_PUT(self):
        # Accepting PUT (dangerous methods)
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.end_headers()
        self.wfile.write(b'PUT accepted\n')

    def do_DELETE(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.end_headers()
        self.wfile.write(b'DELETE accepted\n')

    def do_TRACE(self):
        self.send_response(200)
        self.send_header('Content-Type', 'message/http')
        self.end_headers()
        self.wfile.write(f'TRACE {self.path} HTTP/1.1\r\n'.encode())

    def log_message(self, format, *args):
        print(f"[vuln-lab] {args[0]}")

if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8888
    server = HTTPServer(('127.0.0.1', port), VulnerableHandler)
    print(f'Vuln Lab running on http://127.0.0.1:{port}')
    print('Test with: sec report localhost:{port}')
    print('Ctrl-C to stop')
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\nStopped.')
