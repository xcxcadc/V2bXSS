#!/usr/bin/env python3
"""Check terminal rendering and real wizard input without network/services."""
import errno
import json
import os
import pathlib
import pty
import select
import signal
import subprocess
import tempfile
import time
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
    def menu_interrupt(self, action="", prompt="请选择 [0-13]：", state="inactive", autostart="enabled"):
        """Send an actual terminal Ctrl+C; never install or manage host services."""
        with tempfile.TemporaryDirectory() as directory:
            directory = pathlib.Path(directory)
            for name, body in {
                "uname": "echo Darwin",
                "systemctl": (
                    'case "$1" in\n'
                    f'is-active) echo {state}; exit 3 ;;\n'
                    f'is-enabled) echo {autostart} ;;\n'
                    'status) echo fixture-status ;;\n'
                    '*) exit 99 ;;\nesac'
                ),
                "journalctl": 'echo fixture-live-log; sleep 60',
            }.items():
                target = directory / name
                target.write_text(f"#!/bin/sh\n{body}\n")
                target.chmod(0o755)
            pid, master = pty.fork()
            if pid == 0:
                os.environ["PATH"] = f"{directory}:{os.environ['PATH']}"
                os.execvp("bash", ["bash", str(ROOT / "install.sh")])
            output = b""
            status = None
            try:
                def wait_for(text):
                    nonlocal output
                    deadline = time.monotonic() + 10
                    while text.encode() not in output:
                        if time.monotonic() >= deadline:
                            self.fail(f"terminal did not show {text!r}: {output.decode(errors='replace')}")
                        if select.select([master], [], [], 0.1)[0]:
                            output += os.read(master, 8192)

                wait_for("请选择 [0-13]：")
                if action:
                    os.write(master, (action + "\n").encode())
                    wait_for(prompt)
                # Bash prints read's prompt before finishing terminal setup.
                # Model a key press once it is waiting, not during tcsetattr.
                time.sleep(0.1)
                os.write(master, b"\x03")
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    ended, status = os.waitpid(pid, os.WNOHANG)
                    if ended:
                        break
                    status = None
                    if select.select([master], [], [], 0.1)[0]:
                        try:
                            output += os.read(master, 8192)
                        except OSError as error:
                            if error.errno != errno.EIO:
                                raise
                self.assertIsNotNone(status, f"Ctrl+C did not exit the manager: {output.decode(errors='replace')}")
                self.assertEqual(os.waitstatus_to_exitcode(status), 130, output.decode(errors="replace"))
                return output.decode(errors="replace")
            finally:
                if status is None:
                    os.killpg(pid, signal.SIGKILL)
                    os.waitpid(pid, 0)
                os.close(master)

    def test_status_labels_and_ctrl_c_at_menu(self):
        output = self.menu_interrupt()
        self.assertIn("运行状态：已停止 ｜ 开机自启：已开启", output)
        self.assertNotIn("运行状态：inactive", output)

    def test_ctrl_c_after_action(self):
        output = self.menu_interrupt("7", "按回车返回主菜单：", "active", "disabled")
        self.assertIn("运行状态：运行中 ｜ 开机自启：已关闭", output)

    def test_ctrl_c_during_live_logs(self):
        self.menu_interrupt("8", "fixture-live-log")

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
