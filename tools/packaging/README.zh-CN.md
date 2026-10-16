# 隔离测试节点构建、安装与回滚

这里的脚本安装本分支二开，不调用上游一键脚本，也不下载二进制或依赖。
只管理 `V2bX-audit-test.service`，不管理现有 `V2bX.service`、`/etc/V2bX`、面板或数据库。
安装和回滚默认都只校验并打印计划；必须显式 `--apply` 才写入，另加 `--start` 才启动。
构建脚本会写入显式指定的新输出目录，不修改源目录。

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
当前仅提供已有面板 `routes` 的只读清单；复制到新模块不代表接管原静态规则。
因此不能声称在新页面删除副本就删除了节点原默认规则。
也没有完成全部入站协议、所有真实客户端、arm64 或生产支付链路的完整验收。
本工具是隔离测试安装入口，不是可覆盖任意既有节点的一键迁移器。

## 本轮工具验证

已用真实离线构建脚本生成 Linux/amd64 bundle（Go 1.26.5），再在没有隔离服务的
本地验证环境运行以下命令，13 项检查通过：

```sh
bash tools/packaging/test-packaging.sh --bundle /absolute/path/to/built-bundle
```

覆盖脚本语法、默认 dry-run、`--start` 不隐式写入、冲突参数、错误哈希、错误版本、
组件篡改、清单路径穿越、非法回滚路径和无系统目录创建。夹具保留在输出的临时目录，
测试不执行 `--apply`。真实 Linux root/systemd 安装/回滚尚未在本轮本地执行，
不能把这些校验当成测试节点真实服务启动、数据上报或全部客户端的验收。
