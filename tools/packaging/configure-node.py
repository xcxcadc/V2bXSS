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

MENU_CONFIG_VERSION = 2


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


def checked(prompt, check, default="", secret=False):
    while True:
        try:
            return check(ask(prompt, default, secret=secret))
        except ValueError as error:
            print(f"输入有误：{error}；请重新填写此项，之前的内容保留。")


def choose(title, choices, default="1"):
    """One choice per line, like the original manager; 0 cancels this wizard."""
    green = "\033[0;32m" if sys.stdout.isatty() and "NO_COLOR" not in os.environ else ""
    reset = "\033[0m" if green else ""
    print(f"\n---------- {title} ----------")
    for index, (value, label) in enumerate(choices, 1):
        print(f" {green}{index}.{reset} {label}")
    print(f" {green}0.{reset} 取消本次添加，返回管理菜单")
    while True:
        selection = ask("请选择", default).lower()
        if selection == "0":
            raise KeyboardInterrupt
        for index, (value, _) in enumerate(choices, 1):
            if selection in (str(index), value):
                return value
        print("无效选择，请输入上方的数字。")


def positive_id(value):
    if not value.isascii() or not value.isdecimal() or int(value) < 1:
        raise ValueError("节点 ID 必须是正整数")
    return int(value)


def cert_domain(value):
    value = value.lower()
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", value):
        raise ValueError("证书域名格式无效")
    return value


def cert_path(value):
    path = pathlib.Path(value)
    if not path.is_absolute() or not path.is_file():
        raise ValueError("证书和私钥必须是已存在的绝对路径")
    return str(path)


def build_node(config):
    host = checked("面板 API 地址（不是订阅地址）", panel_url)
    key = ask("节点 API 密钥（输入不回显）", secret=True)
    kinds = list(NODE_CORES)
    kind = choose("选择节点协议", [(kind, kind) for kind in kinds], "5")

    def unique_id(value):
        node_id = positive_id(value)
        for node in config["Nodes"]:
            api = api_of(node)
            existing_kind = api["NodeType"].lower()
            existing_kind = {"v2ray": "vmess", "hysteria2": "hysteria"}.get(existing_kind, existing_kind)
            current_kind = "hysteria" if kind == "hysteria2" else kind
            if panel_url(api["ApiHost"]).lower() == host.lower() and existing_kind == current_kind and api["NodeID"] == node_id:
                raise ValueError("此面板/协议/节点 ID 已存在，请填写新节点的 ID")
        return node_id

    node_id = checked("面板中的节点 ID", unique_id)
    core = choose("选择运行内核", [(core, {"sing": "sing-box", "xray": "Xray", "hysteria2": "Hysteria2"}[core]) for core in NODE_CORES[kind]])
    name = core
    existing = next((item for item in config["Cores"] if item.get("Type") == core), None)
    if existing:
        name = existing.get("Name") or core
    options = {"Core": core, "CoreName": name, "ListenIP": "0.0.0.0", "SendIP": "0.0.0.0"}
    if core == "sing":
        options["EnableSniff"] = True
    tls_required = kind in ("trojan", "hysteria", "hysteria2", "tuic", "anytls")
    tls_choices = [("file", "使用已有证书和私钥文件"), ("http", "自动申请 HTTP 证书（域名已解析，80 端口可用）")]
    if not tls_required:
        tls_choices.append(("none", "不配置 TLS（无 TLS / Reality 等场景）"))
    tls_mode = choose("证书 / TLS 配置", tls_choices, "1" if tls_required else "3")
    cert = {"CertMode": "none"}
    if tls_mode in ("file", "http"):
        domain = checked("节点证书域名", cert_domain)
        cert = {"CertMode": tls_mode, "CertDomain": domain}
        if tls_mode == "file":
            for field, prompt in (("CertFile", "证书文件绝对路径"), ("KeyFile", "私钥文件绝对路径")):
                cert[field] = checked(prompt, cert_path)
        else:
            directory = pathlib.Path("/etc/v2bxss")
            cert.update(CertFile=str(directory / f"{core}-{node_id}.crt"),
                        KeyFile=str(directory / f"{core}-{node_id}.key"), Email=ask("证书申请邮箱"))
    options["CertConfig"] = cert
    if not existing:
        config["Cores"].append({"Type": core})
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
    validator = sub.add_parser("validate")
    validator.add_argument("--input", required=True)
    args = parser.parse_args()
    if args.action == "go-compatible":
        return 0 if go_compatible(args.current, args.required) else 1
    if args.action == "go-download":
        go_download(args.metadata, args.arch, args.required)
        return 0
    if args.action == "validate":
        read_config(args.input)
        return 0
    if args.action == "import":
        config = read_config(args.input)
    else:
        config = copy.deepcopy(read_config(args.existing)) if args.existing else {"Log": {"Level": "info"}, "Cores": [], "Nodes": []}
        while True:
            build_node(config)
            if choose("节点信息已保存", [("y", "继续添加下一个节点"), ("n", "完成填写并应用配置")], "2") != "y":
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
