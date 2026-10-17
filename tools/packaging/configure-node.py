#!/usr/bin/env python3
"""Interactive configuration for the fork installer; no network or credentials log."""
import argparse
import copy
import getpass
import json
import os
import pathlib
import re
import sys
from urllib.parse import urlsplit


NODE_CORES = {
    "vmess": ("xray", "sing"), "vless": ("xray", "sing"),
    "trojan": ("xray", "sing"), "shadowsocks": ("xray", "sing"),
    "hysteria2": ("hysteria2", "sing"), "hysteria": ("sing",),
    "tuic": ("sing",), "anytls": ("sing",),
}


def version(value):
    match = re.fullmatch(r"(?:go)?(\d+)\.(\d+)(?:\.(\d+))?", value)
    return tuple(int(part or 0) for part in match.groups()) if match else (0, 0, 0)


def go_compatible(current, required):
    return version(current) >= max(version(required), (1, 25, 0))


def go_download(metadata, arch, required):
    releases = json.loads(pathlib.Path(metadata).read_text(encoding="utf-8"))
    for release in sorted(releases, key=lambda item: version(item["version"]), reverse=True):
        name = release["version"]
        if not release.get("stable") or not go_compatible(name, required):
            continue
        for item in release["files"]:
            if (item.get("os") == "linux" and item.get("arch") == arch
                    and item.get("kind") == "archive"
                    and item.get("filename") == f"{name}.linux-{arch}.tar.gz"
                    and re.fullmatch(r"[a-f0-9]{64}", item.get("sha256", ""))):
                print(name, item["filename"], item["sha256"])
                return
    raise ValueError("未找到满足源码版本要求的 Go 官方 Linux 下载项")


def read_config(path):
    source = pathlib.Path(path)
    if source.is_symlink() or not source.is_file():
        raise ValueError("配置必须是已有的普通文件")
    # json5 custom configurations remain untouched during binary updates. The
    # wizard/import intentionally requires JSON so it can validate before write.
    try:
        config = json.loads(source.read_text(encoding="utf-8-sig"))
    except (UnicodeError, json.JSONDecodeError):
        raise ValueError("导入/追加向导需要标准 JSON；带注释的自定义配置可保留原文件直接更新程序") from None
    validate(config)
    return config


def api_of(node):
    return node.get("ApiConfig", node)


def options_of(node):
    return node.get("Options", node)


def panel_url(value):
    parsed = urlsplit(value)
    if (parsed.scheme not in ("https", "http") or not parsed.hostname
            or parsed.username or parsed.password or parsed.query or parsed.fragment):
        raise ValueError("面板地址需要是 http(s) 地址，不含账号、查询参数或 #")
    return value.rstrip("/")


def validate(config):
    if not isinstance(config, dict) or not isinstance(config.get("Cores"), list) or not config["Cores"]:
        raise ValueError("配置缺少 Cores 列表")
    if not isinstance(config.get("Nodes"), list) or not config["Nodes"]:
        raise ValueError("配置缺少 Nodes 列表")
    core_names = set()
    for core in config["Cores"]:
        if not isinstance(core, dict) or core.get("Type") not in ("xray", "sing", "hysteria2"):
            raise ValueError("配置包含当前构建不支持的内核")
        core_names.add(core.get("Name") or core["Type"])
    seen = set()
    for node in config["Nodes"]:
        if not isinstance(node, dict):
            raise ValueError("Nodes 每项必须是对象")
        if node.get("Include"):
            raise ValueError("向导不展开 Include 外部配置；请保留原配置直接更新程序")
        api, options = api_of(node), options_of(node)
        if not isinstance(api, dict) or not isinstance(options, dict):
            raise ValueError("ApiConfig / Options 必须是对象")
        host = panel_url(api.get("ApiHost", ""))
        kind = api.get("NodeType", "").lower()
        kind = "vmess" if kind == "v2ray" else kind
        node_id = api.get("NodeID")
        if kind not in NODE_CORES or type(node_id) is not int or node_id < 1 or not api.get("ApiKey"):
            raise ValueError("节点类型、节点 ID 或 API 密钥无效")
        core = options.get("Core", "")
        name = options.get("CoreName") or core
        if core not in NODE_CORES[kind] or name not in core_names:
            raise ValueError("节点类型与配置的内核不兼容")
        identity = (host.lower(), "hysteria" if kind == "hysteria2" else kind, node_id)
        if identity in seen:
            raise ValueError("配置包含重复的面板/类型/节点 ID")
        seen.add(identity)


def ask(prompt, default="", secret=False):
    label = f"{prompt}{' [' + default + ']' if default else ''}："
    while True:
        value = (getpass.getpass(label) if secret and sys.stdin.isatty() else input(label)).strip()
        value = value or default
        if value:
            return value
        print("此项不能为空。")


def build_node(config):
    host = panel_url(ask("面板 API 地址（不是订阅地址）"))
    key = ask("节点 API 密钥（输入不回显）", secret=True)
    kinds = list(NODE_CORES)
    print("节点类型：" + "  ".join(f"{i + 1}.{name}" for i, name in enumerate(kinds)))
    selection = ask("选择序号或类型", "5")
    kind = kinds[int(selection) - 1] if selection.isdigit() and 1 <= int(selection) <= len(kinds) else selection.lower()
    if kind not in NODE_CORES:
        raise ValueError("不支持的节点类型")
    node_id_text = ask("面板中的节点 ID")
    if not node_id_text.isdecimal() or int(node_id_text) < 1:
        raise ValueError("节点 ID 必须是正整数")
    node_id = int(node_id_text)
    core = ask("内核（" + "/".join(NODE_CORES[kind]) + "）", NODE_CORES[kind][0])
    if core not in NODE_CORES[kind]:
        raise ValueError("该节点类型不支持所选内核")
    name = core
    existing = next((item for item in config["Cores"] if item.get("Type") == core), None)
    if existing:
        name = existing.get("Name") or core
    else:
        config["Cores"].append({"Type": core})
    options = {"Core": core, "CoreName": name, "ListenIP": "0.0.0.0", "SendIP": "0.0.0.0"}
    if core == "sing":
        options["EnableSniff"] = True
    print("TLS：1.已有证书文件  2.自动申请 HTTP 证书（域名已解析，80 端口可用）  3.不配置 TLS（仅无 TLS / Reality 等场景）")
    tls_mode = ask("选择 TLS 方式", "1" if kind in ("trojan", "hysteria", "hysteria2", "tuic", "anytls") else "3")
    cert = {"CertMode": "none"}
    if tls_mode in ("1", "2"):
        domain = ask("节点证书域名").lower()
        if not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", domain):
            raise ValueError("证书域名格式无效")
        cert = {"CertMode": "file" if tls_mode == "1" else "http", "CertDomain": domain}
        if tls_mode == "1":
            for field, prompt in (("CertFile", "证书文件绝对路径"), ("KeyFile", "私钥文件绝对路径")):
                path = pathlib.Path(ask(prompt))
                if not path.is_absolute() or not path.is_file():
                    raise ValueError("证书和私钥必须是已存在的绝对路径")
                cert[field] = str(path)
        else:
            directory = pathlib.Path("/etc/v2bxss")
            cert.update(CertFile=str(directory / f"{core}-{node_id}.crt"),
                        KeyFile=str(directory / f"{core}-{node_id}.key"), Email=ask("证书申请邮箱"))
    elif tls_mode != "3" or kind in ("trojan", "hysteria", "hysteria2", "tuic", "anytls"):
        raise ValueError("所选节点类型需要 TLS，请使用证书文件或自动申请")
    options["CertConfig"] = cert
    config["Nodes"].append({
        "ApiConfig": {"ApiHost": host, "ApiKey": key, "NodeID": node_id, "NodeType": kind, "Timeout": 30,
                      "SecurityAuditCachePath": f"/etc/v2bxss/audit-{core}-{node_id}-{len(config['Nodes'])}.json"},
        "Options": options,
    })
    validate(config)


def write_new(path, config):
    validate(config)
    # The installer passes a new private staging path; never overwrite live config.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(config, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    print(f"已校验配置：{len(config['Nodes'])} 个节点（密钥不显示）。")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    compatible = sub.add_parser("go-compatible")
    compatible.add_argument("current")
    compatible.add_argument("required")
    download = sub.add_parser("go-download")
    download.add_argument("metadata")
    download.add_argument("arch", choices=("amd64", "arm64"))
    download.add_argument("required")
    wizard = sub.add_parser("wizard")
    wizard.add_argument("--existing")
    wizard.add_argument("--output", required=True)
    importer = sub.add_parser("import")
    importer.add_argument("--input", required=True)
    importer.add_argument("--output", required=True)
    args = parser.parse_args()
    if args.action == "go-compatible":
        return 0 if go_compatible(args.current, args.required) else 1
    if args.action == "go-download":
        go_download(args.metadata, args.arch, args.required)
        return 0
    if args.action == "import":
        config = read_config(args.input)
    else:
        config = copy.deepcopy(read_config(args.existing)) if args.existing else {"Log": {"Level": "info"}, "Cores": [], "Nodes": []}
        while True:
            build_node(config)
            if ask("继续添加另一个节点？y/N", "N").lower() != "y":
                break
    write_new(args.output, config)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, EOFError, KeyboardInterrupt) as error:
        # Never include JSON parse excerpts or entered credentials in errors.
        print("配置操作取消。" if isinstance(error, (EOFError, KeyboardInterrupt)) else f"配置检查失败：{error}", file=sys.stderr)
        sys.exit(1)
