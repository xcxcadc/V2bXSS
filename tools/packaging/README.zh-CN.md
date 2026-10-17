# 一键菜单与高级构建、安装、回滚

## 推荐：一键打开中文菜单

```sh
wget -N https://raw.githubusercontent.com/xcxcadc/V2bXSS/dev_new/install.sh && bash install.sh
```

使用 Linux root、systemd、amd64/arm64。菜单 1 安装/更新自己的二开，自动准备
系统依赖、独立 Go 工具链和模块，固定本次取得的完整提交后构建。Go 官方下载使用
官网发布的 SHA256 校验；模块使用 go.sum 和校验服务。首次编译需要数分钟及足够磁盘。
工具链和构建缓存位于 `/etc/v2bxss/`，不替换系统 Go。

安装入口和独立原版升级入口均只获取 `xcxcadc/V2bXSS/dev_new`，输出本次完整提交及源码链接，
再从固定提交构建；不下载上游原版二进制或旧 Release。同步到仓库不会自动更改已部署节点，
已有独立安装运行菜单 1 更新，原版原位升级运行本页末尾的独立升级命令。
当前已同步的二开包含累计流量修复；多协议隔离验收范围和限制见
[2026-10-17 验收记录](../../docs/PROTOCOL-VALIDATION-20261017.zh-CN.md)。

首次可选择向导（面板、密钥、类型、ID、TLS）或导入 JSON；支持多节点。
支持 vmess/vless/trojan/shadowsocks、hysteria1/2、tuic、anytls，向导按类型选择可用内核。
TLS 可用已有文件或自动 HTTP 证书；后者要求域名已解析到本机且 80 端口可用。
混淆、端口等面板下发参数仍由面板管理，不另建一份密码。

安装后运行 `v2bxss` 打开相同菜单：

| 选项 | 行为 |
| --- | --- |
| 1 | 安装/更新最新二开；已是最新提交则跳过编译；已有配置完整保留 |
| 2 | 保留已有节点、证书、自定义选项并追加节点；拒绝重复节点 |
| 3 | 导入替换 JSON，先备份；启动检查失败时恢复旧配置 |
| 4/5/6 | 启动/停止/重启二开服务 |
| 7/8 | 查看运行状态/最近 100 条日志，查看后返回菜单 |
| 9 | 开启/关闭二开服务开机自启 |
| 10 | 选取匹配当前版本的上一版备份，确认后回滚并重启 |
| 11 | 实时跟随当前运行/连接日志；Ctrl+C 结束查看返回菜单，不停止节点 |
| 12 | 将旧独立目录迁移到 `/etc/v2bxss`，备份后切换服务；失败切回，旧文件保留 |
| 0 | 退出 |

菜单中的写入操作直接执行，无需再追加高级参数。安装成功自动开启开机自启。
更新保留整个现有配置文件，包括带注释 JSON、外部 Include、证书和混淆配置；
只有追加/导入向导需要可校验的标准 JSON，自定义 Include 可直接修改原配置。
每次程序安装沿用下面的哈希校验、备份和独立服务路径。
管理脚本位于 `/etc/v2bxss/v2bxss`，程序为 `/etc/v2bxss/current/v2bxss`。
菜单打开时即保存可独立运行的管理脚本，且高级 bundle 安装也先安装管理入口，
不再出现仅留下快捷命令却未安装目标脚本的情况。
配置编辑备份另放在 `/var/backups/v2bxss/config-<UTC时间>-<PID>/config.json`。
安装失败保留构建目录并显示错误，菜单不会因单次失败退出。

升级程序重启本服务一次；后台托管规则约 30 秒热同步，无需为每条规则重启。
菜单只管理 `v2bxss.service`，不自动接管上游服务或修改防火墙。
如果原节点还占用相同端口，请先处理冲突，再启动二开。

## 只修复管理入口 / 旧独立安装迁移

```sh
wget -N https://raw.githubusercontent.com/xcxcadc/V2bXSS/dev_new/install.sh && bash install.sh repair
v2bxss
```

`repair` 不联网、不编译、不操作服务，也不改配置。随后选择菜单 12 可迁移旧独立安装。
迁移保留旧文件和原二进制版本、打印备份/回滚命令；只把配置中的旧私有目录前缀
改为 `/etc/v2bxss/`，其他设置、密钥及外部证书路径保持原样。
旧目录丢失而程序仍在运行时，先从 Linux 运行中可执行文件备份恢复，才允许停止旧服务。
不能恢复旧程序或存在自定义 systemd drop-in 时拒绝切换，不会盲目重启。
迁移后要更新二开代码，再选择菜单 1。旧原版 `/etc/V2bX` 不属于该迁移范围。

## 高级：固定提交和离线操作

以下为可选的高级入口，不是日常一键安装的必做步骤。
此目录的离线脚本安装本分支二开，不调用上游一键脚本，也不下载二进制或依赖。
只管理 `v2bxss.service`，不管理现有 `V2bX.service`、`/etc/V2bX`、面板或数据库。
安装和回滚默认都只校验并打印计划；必须显式 `--apply` 才写入，另加 `--start` 才启动。
构建脚本会写入显式指定的新输出目录，不修改源目录。

## 高级参数入口

根目录 [install.sh](../../install.sh) 带参数调用时保留高级安装入口，
从完整提交 SHA 构建再调用本目录的隔离安装器，不假设存在预编译 Release，
不会执行上游安装器或未校验的远端脚本管道。
审计功能的使用见 [使用说明](../../docs/USAGE.zh-CN.md)。

前提是已安装 Go、Git、GNU 工具。Go 需要满足选定源码 `go.mod` 的最低版本，
并支持 `GOEXPERIMENT=jsonv2`（当前源码至少 Go 1.25）。
不存在 Go、版本不足或不支持实验开关时，入口准确报错，不替换系统 Go，
不使用 Go 的自动工具链下载。实际安装仍要求 Linux root、匹配架构及 systemd。

需要固定提交的自动化部署时，从 `dev_new` 获取并记录完整 SHA：

```sh
git clone --branch dev_new --single-branch https://github.com/xcxcadc/V2bXSS.git V2bXSS
cd V2bXSS
commit=$(git rev-parse HEAD)
git show --stat "$commit"
bash install.sh --source "$PWD" --commit "$commit" \
  --config /absolute/path/to/test-node.json --download-deps
```

`--source` 要求本地 checkout 根目录、HEAD 与 SHA 相符、工作树干净。
入口在新临时目录取出该提交，保留源码和 bundle 路径，不复制未提交文件或真实配置。
它先验证提交、Go 最低版本和依赖缓存，再执行已有离线构建与哈希校验。
默认版本名是 `audit-<SHA前12位>`；可用 `--version` 指定新名称，目标可选 `--arch amd64|arm64`。

默认安装阶段不写系统目录、不修改或启动服务；前面的源码准备和构建会写临时目录。
`--download-deps` 明确允许 Go 模块下载，使用 `go.sum` 和公开校验服务验证依赖；
省略时仅使用现有缓存，缺失会失败。网络代理由操作者使用 Git/Go 支持的环境变量配置，
脚本不内置任何私有代理。请在同一依赖缓存环境下，使用 Linux root 明确安装并启动：

```sh
bash install.sh --source "$PWD" --commit "$commit" \
  --config /absolute/path/to/test-node.json --apply --start
```

已取得并审阅入口脚本时，也可不提供 `--source`，由脚本只从自己的仓库拉取指定完整提交：

```sh
bash /absolute/path/to/reviewed/install.sh --commit '<可信的40位完整提交SHA>' \
  --config /absolute/path/to/test-node.json --download-deps
```

分支名、短 SHA 和拉取结果不一致均会拒绝。此模式的默认计划仍需要下载源码和构建，
只是不执行系统安装。入口脚本及指定提交都应来自操作者信任并审阅的版本；
校验提交相等不等于自动证明任意代码安全。
升级时选新提交并省略 `--config`，现有测试配置保留，已有版本目录拒绝覆盖。
如果本机已有不同的测试 unit，安装器会拒绝，要求先审阅，不自动覆盖它。

```sh
bash install.sh status
bash install.sh logs
bash install.sh restart --apply
bash install.sh stop --apply
bash install.sh start --apply
```

状态和最近 100 条日志只读取 `v2bxss.service`；启动、重启和停止必须加 `--apply`。
这些命令不管理原 `V2bX.service`，也没有卸载、删除备份或修改开机启动的隐式操作。
**更换二进制需要一次明确重启；之后已支持的后台审计规则热更新无需重启节点。**

## 本地构建

准备支持 `GOEXPERIMENT=jsonv2` 的 Go 工具链、完整依赖缓存、Git 和常见 GNU 命令。
本轮验证为 Go 1.26.5。依赖缺失时脚本失败，不下载或切换工具链。

```sh
bash tools/packaging/build-local-bundle.sh \
  --source /absolute/path/to/V2bXSS \
  --output /absolute/path/to/new/audit-test-bundle \
  --version audit-test-1 --arch amd64
```

目标可选 `amd64` 或 `arm64`；当前真实构建验收为 Linux/amd64。
构建标签包括 Xray、sing-box、原生 HY2、QUIC、完整 gRPC、uTLS、WireGuard、ACME 和 gVisor。
本轮已验证包含 `with_grpc` 的 Linux/amd64 编译；这不等于每种协议已做真实客户端验收。
成功输出包含二进制、安装/回滚脚本、独立 unit、`BUILD-INFO` 和 `SHA256SUMS`。
`BUILD-INFO` 记录版本、提交、工具链及工作树哈希，不打包工作树内容或真实配置。
记录终端输出的二进制和清单 SHA256，安装时从可信记录取得哈希；不要只信任随包附带的值。

此目录的脚本不会上传文件或连接服务器。上传方式和代理由操作者单独配置。
面板地址、节点 ID、API token、端口和证书应为独立测试值。

## 校验与安装

先将完整构建目录和单独测试配置放到目标测试主机，执行：

```sh
bash ./install-test-node.sh \
  --bundle /absolute/path/to/uploaded-bundle --version audit-test-1 \
  --binary-sha256 '<可信记录的二进制SHA256>' \
  --manifest-sha256 '<可信记录的清单SHA256>' \
  --config /absolute/path/to/test-node.json
```

该命令默认不写入、不执行二进制、不启动服务；`--start` 单独使用也不会启动。
检查测试身份、监听端口和 TLS 路径后，在相同命令后加 `--apply` 安装。
还需要立即启动时使用 `--apply --start`。实际安装要求 Linux root、systemd、架构相符。
脚本不自动启用开机启动；`active` 也不等于所有节点均成功对接。

| 对象 | 固定隔离路径 |
| --- | --- |
| 每个版本 | `/etc/v2bxss/releases/<version>/` |
| 当前版本 | `/etc/v2bxss/current` |
| 测试配置 | `/etc/v2bxss/config.json` |
| 独立服务 | `/etc/systemd/system/v2bxss.service` |
| 每次安装前备份 | `/var/backups/v2bxss/<UTC时间>-<version>-<PID>/` |

升级时使用新版本名并省略 `--config`，已有配置会保留；同名版本拒绝覆盖。
脚本验证二进制、清单、完整六项文件哈希（含管理器）、版本、目标架构以及路径类型。
备份先于版本切换，包含旧版本副本、旧配置和 unit、旧服务状态以及回滚脚本。
脚本不删除旧版本、备份或证据。没有 `--start` 时，已运行的进程继续使用旧二进制。
如果中途失败，查阅已经打印的备份路径和当前链接，不能假定自动回滚已经完成。

## 回滚

从安装输出取得确切备份目录，先打印计划：

```sh
bash /var/backups/v2bxss/<备份名>/rollback-test-node.sh \
  --backup /var/backups/v2bxss/<备份名>
```

确认后加 `--apply`，只停止隔离测试服务并恢复备份对应的旧版本链接、旧配置和 unit。
加 `--apply --start` 才启动恢复的版本。脚本先额外保留回滚前配置与 unit 的检查点；
不会删除任何文件，也不会接触上游服务。首次安装没有旧版本时，只停止隔离服务并保留文件。
当前版本已被后续安装切换时，旧备份回滚会拒绝执行，避免覆盖后续升级。

回滚前应确认流量增量已经成功上报。上游仍有发送前清零、移除用户丢失待报计数的限制；
停止进程不能保证待报流量零损失。服务运行、连接撤销和各类统计还需按
[部署验收说明](../../securityaudit/DEPLOYMENT.md) 检查。

## 尚未完成的边界

安装器不接管每台节点安装时的 Xray 本地路由、sing 配置或 HY2 ACL。
当前提供已有面板 `routes` 和显式配置的 `RuleListPath` 本地文件的独立只读清单。
后者默认只预览，显式开启 `RuleListEnforce` 才在支持内核执行；文件内容随原节点
配置轮询热检查，不上传服务器路径。详见[本地规则说明](../../securityaudit/NATIVE-AUDIT.zh-CN.md)。
这两种清单不能代表节点上全部静态规则；复制到新模块不代表接管原件。
因此不能声称在新页面删除副本就删除了节点原默认规则。
也没有完成全部入站协议、所有真实客户端、arm64 或生产支付链路的完整验收。
本工具不自动覆盖任意既有上游节点；菜单和高级安装共用独立服务路径。

## 原版节点独立升级

原来由 `wyx2685/V2bX-script` 安装的节点使用独立入口：

```sh
wget -N https://raw.githubusercontent.com/xcxcadc/V2bXSS/dev_new/upgrade-legacy-node.sh && bash upgrade-legacy-node.sh
```

该脚本不会调用 `install.sh`，只替换 `/usr/local/V2bX/V2bX`，沿用原 systemd/OpenRC
服务。`/etc/V2bX`、证书、混淆、端口、geo/路由文件、原管理器、启停和开机启动设置保持原样。
需要 Linux amd64/arm64；缺少依赖和合适 Go 时自动准备，源码固定到获取时的完整提交号，
工具链校验官方 SHA256，Go 模块保持校验。只检查原安装可以先运行：

```sh
bash upgrade-legacy-node.sh --dry-run
```

构建期间原服务持续运行。确认升级后，先把原程序、整个原安装/配置目录、服务定义及
运行状态备份到 `/var/backups/v2bxss-legacy/<时间-版本-进程号>/`，再原位替换程序。
运行中的服务重启一次并检查持续存活和 PID；停止状态不会擅自启动。替换/启动失败自动
恢复旧程序及升级前状态。备份可能含密钥，权限为 root 私有，不能上传公开仓库。

每次输出可直接复制的回滚命令，例如：

```sh
bash /var/backups/v2bxss-legacy/<备份名>/rollback.sh --rollback /var/backups/v2bxss-legacy/<备份名>
```

回滚校验旧/新二进制哈希，拒绝覆盖后来变化的程序，只恢复旧二进制及当时运行状态；
不覆盖之后修改的配置。原始文件归档 `original-files.tar` 供人工恢复，不自动解压覆盖。
升级和回滚会短暂中断连接，不能承诺进程内待报增量零损失。脚本不会修改数据库或面板
累计流量。服务稳定只是一层检查，还要核对实际连接、节点回执、流量增量、在线统计和
到期/流量用尽撤权。原 shell 管理器保留；不要使用其上游更新/重装功能覆盖二开。

隔离夹具检查命令：

```sh
bash tools/packaging/test-legacy-upgrade.sh
```

夹具在临时目录做真实文件替换和备份，模拟编译器与服务管理器；覆盖配置/证书/路由保留、
运行与停止状态、systemd/OpenRC、失败回滚、重启循环及过期备份拒绝。它不代替真实节点业务测试。

## 工具验证

已用真实离线构建脚本生成 Linux/amd64 bundle（Go 1.26.5），再在没有隔离服务的
本地验证环境运行以下命令，13 项检查通过：

```sh
bash tools/packaging/test-packaging.sh --bundle /absolute/path/to/built-bundle
```

覆盖脚本语法、默认 dry-run、`--start` 不隐式写入、冲突参数、错误哈希、错误版本、
组件篡改、清单路径穿越、非法回滚路径和无系统目录创建。夹具保留在输出的临时目录，
这些夹具不执行真实系统的 `--apply`，不能单独作为实机验收。

2026-10-16 另在授权的 Linux amd64/HY2 测试机验证了公开脚本：菜单入口的现有独立
配置升级路径、重复更新不重启，以及原版标准目录的停止/运行状态原位升级和显式回滚。
原版基线使用未二开的上游 `71277de` 构建，升级脚本代码为 `c3284cb`。
配置、证书、路由及原服务文件哈希保持一致；TLS 校验、Salamander 混淆 TCP/UDP
通信通过，原位升级后二开上报的双向增量与探针各 665360 字节精确一致，在线统计正常。
此结果仅覆盖该 HY2 测试配置。全新空服务器的完整交互向导、OpenRC 和其他节点协议
仍以对应夹具/构建结果为限，不代表已全部真机验收。

根入口另有独立夹具测试：

```sh
bash tools/packaging/test-entrypoint.sh
```

本次本地 24 项入口检查通过，另复用原 13 项打包检查。
入口夹具使用真实 Git 本地提交和真实 bundle 生成脚本，但替代了 Go 编译、远端下载、
依赖下载和服务管理命令；`--apply` 只转发到模拟安装器，没有访问系统安装目录。
覆盖固定自有仓库、完整提交比对、干净源码、Go/jsonv2/源码最低补丁版本、
显式依赖下载、源码被依赖命令修改时拒绝、模式冲突以及固定测试服务管理。
这些结果不能当成真实 Linux root/systemd 安装或真实节点接入测试。

菜单/配置向导另外运行：

```sh
bash tools/packaging/test-menu.sh
python3 tools/packaging/test-configure-node.py
```

覆盖无需依赖打开菜单、失败返回、多内核节点配置、追加保留、重复校验、导入保留
混淆及未知选项、密钥不回显、配置文件权限、Go 官方下载项选择及补丁版本比较。
