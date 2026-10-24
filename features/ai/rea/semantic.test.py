import gzip
import http.server
import json
import platform
import queue
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

COMMAND = sys.argv.pop(1)
BROWSER = sys.argv.pop(1)
ELF = sys.argv.pop(1)
WAKARU_VERSION = sys.argv.pop(1)


def native_record(value):
    if isinstance(value, dict):
        payload = b"".join(
            native_record(key) + native_record(child) for key, child in value.items()
        )
        marker = b"}"
    elif isinstance(value, str):
        payload, marker = value.encode(), b";"
    elif isinstance(value, bytes):
        payload, marker = value, b","
    else:
        payload, marker = str(value).encode(), b"#"
    return str(len(payload)).encode() + b":" + payload + marker


def values(value, key):
    found = []
    if isinstance(value, dict):
        if key in value:
            found.append(value[key])
        for child in value.values():
            found.extend(values(child, key))
    if isinstance(value, list):
        for child in value:
            found.extend(values(child, key))
    return found


class ToolTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        environment = {
            "HOME": str(self.root),
            "USERPROFILE": str(self.root),
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "PATH": "",
            "REA_LOG_LEVEL": "silent",
        }
        self.process = subprocess.Popen(
            [COMMAND, "mcp"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
            cwd=self.root,
        )
        self.addCleanup(self.close)
        self.messages = queue.Queue()

        def read():
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
            self.messages.put(None)

        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()
        self.sequence = 0
        self.request(
            "initialize",
            {
                "protocolVersion": "2025-11-25",
                "capabilities": {},
                "clientInfo": {"name": "rea-nix-test", "version": "1"},
            },
        )
        self.process.stdin.write(
            json.dumps(
                {
                    "jsonrpc": "2.0",
                    "method": "notifications/initialized",
                }
            )
            + "\n"
        )
        self.process.stdin.flush()

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=15)
        self.reader.join(timeout=15)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()

    def request(self, method, params):
        self.sequence += 1
        self.process.stdin.write(
            json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": self.sequence,
                    "method": method,
                    "params": params,
                }
            )
            + "\n"
        )
        self.process.stdin.flush()
        while True:
            message = self.messages.get(timeout=180)
            self.assertIsNotNone(message, "REA closed its MCP stream")
            if message.get("id") == self.sequence:
                self.assertNotIn("error", message, message)
                return message["result"]

    def tool(self, name, arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        self.assertFalse(result.get("isError", False), json.dumps(result))
        return result.get("structuredContent") or json.loads(
            result["content"][0]["text"]
        )

    def test_wireshark(self):
        result = self.tool("inspect_pcap_client", {})
        self.assertIn("Wireshark", json.dumps(result))
        if platform.system() != "Linux":
            return
        packet = bytes.fromhex(
            "00112233445566778899aabb0800"
            "4500001c00000000401100007f0000017f000001"
            "04d2162e00080000"
        )
        capture = self.root / "one.pcap"
        capture.write_bytes(
            struct.pack("<IHHIIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1)
            + struct.pack("<IIII", 1, 0, len(packet), len(packet))
            + packet
        )
        result = self.tool("inspect_pcap_capture", {"path": str(capture)})
        self.assertIn(1, values(result, "packet_count"))

    @unittest.skipUnless(platform.system() == "Linux", "REA GDB integration uses /proc")
    def test_gdb(self):
        session = self.tool("start_gdb_session", {})
        session_id = values(session, "session_id")[0]
        result = self.tool("gdb_session_status", {"session_id": session_id})
        self.assertEqual(values(result, "state"), ["ready"])
        self.tool("close_gdb_session", {"session_id": session_id})

    @unittest.skipUnless(
        platform.system() == "Linux", "REA firmware engines use prlimit"
    )
    def test_firmware(self):
        firmware = self.root / "firmware.gz"
        firmware.write_bytes(
            gzip.compress(b"REA packaged firmware fixture\n" * 64, mtime=0)
        )
        inspected = self.tool("inspect_firmware_regions", {"path": str(firmware)})
        self.assertIn("gzip", json.dumps(inspected).lower())
        extracted = self.tool(
            "extract_firmware",
            {
                "path": str(firmware),
                "output_directory": str(self.root / "extracted"),
            },
        )
        self.assertIn("unblob", json.dumps(extracted).lower())
        published = [
            p.read_bytes() for p in (self.root / "extracted").rglob("*") if p.is_file()
        ]
        self.assertIn(b"REA packaged firmware fixture\n" * 64, published)

    @unittest.skipUnless(
        platform.system() == "Linux", "REA native mitmproxy decoding supports Linux"
    )
    def test_mitmproxy(self):
        capture = self.root / "native.mitm"
        capture.write_bytes(
            native_record(
                {
                    "request": {"method": b"GET", "path": b"/rea"},
                    "response": {"status_code": 200},
                }
            )
        )
        result = self.tool(
            "inspect_web_network_capture",
            {
                "capture_path": str(capture),
                "format": "mitmproxy",
            },
        )
        self.assertIn(1, values(result, "total_records"))
        self.assertIn("mitmproxy-native-tnetstring", values(result, "id"))
        self.assertEqual(
            values(result, "reported"),
            [
                None,
                {
                    "request": {"method": "GET", "path": "/rea"},
                    "response": {"status_code": 200},
                },
            ],
        )
        self.assertRegex(values(result, "decoder")[0]["version"], r"^\d+\.")

    @unittest.skipUnless(
        platform.system() == "Linux" and platform.machine() == "x86_64",
        "REA pwntools and Wakaru integrations support Linux x64",
    )
    def test_pwntools_and_wakaru(self):
        layout = self.tool("inspect_binary_layout", {"path": ELF})
        self.assertIn("elf", json.dumps(layout).lower())
        self.assertIn("Observed Python packages:", json.dumps(layout))
        self.assertRegex(
            values(layout, "provider")[0]["version"],
            r"^pwntools@[^;]+;pyelftools@[^;]+;unicorn@[^;]+$",
        )
        source = self.root / "input.js"
        source.write_text(
            "function greeting(){return 'hello';} console.log(greeting());\n"
        )
        recovered = self.tool(
            "recover_javascript_sources",
            {
                "path": str(source),
                "output_directory": str(self.root / "recovered"),
            },
        )
        self.assertIn(WAKARU_VERSION, values(recovered, "version"))
        self.assertTrue(any((self.root / "recovered").rglob("*.js")))

    def test_browser(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = b"<!doctype html><title>REA fixture</title><h1>Packaged Chromium</h1>"
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        result = self.tool(
            "capture_browser_scenario",
            {
                "browser": {"mode": "launch", "executable_path": BROWSER},
                "start_url": {"url": f"http://127.0.0.1:{server.server_port}/"},
                "actions": [
                    {"step_id": "ready", "action": "wait_for_timeout", "duration_ms": 1}
                ],
                "capture": {"at_end": ["dom"]},
            },
        )
        self.assertIn("Packaged Chromium", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
