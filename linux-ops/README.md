# lops — Linux 运维工具箱

> 一个入口集成所有基础运维能力：交互菜单一键执行，子命令直达自动化。
> 适用于 Ubuntu/Debian 与 CentOS/RHEL/Rocky/AlmaLinux。

## 快速开始

```bash
# 交互式主菜单（编号选择，一键执行）
bash lops.sh

# 子命令模式（适合脚本/自动化）
bash lops.sh init all                    # 新服务器一键初始化
bash lops.sh monitor check               # 一键健康巡检
bash lops.sh info all                    # 硬件信息报表

# 帮助体系
bash lops.sh help                        # 总帮助（模块清单+示例）
bash lops.sh disk help                   # 任意模块的详细帮助
```

## 模块总览

| 模块       | 能力        | 常用动作                                                                |
| -------- | --------- | ------------------------------------------------------------------- |
| init     | 系统初始化     | `all`（时区/NTP/locale/limits/history/unattended 加固/管理用户）           |
| user     | 用户管理      | `add` / `del` / `passwd` / `sudo` / `list`                          |
| ssh      | SSH 安全    | `keygen` / `pushkey`（批量铺公钥）/ `harden` / `audit`                     |
| info     | 信息报表      | `all` / `os` / `net` / `gpu`（全部只读）                                  |
| disk     | 磁盘管理      | `ls` / `mount`（格式化+挂载+fstab）/ `uuid` / `test`（fio）/ `health`（SMART） |
| monitor  | 监控巡检      | `check`（一键巡检）/ `top` / `node_exporter` / `disk_monitor`             |
| network  | 网络测试      | `server`/`client`（iperf3）/ `mtr` / `speed` / `ports`                |
| docker   | Docker 环境 | `install` / `status` / `mirror` / `clean` / `ps`                    |
| backup   | 备份清理      | `dir`（打包+轮转）/ `cleanlog`（journald）/ `old`（过期清理）                     |
| security | 安全巡检加固    | `check`（安全巡检）/ `harden`（交互加固）/ `fail2ban` / `firewall`              |
| process  | 进程端口排查    | `top`（资源Top10）/ `port` / `kill` / `zombies` / `tree`                |

## 目录结构

```text
linux-ops/
├── lops.sh                 # 唯一总入口（模块自动发现）
├── lib/
│   ├── common.sh           # 颜色/日志/OS 检测/权限校验/确认交互/报表输出
│   └── ui.sh               # 菜单渲染
├── modules/                # 15 大功能模块（新增模块即放即用）
│   ├── init.sh  user.sh  ssh.sh  info.sh  disk.sh  security.sh
│   ├── monitor.sh  network.sh  docker.sh  backup.sh  doctor.sh  process.sh
│   └── log.sh  pkg.sh  cron.sh
└── assets/
    └── disk_health_monitor.sh   # 磁盘健康监控素材（被 monitor 模块部署）
```

## 新增模块

在 `modules/` 下新建 `xx.sh`，实现 4 个接口函数即可被入口自动发现：

```bash
mod_xx_desc()     { echo "一句话描述"; }
mod_xx_actions()  { echo "动作|说明"; }
mod_xx_help()     { cat <<EOF ... 详细帮助 ... EOF; }
mod_xx_run()      { case "$1" in ... esac; }   # 动作分发
```

公共能力（日志/颜色/确认/备份/包安装等）一律复用 `lib/common.sh`。

## 设计约定

- **双模式**：交互菜单覆盖人工操作，子命令覆盖自动化场景

- **危险操作二次确认**：格式化磁盘、删用户、删文件等必须输入 `y` 才执行

- **改前备份**：fstab/sshd\_config/sudoers 等修改前自动备份 `*.bak.<时间戳>`

- **幂等**：init 等动作重复执行不破坏已有配置

- **不硬编码**：所有 IP/路径/阈值均参数化或环境变量化

- **日志留痕**：全部操作记录到 `/var/log/lops/lops.log`

## 旧脚本归档说明

原 `Linux/scripts/`、`Linux/ubuntu/`、`Linux/iperf3/`、`Linux/toolkit/` 中的
通用能力已吸收进 lops 各模块（功能对照见各模块 help 的“参考”部分），
原文件已归档至 `Linux/.trash/`，需要历史实现时可查阅。
