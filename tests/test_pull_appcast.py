import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools" / "pull_appcast.py"
RSS = b'<?xml version="1.0"?><rss><channel /></rss>'


class AppcastHandler(BaseHTTPRequestHandler):
    user_agent = None

    def do_GET(self):
        type(self).user_agent = self.headers.get("User-Agent")
        if type(self).user_agent != "Kikishima-release/1.0":
            self.send_response(403)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/xml")
        self.end_headers()
        self.wfile.write(RSS)

    def log_message(self, *_args):
        pass


class PullAppcastTest(unittest.TestCase):
    def test_uses_custom_user_agent_and_saves_rss(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), AppcastHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "appcast.xml"
            result = subprocess.run(
                [sys.executable, str(SCRIPT), f"http://127.0.0.1:{server.server_port}/appcast.xml", str(output)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(AppcastHandler.user_agent, "Kikishima-release/1.0")
            self.assertEqual(output.read_bytes(), RSS)


if __name__ == "__main__":
    unittest.main()
