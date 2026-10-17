#!/usr/bin/env python3
"""Preserve the complete upstream trees; never rebuild a node with the wizard."""
import os
import hashlib
from pathlib import Path
import re
import shutil
import sys

OLD_CONFIG = Path('/etc/V2bX')
OLD_RUNTIME = Path('/usr/local/V2bX')
NEW = Path('/etc/v2bxss')
UNIT = Path('/etc/systemd/system/V2bX.service')
STANDARD = '''[Unit]
Description=V2bX Service
After=network.target nss-lookup.target
Wants=network.target
[Service]
User=root
Group=root
Type=simple
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999
WorkingDirectory=/usr/local/V2bX/
ExecStart=/usr/local/V2bX/V2bX server
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
'''
RESERVED = {'current', 'releases', 'manager', 'toolchains', 'build-cache',
            'v2bxss', 'layout.lock', 'legacy-runtime', 'launcher.last-check'}
REPLACEMENTS = [('/usr/local/V2bX', '/etc/v2bxss/legacy-runtime'),
                ('/etc/V2bX', '/etc/v2bxss')]


def rewrite(text):
    for old, new in REPLACEMENTS:
        # A path component boundary avoids rewriting unrelated prefix names.
        text = re.sub(re.escape(old) + r'(?=/|["\s\x27]|$)', lambda _: new, text)
        text = re.sub(re.escape(old.replace('/', r'\/')) + r'(?=\\/|["\s\x27]|$)',
                      lambda _: new.replace('/', r'\/'), text)
    return text


def normalize(text):
    return '\n'.join(line.strip() for line in text.splitlines()
                     if line.strip() and not line.lstrip().startswith(('#', ';', 'Description=')))


def safe(path):
    for parent in (path, *path.parents):
        if parent.is_symlink():
            raise ValueError(f'不支持符号链接安装根路径：{parent}')


def preflight():
    for path in (OLD_CONFIG, OLD_CONFIG / 'config.json', OLD_RUNTIME, OLD_RUNTIME / 'V2bX', UNIT, NEW, NEW / 'legacy-runtime'):
        safe(path)
    if not (OLD_CONFIG / 'config.json').is_file() or not (OLD_RUNTIME / 'V2bX').is_file():
        raise ValueError('未找到原版完整配置和程序')
    if (NEW / 'legacy-runtime').exists():
        raise ValueError('目标已有迁移运行资源；拒绝叠加覆盖')
    if normalize(UNIT.read_text()) != normalize(STANDARD):
        raise ValueError('原版服务含自定义参数或不是上游标准 systemd 安装；需人工审查，未停止原节点')
    for item in OLD_CONFIG.iterdir():
        if item.name in RESERVED:
            raise ValueError(f'旧配置含管理保留名称：{item.name}')
    for root in (OLD_CONFIG, OLD_RUNTIME):
        for directory, dirs, files in os.walk(root, followlinks=False):
            for name in dirs + files:
                path = Path(directory) / name
                if not path.is_symlink() and not path.is_dir() and not path.is_file():
                    raise ValueError(f'不复制套接字或特殊设备：{path}')


def fingerprint():
    """Detect edits during backup/staging, before stopping the live service."""
    digest = hashlib.sha256()
    paths = [UNIT]
    for root in (OLD_CONFIG, OLD_RUNTIME):
        for directory, dirs, files in os.walk(root, followlinks=False):
            paths.extend(Path(directory) / name for name in dirs + files)
    for path in sorted(paths):
        digest.update(os.fsencode(str(path)) + b'\0')
        digest.update(str(path.lstat().st_mode).encode() + b'\0')
        if path.is_symlink():
            digest.update(os.fsencode(os.readlink(path)))
        elif path.is_file():
            with path.open('rb') as stream:
                while chunk := stream.read(1024 * 1024):
                    digest.update(chunk)
        digest.update(b'\0')
    return digest.hexdigest()


def stage(destination):
    preflight()
    destination.mkdir(mode=0o700)
    shutil.copytree(OLD_CONFIG, destination / 'config', symlinks=True)
    shutil.copytree(OLD_RUNTIME, destination / 'runtime', symlinks=True)
    for root in (destination / 'config', destination / 'runtime'):
        for directory, dirs, files in os.walk(root, followlinks=False):
            for name in dirs + files:
                path = Path(directory) / name
                if path.is_symlink():
                    old = os.readlink(path)
                    new = rewrite(old)
                    if new != old:
                        path.unlink()
                        path.symlink_to(new)
                elif path.is_file() and path.suffix.lower() in {'.json', '.json5', '.yaml', '.yml', '.toml', '.txt', '.conf'}:
                    try:
                        old = path.read_text(encoding='utf-8')
                    except UnicodeError:
                        continue
                    new = rewrite(old)
                    if new != old:
                        path.write_text(new, encoding='utf-8')
    # Keep the upstream working directory for relative Include, geo and route
    # paths. The config flag replaces upstream's hard-coded /etc/V2bX default.
    unit = rewrite(UNIT.read_text())
    unit = unit.replace('ExecStart=/etc/v2bxss/legacy-runtime/V2bX server',
                        'ExecStart=/etc/v2bxss/current/v2bxss server --config /etc/v2bxss/config.json')
    (destination / 'service').write_text(unit)


if __name__ == '__main__':
    try:
        if len(sys.argv) == 1:
            preflight()
        elif sys.argv[1:] == ['--fingerprint']:
            print(fingerprint())
        elif len(sys.argv) == 2:
            stage(Path(sys.argv[1]))
        else:
            raise ValueError('需要零个参数或一个新的暂存目录')
    except (OSError, ValueError) as error:
        sys.exit(f'迁移检查失败：{error}')
