import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVICE_NAME = "python-app"
PORT = int(os.environ.get("PORT", 5000))


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            body = json.dumps({"status": "ok", "service": SERVICE_NAME}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
            return

        body = f"Hello from {SERVICE_NAME} (project-9 CD stack)\n".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    print(f"{SERVICE_NAME} listening on :{PORT}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
