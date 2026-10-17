# 多协议真实连接与审计回归

仅在隔离远端 Linux 环境运行，不需要面板密钥或生产配置。使用本二开真实服务端内核、
sing-box 真实协议客户端和回环 TCP/UDP echo；面板接口为带节点鉴权的 HTTP 测试夹具。
所有监听均为 `127.0.0.1` 随机端口，证书运行时生成并验证，不使用 `insecure`。

```sh
GOEXPERIMENT=jsonv2 GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off \
go test -p 1 -tags 'sing xray hysteria2 with_quic with_grpc with_utls with_wireguard with_acme with_gvisor' \
  ./tools/protocol-audit-check -run TestProtocolAuditRoundTrip -v -count=1 -timeout=15m
```

覆盖 Xray 的 VMess/VLESS/SS/Trojan、sing 的八类协议和原生 HY2，共 13 种组合。
逐项检查基线、观察、阻断、删除策略后恢复的 TCP/UDP 真实收发，域名及子域阻断证据，
用户 ID、版本与动作上报，流量和在线的原 HTTP 上报接口，以及移除资格后新客户端拒绝。
队列和轮询使用公开配置的一秒测试间隔；实际节点默认间隔没有改变。

本套用例不写数据库、不操作 systemd 或已部署节点；也不替代实际面板数据库入库、
各桌面/手机客户端、全部传输变体、已有长连接撤销和压力测试。
运行结果须单独记录，添加测试代码本身不代表这些组合已经通过。
