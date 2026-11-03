import json
from pathlib import Path
import subprocess
import sys
import unittest
import server


class ProtocolTests(unittest.TestCase):
    def request(self, method, params=None):
        return {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}

    def test_handshake_discovery_notifications_and_unknown_methods(self):
        self.assertEqual(server.handle(self.request("initialize"), Path("/missing"))["result"]["protocolVersion"], server.PROTOCOL)
        tools = server.handle(self.request("tools/list"), Path("/missing"))["result"]["tools"]
        self.assertEqual(len(tools), len({tool["name"] for tool in tools}))
        self.assertGreaterEqual(len(tools), 16)
        self.assertIsNone(server.handle({"jsonrpc": "2.0", "method": "notifications/initialized"}, Path("/missing")))
        self.assertEqual(server.handle(self.request("bad"), Path("/missing"))["error"]["code"], -32601)

    def test_validation_and_unavailable_app_are_distinct(self):
        invalid = self.request("tools/call", {"name": "dogsc_lut", "arguments": {"action": "configure", "intensity": True}})
        self.assertEqual(server.handle(invalid, Path("/missing"))["error"]["code"], -32602)
        unavailable = self.request("tools/call", {"name": "dogsc_status"})
        self.assertTrue(server.handle(unavailable, Path("/missing"))["result"]["isError"])

    def test_stdio_is_only_json_and_recovers_after_parse_error(self):
        process = subprocess.run([sys.executable, str(Path(server.__file__))], input='bad\n' + json.dumps(self.request("ping")) + '\n', text=True, capture_output=True, check=True)
        lines = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertEqual(lines[0]["error"]["code"], -32700)
        self.assertEqual(lines[1]["result"], {})


if __name__ == "__main__":
    unittest.main()
