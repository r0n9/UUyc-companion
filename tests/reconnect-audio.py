import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("reconnect_audio", Path(__file__).parents[1] / "scripts/reconnect-audio.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def status(ids):
    return {"success": True, "data": {"connections": [{"deviceId": item} for item in ids],
                                      "total": len(ids), "hasActiveConnections": bool(ids)}}


class ReconnectTests(unittest.TestCase):
    def test_waits_for_asynchronous_disconnect_and_preserves_other_connections(self):
        replies = iter([status(["target", "other"]), status(["target", "other"]), status(["other"])])
        calls = []
        current = [100.0]

        def call(cli, arguments, timeout):
            calls.append(arguments)
            return next(replies) if arguments == ["device", "status"] else {"success": True}

        module.reconnect("cli", "target", call, lambda: current[0], lambda seconds: current.__setitem__(0, current[0] + seconds))
        self.assertEqual(calls, [["device", "status"], ["device", "disconnect", "target"],
                                 ["device", "status"], ["device", "status"], ["device", "connect", "target"]])
        self.assertAlmostEqual(current[0], 100.3)

    def test_never_connects_when_disconnect_times_out(self):
        calls = []
        current = [0.0]

        def call(cli, arguments, timeout):
            calls.append(arguments)
            return status(["target"])

        with self.assertRaises(module.ReconnectError):
            module.reconnect("cli", "target", call, lambda: current[0], lambda seconds: current.__setitem__(0, current[0] + seconds))
        self.assertNotIn(["device", "connect", "target"], calls)
        self.assertEqual(current[0], 10)

    def test_unknown_status_does_not_mean_disconnected(self):
        for reply in [{"data": {}}, {"data": {"connections": [], "total": 0, "hasActiveConnections": True}},
                      {"data": {"connections": [{"id": "target"}], "total": 1, "hasActiveConnections": True}}]:
            with self.subTest(reply=reply), self.assertRaises(module.ReconnectError):
                module.connected_ids(reply)

    def test_already_disconnected_does_not_disconnect_any_device(self):
        calls = []

        def call(cli, arguments, timeout):
            calls.append(arguments)
            return status([])

        with self.assertRaises(module.ReconnectError):
            module.reconnect("cli", "target", call)
        self.assertEqual(calls, [["device", "status"]])


if __name__ == "__main__":
    unittest.main()
