# V2bX

本分支包含可选的节点安全审计二开。构建、隔离安装、测试范围和已知限制见
[二开部署与验收说明](securityaudit/DEPLOYMENT.md) 和
[审计协议及内核能力](securityaudit/README.md)。运行下面的一键命令打开中文菜单，
选择安装或更新即可，自动准备依赖、Go 和节点配置，不需要手工 clone 或填写提交号。
安装的是自己的二开版本；详细说明见 [tools/packaging](tools/packaging/README.zh-CN.md)。

### 本次二开更新（2026-10-17）

安装和原版升级脚本均从 `xcxcadc/V2bXSS` 的 `dev_new` 获取源码，固定本次提交后构建，
不是下载上游原版程序或旧 Release。两条命令保持不变，原有节点不会被远程自动升级；
需在自己的节点服务器运行相应入口，新装菜单选择 **1**。

- 已完成 Xray、sing-box、原生 HY2 共 **13 项内核/协议组合**的隔离集成验收，覆盖连接、
  审计热同步、观察/阻断/解除、流量及在线上报和用户撤权。
- 修复普通流连接累计流量被后一次读写覆盖的问题；本次安装/升级会包含该修复。
- 新装管理菜单新增 **11. 实时运行 / 连接日志**，也可执行 `v2bxss logs -f`。

详细结果及未覆盖范围见[逐项验收记录](docs/PROTOCOL-VALIDATION-20261017.zh-CN.md)。
这不是全部客户端、传输组合或实际面板支付流程都已验收的声明。

[![](https://img.shields.io/badge/TgChat-UnOfficialV2Board%E4%BA%A4%E6%B5%81%E7%BE%A4-green)](https://t.me/unofficialV2board)
[![](https://img.shields.io/badge/TgChat-YuzukiProjects%E4%BA%A4%E6%B5%81%E7%BE%A4-blue)](https://t.me/YuzukiProjects)

A V2board node server based on multi core, modified from XrayR.  
一个基于多种内核的V2board节点服务端，修改自XrayR，支持V2ay,Trojan,Shadowsocks协议。

**注意： 本项目需要搭配[修改版V2board](https://github.com/wyx2685/v2board)**

## 特点

* 永久开源且免费。
* 支持Vmess/Vless, Trojan， Shadowsocks, Hysteria1/2多种协议。
* 支持Vless和XTLS等新特性。
* 支持单实例对接多节点，无需重复启动。
* 支持限制在线IP。
* 支持限制Tcp连接数。
* 支持节点端口级别、用户级别限速。
* 配置简单明了。
* 修改配置自动重启实例。
* 支持多种内核，易扩展。
* 支持条件编译，可仅编译需要的内核。

## 功能介绍

新增审计的后台配置、节点同步、能力范围及使用步骤见
[二开审计使用说明](docs/USAGE.zh-CN.md)。新增规则是否执行以节点回执能力为准。

| 功能        | v2ray | trojan | shadowsocks | hysteria1/2 |
|-----------|-------|--------|-------------|----------|
| 自动申请tls证书 | √     | √      | √           | √        |
| 自动续签tls证书 | √     | √      | √           | √        |
| 在线人数统计    | √     | √      | √           | √        |
| 审计规则（按内核能力，详见使用说明） | 支持 | 支持 | 支持 | HY2 支持域名/IP/端口 |
| 自定义DNS    | √     | √      | √           | √        |
| 在线IP数限制   | √     | √      | √           | √        |
| 连接数限制     | √     | √      | √           | √         |
| 跨节点IP数限制  |√      |√       |√            |√          |
| 按照用户限速    | √     | √      | √           | √         |
| 动态限速(未测试) | √     | √      | √           | √         |

## TODO

- [ ] 重新实现动态限速
- [ ] 完善使用文档

## 软件安装

### 已有原版节点：独立原位升级

已经通过 `wyx2685/V2bX-script` 安装的节点，使用这一条命令，**不要使用下面的新装入口**：

```sh
wget -N https://raw.githubusercontent.com/xcxcadc/V2bXSS/dev_new/upgrade-legacy-node.sh && bash upgrade-legacy-node.sh
```

脚本自动构建本二开，只替换 `/usr/local/V2bX/V2bX`，保留 `/etc/V2bX` 全部配置、
证书、混淆、节点端口、本地路由/geo 文件、服务定义和开机启动设置。
沿用原 `V2bX.service` 或 OpenRC，不安装新服务。升级前备份到
`/var/backups/v2bxss-legacy/<时间-版本-进程号>/` 并打印回滚命令。
替换或启动失败自动恢复；原服务停止时保持停止。支持 Linux amd64/arm64。

构建期间原节点继续运行，替换后重启一次，已有连接会短暂中断。
脚本不修改面板累计流量；进程内尚未成功上报的增量仍受原版计数机制限制，不能承诺零损失。
升级后应核对流量上报、在线统计和用户到期撤权。后续仍使用此脚本更新，
不要从上游旧菜单执行更新/重装，否则可能覆盖二开。
回滚方式及验证边界见[升级说明](tools/packaging/README.zh-CN.md#原版节点独立升级)。

### 一键安装本二开（中文菜单）

在 Linux 服务器用 root 执行：

```sh
wget -N https://raw.githubusercontent.com/xcxcadc/V2bXSS/dev_new/install.sh && bash install.sh
```

运行后出现菜单，选择 **1. 安装 / 更新到最新二开版本**。
首次安装按提示填写面板 API 地址、节点密钥、节点类型、节点 ID 和证书信息，
也可以直接导入已有 JSON 配置。支持一次对接多个节点。
程序自动下载依赖并编译，首次安装需要数分钟；不需要自行安装 Go。
支持 Debian/Ubuntu、使用 dnf/yum 的发行版，Linux amd64/arm64 和 systemd。

安装完成后，直接输入以下命令重新打开管理菜单：

```sh
v2bxss
```

菜单包含安装/更新、追加节点、导入配置、启停/重启、状态、日志、开机自启和回滚。
以后更新仍选择 **1**，自动获取本仓库 `dev_new` 最新版本，完整保留现有配置、
证书及混淆；已经是最新版时不重新编译。安装前自动备份并显示路径。

本二开使用独立服务 `V2bX-audit-test.service` 和 `/etc/v2bx-audit-test/config.json`。
若原有上游服务正在使用相同端口，应先处理端口冲突；菜单不会自动停掉上游服务。
工具链安装在自己的目录，不替换系统 Go。高级固定提交/离线安装入口仍保留，见
[完整安装说明](tools/packaging/README.zh-CN.md)。

升级二进制会重启该二开服务一次；之后后台托管审计规则约 30 秒自动同步，
不需要为每条规则登录服务器或重启所有节点。

## 构建
```sh
bash tools/packaging/build-local-bundle.sh \
  --source "$PWD" --output /absolute/path/to/new/audit-test-bundle \
  --version audit-test-1 --arch amd64
```

此入口仅离线构建，需要预先准备完整依赖缓存。可选 `amd64`、`arm64`；构建标签和验收范围见安装说明。

## 配置文件及详细使用教程

[详细使用教程](https://v2bx.v-50.me/)

## 免责声明

* 此项目用于本人自用，因此本人不能保证向后兼容性。
* 由于本人能力有限，不能保证所有功能的可用性，如果出现问题请在Issues反馈。
* 本人不对任何人使用本项目造成的任何后果承担责任。
* 本人比较多变，因此本项目可能会随想法或思路的变动随性更改项目结构或大规模重构代码，若不能接受请勿使用。

## 赞助

[赞助链接](https://v-50.me/)

## Thanks

* [Project X](https://github.com/XTLS/)
* [V2Fly](https://github.com/v2fly)
* [VNet-V2ray](https://github.com/ProxyPanel/VNet-V2ray)
* [Air-Universe](https://github.com/crossfw/Air-Universe)
* [XrayR](https://github.com/XrayR/XrayR)
* [sing-box](https://github.com/SagerNet/sing-box)

## Stars 增长记录

[![Stargazers over time](https://starchart.cc/wyx2685/V2bX.svg)](https://starchart.cc/wyx2685/V2bX)
