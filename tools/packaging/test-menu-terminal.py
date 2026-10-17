#!/usr/bin/env python3
"""Check terminal rendering and real wizard input without network/services."""
import errno
import json
import os
import pathlib
import pty
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def terminal_run(command, answers):
    master, slave = pty.openpty()
    try:
        env = dict(os.environ)
        env.pop("NO_COLOR", None)
        result = subprocess.run(command, input=answers.encode(), stdout=slave, stderr=slave, env=env, timeout=15)
        os.close(slave)
        slave = None
        chunks = []
        while True:
            try:
                chunk = os.read(master, 8192)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            chunks.append(chunk)
        return result.returncode, b"".join(chunks).decode().replace("\r\n", "\n")
    finally:
        if slave is not None:
            os.close(slave)
        os.close(master)


class TerminalTests(unittest.TestCase):
    def test_main_menu_green_numbering(self):
        with tempfile.TemporaryDirectory() as directory:
            # Prevent manager self-install on the test host, regardless of UID.
            uname = pathlib.Path(directory) / "uname"
            uname.write_text("#!/bin/sh\necho Darwin\n")
            uname.chmod(0o755)
            result, output = terminal_run(["env", f"PATH={directory}:{os.environ['PATH']}", "bash", str(ROOT / "install.sh")], "0\n")
        self.assertEqual(result, 0, output)
        self.assertIn("\033[0;32m1.\033[0m 安装", output)
        self.assertIn("\n \033[0;32m11.\033[0m 添加", output)

    def test_wizard_real_input_retries_and_has_vertical_colored_submenus(self):
        with tempfile.TemporaryDirectory() as directory:
            target = pathlib.Path(directory) / "config.json"
            command = ["python3", str(ROOT / "tools/packaging/configure-node.py"), "wizard", "--output", str(target)]
            result, output = terminal_run(command, "bad-url\nhttps://panel.example\nfixture-private-key\n99\n1\nbad-id\n2\n1\n3\n2\n")
            self.assertEqual(result, 0, output)
            data = json.loads(target.read_text())
            self.assertEqual(data["Nodes"][0]["ApiConfig"]["NodeID"], 2)
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        self.assertNotIn("fixture-private-key", output)
        self.assertIn("\n \033[0;32m1.\033[0m vmess\n", output)
        self.assertIn("\n \033[0;32m2.\033[0m vless\n", output)
        for heading in ("选择节点协议", "选择运行内核", "证书 / TLS 配置", "节点信息已保存"):
            self.assertIn(heading, output)


if __name__ == "__main__":
    unittest.main()
