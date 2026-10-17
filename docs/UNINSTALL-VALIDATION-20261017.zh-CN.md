# 独立安装卸载入口验收（2026-10-17）

新增菜单 **13. 卸载 V2bXSS** 与 `v2bxss uninstall [--apply | --dry-run]`。
不加 `--apply` 仅打印计划；执行仍需输入 `UNINSTALL`。配置、证书、程序和缓存
原子移入 root 私有的卸载备份，附带需输入 `RESTORE` 才执行的恢复脚本。
该命令仅处理 `/etc/v2bxss` 独立安装，不接管原版或其他服务。

受测源码：私有维护提交 `8d2294db469ea5d7e575448febc11368485fadc3`，
管理器 SHA256 为 `f8744488a436c0ff30cc9ab6854d72188eb79d1f66ce37fd94446e0506d82164`。
同步公开仓库时仅取本批脱敏的管理脚本、测试及文档，不发布运行配置或任何密钥。

## 已通过

- 菜单/日志/卸载预览：10 项检查；打开菜单、取消输入及预览不依赖网络、Go 或源码副本。
- 卸载/恢复：17 个远端隔离场景。使用真实文件移动与备份，systemctl 为替身，
  `/etc`、`/opt`、`/usr/local/bin` 和 `/var/backups` 均由独立 mount namespace 遮蔽。
- 覆盖运行与停止状态、取消与 EOF、交互菜单完成退出、drop-in、异常程序路径、unit/备份符号链接、
  占用操作锁、跨文件系统拒绝、stop/disable/reload 失败恢复、恢复启动失败、拒绝覆盖新安装、仅管理器安装。
- 每个卸载场景均核对原版节点、外部证书、历史备份不变；正常恢复后配置/证书/程序哈希一致。
- 既有安装入口 24 项及其复用的打包保护 13 项通过；Go 编译、网络和 systemctl 均由替身隔离。
- 另复测 6 个目录布局场景：repair、fresh、install-failed-start、stopped、failed-switch、custom-unit。
- 授权测试节点仅更新管理器，实际验证卸载预览和取消路径；运行进程 PID、配置/二进制/unit 哈希及
  开机自启状态均未变化，未重启节点。

## 边界

没有对正在服务的真实节点执行卸载。真正卸载会主动停止服务并中断连接，不能保证尚未成功上报的
内存流量零损失，应先核对上报。隔离卸载和替身测试不等于所有 Linux 发行版/systemd 版本实机验收。
不永久清除含密钥的备份，不操作面板/数据库、防火墙、系统工具链或原版原位升级目录。

已有安装只刷新菜单，无需重编译/重启：

```sh
wget -N https://raw.githubusercontent.com/xcxcadc/V2bXSS/dev_new/install.sh && bash install.sh repair
v2bxss
```
