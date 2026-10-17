# 节点安全审计：协议与后端核对

核对日期：2026-10-17。以下区分源码接入与真实客户端验收；后台下拉列表包含某类型，
不代表该类型运行的任意后端都实现了本二开的审计。

## 本二开 V2bX 的协议

| 面板节点 / 配置 NodeType | 可用内核 | 新审计接入路径 | 验证范围 |
| --- | --- | --- | --- |
| Shadowsocks / `shadowsocks` | `xray`、`sing` | Xray dispatcher 或 sing TCP/UDP tracker | 源码、构建及公共逻辑验证；未完成该协议真实客户端端到端验收 |
| VMess / `vmess`（兼容 `v2ray`） | `xray`、`sing` | 同上 | 同上 |
| Trojan / `trojan` | `xray`、`sing` | 同上 | 同上 |
| VLESS / `vless` | `xray`、`sing` | 同上 | 同上 |
| Hysteria 1 / `hysteria` | `sing` | sing TCP/UDP tracker | 同上 |
| Hysteria 2 / `hysteria2` | `hysteria2`、`sing` | 原生 HY2 RequestFilter 或 sing tracker | **原生 HY2 已有实机 TCP/UDP、混淆、观察/阻断/解除、流量及资格撤销验收**；sing HY2 未做同等实机验收 |
| TUIC / `tuic` | `sing` | sing TCP/UDP tracker | 源码、构建及公共逻辑验证；未完成该协议真实客户端端到端验收 |
| AnyTLS / `anytls` | `sing` | sing TCP/UDP tracker | 同上 |
| V2node / `v2node` | 本 V2bX 无该适配 | 无 | **不能把此类型作为本 V2bX 的 NodeType 使用** |

新装和原版升级构建都包含 `xray`、`sing`、`hysteria2` 与必要的 QUIC 等标签。
安装向导只给出各协议适配的内核选择；手写配置也必须符合该表。TLS、端口、传输、
密码/UUID、混淆和客户端能力仍须匹配。把 TUIC/AnyTLS 指向 Xray 不会因此获得支持。

审计在用户认证后、业务转发路径上进行，不替换原有用户拉取、流量上报、在线统计。
配套面板把 `hysteria2` 归入 `hysteria` 节点表；这是已实现的接口映射，不需要
在面板新增一个 HY2 表。后台规则默认约 30 秒拉取、证据约 5 秒上报；托管规则热同步
不要求重启全部节点。重启、故障及上游待报流量的限制见 [部署说明](../securityaudit/DEPLOYMENT.md)。

## 规则能力的边界

- 原生 HY2：匹配客户端提供的目标主机名、字面 IP/CIDR、端口；没有应用协议探测。
- Xray/sing：公共引擎支持上述类型及可用的应用协议信息；域名/应用协议能否识别取决于
  客户端传入域名和嗅探结果。没有域名、使用加密握手或纯 IP 时不能保证识别网站。
- IP/CIDR 规则针对目标为 IP 的连接；不会为每条域名连接额外查询全部 DNS 地址。
- `observe` 留证，`block` 拒绝命中的目标连接；不是全账号封禁，也不是全量浏览历史。
  新策略通常对新连接生效，已有连接与 UDP 复查边界见 [使用说明](USAGE.zh-CN.md)。
- “原面板路由”“本地 RuleList”“新增托管规则”是不同来源，删除托管规则不会解除
  独立静态路由或本地规则的阻断。

## V2node 为什么不能直接使用

现有配套面板保留 V2node 节点管理和审计接口的类型校验，但面板的 V2node 安装命令
指向独立的 `wyx2685/v2node` 后端。本 V2bX 的节点 API 只接受表中其余协议，
不接受 `v2node`。面板能选节点或能配置规则，不等于独立后端会下载和执行这些规则。

要支持独立 V2node，必须在其后端另行适配：节点认证、策略获取、已认证用户与目标的
转发钩子、观察/阻断、证据批次上报、应用版本及能力回执，并独立验证流量、在线和
到期/耗尽停用。在完成该适配与实机验收前，应按“不支持本次新增审计”处理。
本轮没有改写 V2node 后端，也不声称它的原生路由规则等价于本审计。
