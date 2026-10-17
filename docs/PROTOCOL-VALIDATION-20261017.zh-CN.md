# 多协议节点审计隔离验收记录

日期：2026-10-17。测试源码提交：`195d807905f60cd8e1e53cbef243ea37c73c3ba3`。
执行环境：隔离远端 Linux/amd64、Debian 13、Go 1.25.0、`GOEXPERIMENT=jsonv2`。
这是源码集成测试结果，不是正式服发布声明。

## 逐项结果

| 内核 | 协议 | 结果 |
| --- | --- | --- |
| Xray | VMess | 通过 |
| Xray | VLESS | 通过 |
| Xray | Shadowsocks（aes-128-gcm） | 通过 |
| Xray | Trojan | 通过 |
| sing-box | VMess | 通过 |
| sing-box | VLESS | 通过 |
| sing-box | Shadowsocks（aes-128-gcm） | 通过 |
| sing-box | Trojan | 通过 |
| sing-box | Hysteria | 通过 |
| sing-box | Hysteria2 | 通过 |
| sing-box | TUIC | 通过 |
| sing-box | AnyTLS | 通过 |
| 原生 Hysteria2 | Hysteria2 | 通过 |

13/13 组合均使用本二开真实服务端内核与 sing-box 真实协议客户端，监听只绑定回环地址，
依次检查 TCP/UDP 基线回显、观察、阻断、删除策略后恢复；要求审计策略热加载，
证据包含正确的节点、用户、策略版本、动作和目标。域名后缀测试要求子域目标失败且
存在对应已认证阻断证据。随后检查双向流量、原 HTTP 流量/在线上报接口与用户撤销后
新客户端连接被拒绝。TLS 使用临时生成的测试 CA/证书并验证，不关闭证书验证。

每个方向成功回显的应用载荷合计为 2128 字节。最终 sing-box 八项的上传和下载均为
2128 字节；Xray 四项上传 3040、下载 2128；原生 HY2 上传 2432、下载 2128。
不同内核可能把阻断前已进入内核的请求计入上传，因此不要求不同内核的上传总计相等。
夹具验证 HTTP 收到的身份和数值与内核取出的计数一致。

`common/counter` 回归和 `securityaudit` 全套用例也在同一远端提交通过。

## 本轮发现和修正

- 夹具补齐面板 TCP transport JSON；TUIC 客户端补齐服务端所需的 `h3` ALPN。
- UDP 回显改为读取完整数据报，并用超时关闭连接兜底未实现读取超时的 QUIC 适配器。
- 发现普通流量计数路径使用 `Store` 覆盖已有总数，EOF 还可能把总数清为零。
  新回归在修复前失败；改为原子 `Add` 后通过。真实 sing-box VMess 下载计数由
  只保留末段恢复为全部成功回显字节；13 项用更严格的字节下限再次全部通过。
- 新增逐项运行脚本，单任务编译、单测试进程、共用缓存，每项前检查磁盘剩余空间。

约 1 GiB 内存的远端执行全程没有并行协议测试；临时构建目录放在磁盘分区而非
容量约 484 MiB 的 `/tmp`。结束时临时构建目录约 4 KiB，根分区剩余约 6.3 GiB。
没有修改或重启已运行的节点服务，没有写入正式服、测试面板数据库或真实用户配置。

## 结果边界

- 使用带节点鉴权的内存 HTTP 面板夹具；没有验证实际面板数据库、UI、TG、真实订单
  或生产计费。这些项目不能由本轮通过来替代。
- 没有逐个操作 Windows/macOS/iOS/路由器 GUI 客户端，也没有穷尽 WS/gRPC/Reality、
  所有 SS cipher、多路复用参数、不同架构、长连接撤销或高负载。
- sing tracker 关闭客户端后，上游仍可能尝试 DNS 或出站拨号；不证明 DNS 前拦截。
  域名客户端失败还要求匹配证据，但不等于验证所有 DNS 加密/嗅探情形。
- 未改动 V2node、正式服、内鬼风控工作台或对外 Release，未启用 GitHub Actions。

复测方法见 [测试夹具说明](../tools/protocol-audit-check/README.zh-CN.md)。
