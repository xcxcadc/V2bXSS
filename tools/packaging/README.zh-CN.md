# 隔离测试节点构建、安装与回滚

此目录的离线脚本安装本分支二开，不调用上游一键脚本，也不下载二进制或依赖。
只管理 `V2bX-audit-test.service`，不管理现有 `V2bX.service`、`/etc/V2bX`、面板或数据库。
安装和回滚默认都只校验并打印计划；必须显式 `--apply` 才写入，另加 `--start` 才启动。
构建脚本会写入显式指定的新输出目录，不修改源目录。

## 本仓库安装入口

根目录 [install.sh](../../install.sh) 是 `xcxcadc/V2bXSS` 自己的安装入口，
从完整提交 SHA 构建再调用本目录的隔离安装器，不假设存在预编译 Release，
不会执行上游安装器或未校验的远端脚本管道。
审计功能的使用见 [使用说明](../../docs/USAGE.zh-CN.md)。

前提是已安装 Go、Git、GNU 工具。Go 需要满足选定源码 `go.mod` 的最低版本，
并支持 `GOEXPERIMENT=jsonv2`（当前源码至少 Go 1.25）。
不存在 Go、版本不足或不支持实验开关时，入口准确报错，不替换系统 Go，
不使用 Go 的自动工具链下载。实际安装仍要求 Linux root、匹配架构及 systemd。

推荐先从 `xcxcadc/V2bXSS` 的 `dev_new` 分支获取并审阅源码，记录完整提交 SHA：

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

状态和最近 100 条日志只读取 `V2bX-audit-test.service`；启动、重启和停止必须加 `--apply`。
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
构建标签包括 Xray、sing-box、原生 HY2 及已经验证的依赖选项，不含 `with_grpc`。
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
| 每个版本 | `/opt/v2bx-audit-test/releases/<version>/` |
| 当前版本 | `/opt/v2bx-audit-test/current` |
| 测试配置 | `/etc/v2bx-audit-test/config.json` |
| 独立服务 | `/etc/systemd/system/V2bX-audit-test.service` |
| 每次安装前备份 | `/var/backups/v2bx-audit-test/<UTC时间>-<version>-<PID>/` |

升级时使用新版本名并省略 `--config`，已有配置会保留；同名版本拒绝覆盖。
脚本验证二进制、清单、完整五项文件哈希、版本、目标架构以及路径类型。
备份先于版本切换，包含旧版本副本、旧配置和 unit、旧服务状态以及回滚脚本。
脚本不删除旧版本、备份或证据。没有 `--start` 时，已运行的进程继续使用旧二进制。
如果中途失败，查阅已经打印的备份路径和当前链接，不能假定自动回滚已经完成。

## 回滚

从安装输出取得确切备份目录，先打印计划：

```sh
bash /var/backups/v2bx-audit-test/<备份名>/rollback-test-node.sh \
  --backup /var/backups/v2bx-audit-test/<备份名>
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
本工具是隔离测试安装入口，不是可覆盖任意既有节点的一键迁移器。

## 工具验证

已用真实离线构建脚本生成 Linux/amd64 bundle（Go 1.26.5），再在没有隔离服务的
本地验证环境运行以下命令，13 项检查通过：

```sh
bash tools/packaging/test-packaging.sh --bundle /absolute/path/to/built-bundle
```

覆盖脚本语法、默认 dry-run、`--start` 不隐式写入、冲突参数、错误哈希、错误版本、
组件篡改、清单路径穿越、非法回滚路径和无系统目录创建。夹具保留在输出的临时目录，
测试不执行 `--apply`。真实 Linux root/systemd 安装/回滚尚未在本轮本地执行，
不能把这些校验当成测试节点真实服务启动、数据上报或全部客户端的验收。

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
