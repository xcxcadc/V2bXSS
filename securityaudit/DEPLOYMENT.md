# 节点安全审计二开：构建、隔离部署与验收

本目录记录节点端实现；后台页面、权限及审计 API 需要配套面板代码。
日常安装、规则导入、来源区分与重启条件见 [中文使用说明](../docs/USAGE.zh-CN.md)。
本分支不新增 TG 菜单并保留既有交互。
只安装本节点二进制不会创建后台菜单。节点连接适配的后台后会自动拉取可选审计策略，
无需逐台手写规则。旧后台缺少审计接口时节点正常服务，审计功能不启用。

## 功能与数据边界

- 只记录已认证用户命中管理员安全规则的连接，支持观察与阻断目标连接。
- 不采集未命中的浏览历史、网页正文、URL 路径、密码；不执行用户画像或账号自动处罚。
- 支持域名精确、后缀、受限正则、字面 IP/CIDR、端口及可见的应用协议。
- 策略默认约 30 秒轮询，证据默认约 5 秒批量上报；不是实时推送，也不保证零延迟。
- 无效策略或接口故障保留最近有效策略；可按节点配置独立缓存文件以跨重启恢复。
- 证据队列有界，满载时丢弃证据并报告数量；重试使用稳定事件 ID。
- 原有面板路由规则保持原样，以只读清单去重上报。它们不会被静默迁移成新规则。
- `RuleListPath` 本地文件另行只读上报；默认不执行，须显式设置 `RuleListEnforce`
  才阻断。本地规则更新在原节点拉取周期检查，非法更新保留最后有效版本。

没有导入外部政治、宗教或新闻站点名单，也没有实现全浏览历史调查。
XrayR 的任意路由/正则配置不等同于本功能的可移植安全规则，不能声称完全兼容。

## 三内核能力

| 内核 | 域名 | 字面 IP/CIDR、端口 | 应用协议 | 验证边界 |
| --- | --- | --- | --- | --- |
| Xray | 请求域名或已有嗅探结果 | 支持，保留嗅探前 IP | 取决于现有嗅探结果 | 已编译与测试公共引擎，未完成所有入站协议真实客户端验收 |
| sing-box | 请求域名或已有嗅探结果 | 支持，保留嗅探前 IP | 取决于现有嗅探结果 | 已编译与测试公共引擎，未完成所有入站协议真实客户端验收 |
| 原生 Hysteria 2 | 请求中的域名 | 支持 | 当前回调不支持应用协议识别 | 已有本地真实 HY2 TCP/UDP 观察、阻断、恢复与撤销测试 |

不会自动更改嗅探设置；域名规则受加密、ECH、客户端直接连接 IP 等条件限制。
审计不会为 CIDR 匹配另行解析请求域名。规则热更新适用于新连接；已建立 TCP 连接
不会仅因为修改目标规则被追溯切断。原生 HY2 会复查 UDP 目标变化和策略版本变化。

到期、流量耗尽等账号资格由原面板用户快照决定，与目标规则独立。二开修复了空全量
用户快照无法移除最后一个用户、命名节点重载撤销、原生 HY2 已有会话未断开、
多节点认证隔离、并发流量计数与 PushInterval 配置更新等问题。
实际停止时间仍取决于面板发布用户快照和原有用户拉取周期，不能宣称即时到账即断开。

## 可复现构建

本轮本地验证环境为 Go 1.26.5；依赖使用模块文件中的固定版本，不执行依赖升级。
在仓库根目录执行：

```sh
GOEXPERIMENT=jsonv2 CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
  -tags 'xray sing hysteria2 with_quic with_utls with_gvisor with_wireguard with_acme' \
  -trimpath \
  -ldflags='-s -w -X github.com/InazumaV/V2bX/cmd.version=AuditTest-20261016-r3' \
  -o V2bX-audit-linux-amd64 .
sha256sum V2bX-audit-linux-amd64
```

这里列出的是此前验收标签。后续一键新装及原版升级已补充 `with_grpc`，
并通过完整标签 Linux/amd64 编译；仍未把全部平台/协议的真实客户端兼容性算作已验证。
交付时记录实际产物哈希；修改源码或编译器后应重新记录，不能复用旧产物哈希。

## 隔离安装

本仓库首页安装命令改用自己的 [`install.sh`](../install.sh)，从固定提交构建二开，
不调用上游安装器。本分支已禁用 `V2bX update`，避免被上游脚本覆盖。源码仓库另提供
[`tools/packaging`](../tools/packaging/README.zh-CN.md) 离线构建、隔离测试安装和回滚工具。
高级安装/回滚默认只校验，显式 `--apply` 才写入，另加 `--start` 才启动。
无参数新装菜单在用户选择安装后自动构建和启动。已有原版的独立原位升级入口为
`upgrade-legacy-node.sh`，具体保留范围、备份及回滚见打包工具说明。
构建包包含版本和工作树哈希，安装校验二进制及完整清单。

首次验收应使用独立测试目录、测试面板、测试节点 ID、测试用户和端口。例如将已核验
的产物由安装器存为 `/opt/v2bx-audit-test/releases/<version>/V2bX`，配置存为
`/etc/v2bx-audit-test/config.json`，独立服务对应的命令为：

```sh
/opt/v2bx-audit-test/current/V2bX server \
  --config /etc/v2bx-audit-test/config.json --watch=false
```

不要复用或覆盖 `/etc/V2bX`、现有 systemd 服务和正式节点端口。示例配置
[`example/security-audit-hy2-test.json`](../example/security-audit-hy2-test.json)
只监听回环地址，其保留示例域名、面板地址、节点 ID、API token、TLS 路径必须换成
各自测试环境值；示例没有部署凭证。配置应限制到服务运行用户可读，审计缓存每节点独立。
新增节点需要在配套面板赋予审计策略，并查看其 `applied_version` 确认已应用。

## 本地测试命令

在根目录执行；`-run` 刻意排除上游联网 ACME/固定面板测试。ACME 客户端的测试初始化
已移到其显式用例内，避免选择无关用例时意外联网。本轮复核将 `GOPROXY=off`、
`GOSUMDB=off`，且为可能使用 HTTP 的库设置本地 SOCKS 代理，避免依赖重新下载：

```sh
GOEXPERIMENT=jsonv2 go test \
  -tags 'xray sing hysteria2 with_quic with_utls with_gvisor with_wireguard with_acme' \
  ./limiter ./securityaudit ./api/panel ./node ./core/hy2 ./tools/hy2-audit-probe \
  -run 'Test(Rule|Sniffed|Portable|Invalid|Observe|Atomic|Legacy|Bounded|NoUnmatched|Permanent|Batch|ConfigOutage|LastValid|Native|LocalRuleList|SecurityAudit|UserListEmpty|EmptyUser|EmptySnapshot|ReportCadence|TrafficRevocation|ConcurrentNative|Probe|AccountClosure|Revocation)' \
  -count=1
GOEXPERIMENT=jsonv2 GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go vet \
  -tags 'xray sing hysteria2 with_quic with_utls with_gvisor with_wireguard with_acme' \
  ./limiter ./securityaudit ./api/panel ./node ./core/hy2 ./tools/hy2-audit-probe ./core/xray/... ./core/sing
go test github.com/apernet/hysteria/core/v2/server -count=1
go vet github.com/apernet/hysteria/core/v2/server
```

通过这些命令代表本地单元、HTTP 模拟与本地真实 HY2 集成测试通过，不能替代所有
节点类型、所有客户端和实际生产支付/登录/订单/流量统计的端到端测试。

## 部署验收与回滚

使用独立的[回环诊断工具](../tools/hy2-audit-probe/README.md)，按顺序验证基线可用、
观察不阻断、目标阻断、解除恢复、禁用恢复、策略版本确认、证据入库及权限隔离。
TCP 的明确审计拒绝才算阻断通过；UDP 超时必须结合匹配的后台阻断证据判定。

到期与耗尽应分别测试：保留既有 TCP/UDP/QUIC，会话期间仅变更测试用户资格，等待
**节点实际拉取并记录移除**后验证既有流断开、新认证拒绝，再恢复验证。不能只检查
手工获取的面板用户列表，也不能把超时或诊断目标提前退出当作断开成功。
保留服务 PID、时间戳、节点应用版本与精确流量增量，区分本地测试与远程验收结果。

重要已知上游限制：流量任务先重置计数后发送 HTTP，发送失败可能损失该批增量；
移除用户时会删除其尚未上报计数，突然退出也可能损失待报增量。这些交付可靠性问题
没有被证据队列的重试机制解决。替换/回滚测试进程前应先确认待报流量成功送达。
此功能不声称提供生产级零丢失计费保证。

正式服部署需要独立授权与完整回归结果。回滚应恢复备份二进制、配置和服务定义，
不得用测试数据库覆盖正式数据库。保留原有证据；停用策略和回滚程序是两个不同操作。
隔离安装器将备份路径打印到终端，备份位于 `/var/backups/v2bx-audit-test/`。
从该备份运行 `rollback-test-node.sh --backup <完整备份路径>` 可先校验并显示计划；
显式 `--apply` 才恢复，`--apply --start` 才启动旧版本。首次安装没有旧版本时只停止
测试服务，保留文件和备份；回滚前还会保存当前配置检查点。

尚未实现通用接管每个安装器的本地默认规则：现有面板 routes 和本地 RuleList
清单为只读，本地 Xray/sing/HY2 其他静态配置尚未纳入后台删除和重载。
不能将复制规则或删除副本描述为
已经删除节点原静态规则。真实客户端和全部协议的兼容性也不能由编译标签推定。

## 源码交付与许可证

`third_party/hysteria-core` 固定为 Hysteria core/v2 v2.6.4 的本地补丁，保留原 MIT
[`LICENSE.md`](../third_party/hysteria-core/LICENSE.md)；上游的公开固定测试证书
仅作测试夹具，不可部署。补丁详情见
[`AUDIT_PATCH.md`](../third_party/hysteria-core/AUDIT_PATCH.md)。

源码提交排除本地二进制、真实配置、证书私钥、缓存、运行日志、数据库与测试账号。
进度文档不包含服务器地址、私人聊天、真实用户邮箱、token、支付单号或原始证据。
