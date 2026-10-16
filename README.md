# V2bX

本分支包含可选的节点安全审计二开。构建、隔离安装、测试范围和已知限制见
[二开部署与验收说明](securityaudit/DEPLOYMENT.md) 和
[审计协议及内核能力](securityaudit/README.md)。安装入口是本仓库的 `install.sh`，
从指定提交构建本二开，不调用上游安装器，也不假设已有预编译 Release。
本分支的 `V2bX update` 已阻断上游覆盖更新。安装只管理独立测试服务，
默认构建、校验和打印计划；详细说明见 [tools/packaging](tools/packaging/README.zh-CN.md)。

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

### 安装本二开：固定源码提交，先校验再安装

前提：Linux 主机、Git、GNU 工具，以及预先安装的 Go（不低于源码 `go.mod` 的版本，
且支持 `GOEXPERIMENT=jsonv2`；当前源码至少 Go 1.25）。脚本不会安装或替换系统 Go。
首次安装另需准备独立测试节点配置，使用单独节点 ID、监听端口和测试后台凭据。

从自己的二开分支获取源码，审阅本地脚本并记录本次完整提交：

```sh
git clone --branch dev_new --single-branch https://github.com/xcxcadc/V2bXSS.git V2bXSS
cd V2bXSS
commit=$(git rev-parse HEAD)
git show --stat "$commit"
bash install.sh --source "$PWD" --commit "$commit" \
  --config /absolute/path/to/test-node.json --download-deps
```

`--download-deps` 明确允许下载并校验 Go 依赖；已有完整缓存时省略它。
上面会在打印的临时目录构建并保留安装包，但不会修改服务。
确认计划后，在 Linux root 环境中执行（使用同一依赖缓存）：

```sh
bash install.sh --source "$PWD" --commit "$commit" \
  --config /absolute/path/to/test-node.json --apply --start
```

只安装 `V2bX-audit-test.service`；现有 `V2bX.service`、配置及其他服务保留。
升级使用新的 `--commit`，已有测试配置时省略 `--config`，同名版本拒绝覆盖。
默认版本名取自提交 SHA，也可明确传 `--version`。安装前自动备份并打印确切回滚路径。
更换二进制需重启一次服务；之后已支持的后台审计规则自动同步，无需为每条规则重启。

```sh
bash install.sh status
bash install.sh logs
bash install.sh restart --apply
```

这些管理命令仅针对独立测试服务；`start`、`restart`、`stop` 省略 `--apply` 时只打印计划。
远端固定提交安装、离线包安装及回滚见 [完整安装说明](tools/packaging/README.zh-CN.md)。
本入口不是覆盖现有节点的迁移器；不能把 `active` 视作所有协议及数据上报均已验收。

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
