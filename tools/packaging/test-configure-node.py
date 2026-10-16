#!/usr/bin/env python3
"""Configuration tests: preserve secrets/options and reject ambiguous input."""
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("configure", pathlib.Path(__file__).with_name("configure-node.py"))
configure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(configure)


def sample():
    return {"Log": {"Level": "info"}, "Cores": [{"Type": "hysteria2"}], "Nodes": [{
        "ApiConfig": {"ApiHost": "https://panel.example", "ApiKey": "fixture-secret", "NodeID": 1, "NodeType": "hysteria2"},
        "Options": {"Core": "hysteria2", "Obfs": {"Password": "fixture-obfs"}, "UnknownCustomOption": [1, 2]},
    }]}


class ConfigurationTests(unittest.TestCase):
    def test_import_roundtrip_preserves_every_option(self):
        with tempfile.TemporaryDirectory() as directory:
            source, target = pathlib.Path(directory) / "source.json", pathlib.Path(directory) / "target.json"
            data = sample()
            source.write_text(json.dumps(data), encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()) as output:
                configure.write_new(target, configure.read_config(source))
            self.assertEqual(json.loads(target.read_text()), data)
            self.assertNotIn("fixture-secret", output.getvalue())
            self.assertNotIn("fixture-obfs", output.getvalue())
            if os.name != "nt":
                self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                configure.write_new(target, data)

    def test_all_supported_node_types_generate_valid_config(self):
        with tempfile.TemporaryDirectory() as directory:
            cert, key = pathlib.Path(directory) / "cert.pem", pathlib.Path(directory) / "key.pem"
            cert.touch()
            key.touch()
            for kind, cores in configure.NODE_CORES.items():
                for core in cores:
                    with self.subTest(kind=kind, core=core):
                        data = {"Cores": [], "Nodes": []}
                        answers = ["https://panel.example", "fixture-secret", kind, "2", core]
                        if kind in ("vmess", "vless", "shadowsocks"):
                            answers += ["3"]
                        else:
                            answers += ["1", "node.example", str(cert), str(key)]
                        with patch.object(configure, "ask", side_effect=answers), contextlib.redirect_stdout(io.StringIO()):
                            configure.build_node(data)
                        configure.validate(data)
                        self.assertEqual(data["Nodes"][0]["Options"]["Core"], core)

    def test_append_preserves_existing_nodes_and_named_core(self):
        data = sample()
        original = json.loads(json.dumps(data["Nodes"][0]))
        data["Cores"][0]["Name"] = "existing-hy2"
        data["Nodes"][0]["Options"]["CoreName"] = "existing-hy2"
        original["Options"]["CoreName"] = "existing-hy2"
        answers = ["https://panel.example", "new-secret", "hysteria2", "2", "hysteria2", "2", "node.example", "operator@example.invalid"]
        with patch.object(configure, "ask", side_effect=answers), contextlib.redirect_stdout(io.StringIO()):
            configure.build_node(data)
        self.assertEqual(data["Nodes"][0], original)
        self.assertEqual(data["Nodes"][1]["Options"]["CoreName"], "existing-hy2")
        self.assertEqual(len(data["Cores"]), 1)

    def test_duplicates_include_hy2_api_alias(self):
        data = sample()
        other = json.loads(json.dumps(data["Nodes"][0]))
        other["ApiConfig"]["NodeType"] = "hysteria"
        other["Options"]["Core"] = "sing"
        data["Cores"].append({"Type": "sing"})
        data["Nodes"].append(other)
        with self.assertRaisesRegex(ValueError, "重复"):
            configure.validate(data)

    def test_bad_json_errors_never_include_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory) / "bad.json"
            source.write_text('{"ApiKey":"sensitive-test-secret", BAD}', encoding="utf-8")
            with self.assertRaises(ValueError) as caught:
                configure.read_config(source)
            self.assertNotIn("sensitive-test-secret", str(caught.exception))

    def test_validation_rejects_missing_fields_and_wrong_core(self):
        mutations = [lambda d: d.update(Nodes=[]), lambda d: d["Nodes"][0]["ApiConfig"].update(NodeID=True),
                     lambda d: d["Nodes"][0]["ApiConfig"].update(ApiKey=""),
                     lambda d: d["Nodes"][0]["Options"].update(Core="xray"),
                     lambda d: d["Nodes"][0].update(Include="https://file.example/config")]
        for mutation in mutations:
            data = sample()
            mutation(data)
            with self.assertRaises(ValueError):
                configure.validate(data)

    def test_panel_url_rejects_credentials_queries_and_other_schemes(self):
        for value in ("https://user:password@panel.example", "file:///etc/config", "https://panel.example?token=secret", "https://panel.example/#admin"):
            with self.assertRaises(ValueError):
                configure.panel_url(value)

    def test_toolchain_selection_checks_patch_and_uses_official_filename(self):
        self.assertTrue(configure.go_compatible("go1.26.5", "1.25"))
        self.assertFalse(configure.go_compatible("go1.26.5", "1.26.6"))
        self.assertFalse(configure.go_compatible("go1.27rc1", "1.25"))
        with tempfile.TemporaryDirectory() as directory:
            metadata = pathlib.Path(directory) / "downloads.json"
            releases = [{"version": "go1.26.5", "stable": True, "files": [{"os": "linux", "arch": "amd64", "kind": "archive", "filename": "go1.26.5.linux-amd64.tar.gz", "sha256": "a" * 64}]}]
            metadata.write_text(json.dumps(releases), encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()) as output:
                configure.go_download(metadata, "amd64", "1.25")
            self.assertEqual(output.getvalue().strip().split(), ["go1.26.5", "go1.26.5.linux-amd64.tar.gz", "a" * 64])
            with self.assertRaises(ValueError):
                configure.go_download(metadata, "arm64", "1.25")


if __name__ == "__main__":
    unittest.main()
