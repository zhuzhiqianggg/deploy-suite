# 10. NFS 高可用集群搭建与数据迁移（DRBD + Keepalived + NFS）

| 属性 | 值 |
|------|-----|
| 优先级 | **P0**（NFS 是全集群存储单点，且压在 master01 上） |
| 风险等级 | 分阶段控制：P1/P2 零风险（不碰生产数据）→ P3 演练 → P4 逐业务秒级窗口 |
| 前置条件 | 两台新 VM 创建完成（规格见 §2） |
| 观察期 | failover 演练通过 + 每业务切换后 30 分钟 |
| 状态 | ⬜ 待实施（VM 待创建） |
| **本文档定位** | **生产环境（华为云）1:1 复制的执行手册**，所有命令已固化参数，生产执行时仅替换 §9 列出的差异项 |

---

## 1. 背景与目标

**现状（测试与生产完全相同的问题）**：NFS 服务端跑在 master01 本地磁盘（`/data/nfs`，LVM 单卷 139G/用 59G），44 个 PV 中 43 个指向它——**一台 VM 身兼 etcd 成员 + apiserver + sealos.hub registry + NFS 服务端四职**，是全集群最大的单点。

**目标**：

1. 两台专用 NFS 服务器，块级实时同步（DRBD 协议 C），VIP 故障切换（RTO < 10 秒，RPO = 0）
2. 逐业务平滑迁移，每业务中断窗口 = 一次滚动重启（秒级），集群整体不停服
3. 迁移后 master01 数据保留转为每日备份 → **具备误删恢复能力**（HA 防硬件故障，备份防误删，两者互补）
4. 测试环境全流程验证后，本手册在生产（华为云）原样执行

**架构原理（学习点）**：

```
                        VIP: 192.168.10.130 (nfs-ha.lianan.local)
                                  │ Keepalived VRRP 秒级浮动
                  ┌───────────────┴───────────────┐
                  │                               │
          nfs01: 192.168.10.131            nfs02: 192.168.10.132
          DRBD Primary + NFS active        DRBD Secondary + NFS 待命
                  │                               │
                  └──── /dev/drbd0 块级实时同步（协议C）────┘
                          （两台各有独立数据盘 /dev/sdb 150G）

层叠关系:  Keepalived(选主) → DRBD(数据层) → ext4(文件系统) → NFS(服务层)
失败语义:  NFS01 宕 → Keepalived 3 秒内检测 → notify 脚本在 NFS02 上
          DRBD 提升 Primary → 挂载 → 启动 NFS → 客户端重连 VIP 恢复
```

- **为什么是 DRBD 而不是 rsync**：DRBD 复制的是磁盘块，两边的 inode/文件句柄完全一致——failover 后 NFS 客户端 TCP 重连即可恢复，Pod 多数无需重启；rsync 是异步文件级，故障瞬间会丢最后几分钟数据且句柄全变
- **为什么 PV 要重建**：PV 的 `spec.nfs.server` 不可变，指向 `.100` 的 43 个 PV 必须换成新地址重建（这是逐业务切换存在秒级窗口的唯一原因）
- **为什么新 PV 用 DNS 名而不是 IP**：本次迁移后，未来任何存储后端变更只需改一条 DNS 记录，PV 永不再重建

---

## 2. 服务器规划

### 2.1 地址分配（2026-08-25 实际部署值）

| 角色 | 主机名 | IP | 说明 |
|------|--------|-----|------|
| NFS 主节点 | k8s-test-nfs01 | 192.168.10.131 | Keepalived MASTER (priority 150) |
| NFS 备节点 | k8s-test-nfs02 | 192.168.10.132 | Keepalived BACKUP (priority 100) |
| **VIP（浮动）** | nfs-ha.lianan.local | 192.168.10.130 | PV 中的 server 字段统一写此 DNS 名 |
| 旧 NFS | k8s-test-master01 | 192.168.10.100 | 迁移完成后退役 → 转备份节点 |

> ⚠️ .120/.121/.123 已被网内其他设备占用（2026-08-25 探测），不要使用。

### 2.2 VM 创建规格（2026-08-25 实际部署值，模板克隆方式）

| 项 | 规格 | 关键说明 |
|----|------|---------|
| CPU / 内存 | 4 vCPU / 8G | NFS+DRBD 内核态服务，测试环境足够；生产建议 8C/16G |
| 磁盘 | **单盘 100G**（模板克隆自带） | sda2 24G 挂 `/`，**sda3 75G 给 DRBD**（实测路径） |
| 系统 | Ubuntu 24.04 LTS（noble）| **与生产一致**；模板内核 6.8.0-40 已升到 **6.8.0-124**（安全补丁欠账 + DRBD 9.3.3 适配） |
| **Secure Boot** | **已在 vSphere 关闭并冷启动** | DRBD 自编译模块未签名，SB 开启时报 `Key was rejected by service` |
| IP 配置 | 静态 | .131/.132，网关 192.168.10.1，网卡 ens33 |

> **容量说明**：DRBD 卷 75G vs 现有数据 59G，余量 27% 偏紧。若后续增长，VMware 扩 sda 盘后在两台执行 `drbdadm down nfs && parted resizepart` + `drbdadm create-md` 重建（或加第二块盘换 disk 路径）。当初规划的"独立 150G 数据盘"未采用（用户模板机为单盘），生产建议直接用独立 EVS 数据盘 200G。

### 2.3 磁盘与资源布局（两台一致，实测）

```
/dev/sda  100G  单盘
├─sda1    1G    EFI 分区
├─sda2    24G   / （ext4，非 LVM）
└─sda3    75G   DRBD 后端（独立分区，DRBD 独占）
/dev/drbd0      DRBD 块设备（仅 Primary 侧可挂载，ext4 label=nfs-data）
/data/nfs       挂载点（与 master01 路径完全一致 → 迁移时 rsync 路径对齐）
```

---

## 3. P1 基础设施部署（已完成 ✅ 2026-08-25）

### 3.0 Ubuntu 24.04 安装 DRBD 内核模块（⭐ 本次最大的实测坑，生产 1:1 复用）

**问题**：Ubuntu noble 官方源（main/universe 全组件）**没有 `drbd-dkms` 包**（jammy/focal 也没有——只有 `drbd-utils` 和 `drbd-doc`；Debian bookworm 同样没有）。DRBD 内核模块的正规渠道只有 LINBIT 订阅源和 ELRepo（RHEL 系）。`packages.linbit.com` 目录可浏览但 **deb 下载 403**（需订阅）。GitHub 直连不通。

**实测可用路径（国内网络）**：

```bash
# 1) 源码 clone（gitcode.com 是 GitHub 的国内镜像，可直连）
git clone --depth 1 https://gitcode.com/gh_mirrors/dr/drbd.git /root/drbd-src
# 实测拿到的是最新版 9.3.3（2026-08 提交，正是 LINBIT 最新发布）

# 2) drbd-headers submodule（gitcode 无此镜像 403；用 gh-proxy.com 代理 GitHub 直链）
#    ⚠️ 必须用 drbd 9.3.3 锚定的 commit 32c2e60...，master 分支的 headers 与 9.3.3 声明清单不匹配会报 only-in-git/only-in-kbuild
cd /root/drbd-src
git rm --cached drbd/drbd-headers                      # 移除 gitlink
curl -LO "https://gh-proxy.com/https://github.com/LINBIT/drbd-headers/archive/32c2e607f3c496453ba2213440c66cbbeec98197.tar.gz"
tar xzf 32c2e60*.tar.gz -C /tmp
mv /tmp/drbd-headers-32c2e60* drbd/drbd-headers
git add drbd/drbd-headers                              # 转为普通文件，绕过 submodule 机制

# 3) 编译依赖（noble 官方源都有）
apt-get install -y gcc make coccinelle linux-headers-$(uname -r)
#    ⚠️ coccinelle（spatch）是 DRBD 9.3.x 构建硬依赖（生成 compat patch），缺失报 Makefile.spatch 错误

# 4) 编译 + 安装
cd /root/drbd-src
make -j$(nproc)                  # 成功标志: "Module build was successful."
make install                     # 装到 /lib/modules/$(uname -r)/updates/
depmod -a                        # make install 报 missing System.map 跳过 depmod，需手工补

# 5) 开机自动加载
cat > /etc/modules-load.d/drbd.conf <<EOF
drbd
drbd_transport_tcp
EOF
```

**SecureBoot（VMware 环境专属步骤）**：自编译模块未签名，`modprobe drbd` 报 `Key was rejected by service`。处理：vSphere 关闭 VM 的 Secure Boot 并**冷启动**（完全关机再开机，热重启不生效），之后 modprobe 成功。华为云 ECS 无 SB 问题。

**userspace 工具**：`apt-get install -y drbd-utils`（noble 官方 9.22.0，与 kernel 9.3.3 兼容）。安装后 `systemctl disable --now drbd.service` 再 **`systemctl enable drbd.service`**——它只负责开机 `drbdadm up`（attach 资源，不提升角色），promote 交给 keepalived notify。

**踩坑记录（详见 §11）**：
- DRBD 9.3.x 的 `/proc/drbd` **不再输出资源状态行**（只有 version 头），角色判断必须用 `drbdadm status`——check/notify 脚本初版用 `grep "^ 0:" /proc/drbd` 全部失效
- check 脚本必须对**无 VIP 的 BACKUP 节点直接放行**，否则 BACKUP 因缺"Primary+挂载+NFS"三件套被误判 FAULT，造成主备来回震荡
- 模板机 24.04 的 unattended-upgrades 会长时间占 apt 锁，`pkill -f apt.systemd.daily` 后重试；分区用 sfdisk 绕过装 parted
- Ubuntu 重启清空 /tmp，源码树放 /root



> 本阶段全程在两台新 VM 上操作，与现有集群唯一的接触是网络连通。所有命令按序号执行，每步带验证。

### 3.1 系统初始化（两台都做，以 nfs01 为例，nfs02 同样）

```bash
# --- 主机名（安装时若已设则跳过）---
hostnamectl set-hostname k8s-test-nfs01        # nfs02 上改为 k8s-test-nfs02

# --- 互信 hosts（两台都写）---
cat >> /etc/hosts <<'EOF'
192.168.10.131 k8s-test-nfs01 nfs01
192.168.10.132 k8s-test-nfs02 nfs02
192.168.10.130 nfs-ha.lianan.local nfs-ha
EOF

# --- SSH 免密（master01 → 两台 NFS，数据同步要用；nfs01 ↔ nfs02，DRBD/巡检要用）---
# 在 master01 上：
ssh-copy-id root@192.168.10.131
ssh-copy-id root@192.168.10.132
# 在 nfs01 上：
ssh-copy-id root@192.168.10.132
# 在 nfs02 上：
ssh-copy-id root@192.168.10.131

# --- 基础包（两台）---
apt-get update
apt-get install -y chrony drbd-utils drbd-dkms nfs-kernel-server keepalived rsync

# --- 时钟同步（复用 ntp-sync-manager 体系，手工版）---
# 编辑 /etc/chrony/chrony.conf 保证 pool 指向国内源，然后：
systemctl enable --now chrony
chronyc sources -v | head -n 12        # 预期：^* 某 NTP 源（已同步）

# --- 时间同步 vmtools（VMware 环境）---
vmware-toolbox-cmd timesync disable    # 防止 ESXi 时钟干扰（历史教训）
```

### 3.2 DRBD 内核模块加载（两台都做）

```bash
# 加载模块
modprobe drbd
lsmod | grep drbd
# 预期：drbd 380928 ...（模块已加载）
# ⚠️ 若报 "Key was rejected by service" → Secure Boot 未关，回 VM 设置关闭后重启

# 开机自动加载
echo "drbd" > /etc/modules-load.d/drbd.conf

# 确认版本
modinfo drbd | grep -E "^version|^filename"
# 预期：version: 9.x.x
```

### 3.3 DRBD 资源配置（两台配置文件完全相同）

```bash
# --- 全局配置（两台相同）---
cat > /etc/drbd.d/global_common.conf <<'EOF'
global {
    usage-count no;          # 不上报使用统计（离线环境）
}
common {
    net {
        protocol C;          # 同步复制：本地写盘+对端确认才算完成 → RPO=0
        verify-alg sha256;   # 网络校验，防位翻转
        connect-int 10;      # 断线重连间隔（秒）
        ping-int 5;          # 心跳间隔
        timeout 30;          # 对端无响应判定超时
    }
    disk {
        resync-rate 120M;    # 初始同步限速（避免打满网卡；千兆网可调 80-150M）
        on-io-error detach;  # 磁盘错误时脱离设备（数据安全优先）
    }
}
EOF

# --- NFS 资源定义（两台相同）---
cat > /etc/drbd.d/nfs.res <<'EOF'
resource nfs {
    on k8s-test-nfs01 {
        address  192.168.10.131:7789;
        device   /dev/drbd0;
        disk     /dev/sda3;
        meta-disk internal;
    }
    on k8s-test-nfs02 {
        address  192.168.10.132:7789;
        device   /dev/drbd0;
        disk     /dev/sda3;
        meta-disk internal;
    }
}
EOF

# --- 数据分区（实测：模板机单盘，sda3 用 sfdisk 从剩余空间创建；生产独立数据盘则用整块 /dev/sdb）---
echo ",+" | sfdisk --no-reread -N 3 /dev/sda    # sda3 = 剩余全部 75G
partx -a /dev/sda
lsblk /dev/sda                 # 预期：└─sda3 75G part
# ⚠️ sfdisk 直接用（装 parted 会被 unattended-upgrades 的 apt 锁卡住）

# --- 创建 DRBD 元数据（两台都做）---
drbdadm create-md nfs
# 预期输出含：success

# --- 启动资源（两台都做）---
drbdadm up nfs
drbdadm status nfs
# ⚠️ DRBD 9.3.x 的 cat /proc/drbd 只有 version 头（无资源状态行）！
# 预期（状态查询一律用 drbdadm status）：
#   nfs role:Secondary
#     peer-disk:Inconsistent
# （连接已建立，双 Secondary，数据未同步——正常初始状态）
```

### 3.4 初始同步 + 创建文件系统（**只在 nfs01 执行**）

```bash
# --- nfs01 强制提升 Primary，触发全盘初始同步 ---
drbdadm primary nfs --force
drbdadm status nfs
# 预期：
#   nfs role:Primary
#     k8s-test-nfs02 role:Secondary
#       replication:SyncSource peer-disk:Inconsistent done:1.30
# done 百分比持续增长（75G @resync-rate 120M ≈ 11 分钟）
# 同步完成标志：peer-disk:UpToDate 且 replication 行消失

# --- 创建 ext4 文件系统（一次性，之后永不重做）---
mkfs.ext4 -L nfs-data /dev/drbd0

# --- 挂载点（两台都建目录，但只在 nfs01 挂载）---
mkdir -p /data/nfs
mount /dev/drbd0 /data/nfs
df -h /data/nfs            # 预期：/dev/drbd0 74G ...
# nfs02 上：目录建好但不挂载（failover 时 notify 脚本自动挂）
```

### 3.5 NFS 服务配置（两台相同；先不启动，由 keepalived 接管启停）

```bash
# --- exports：逐字复制 master01 的导出配置 ---
cat > /etc/exports <<'EOF'
/data/nfs *(rw,sync,no_root_squash,no_subtree_check)
EOF
# 注意：no_root_squash 必须保留——k8s 容器以 root 写数据依赖它
# （生产环境安全加固见 §9：将 * 替换为集群节点网段）

# --- 固定 NFS 辅助端口（为生产安全组预铺路，测试环境顺手做了保持两环境一致）---
cat >> /etc/nfs.conf <<'EOF'
[mountd]
port=20048
[statd]
port=20049
EOF

# --- nfs01 上手动启动一次验证（keepalived 上线前的自检）---
systemctl start nfs-kernel-server
exportfs -v
# 预期：/data/nfs <world>(rw,sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash)
showmount -e 127.0.0.1
# 预期：Export list ...: /data/nfs

# --- 验证后停掉并禁用自启（启停权交给 keepalived notify 脚本！）---
systemctl stop nfs-kernel-server
systemctl disable nfs-kernel-server
# ⚠️ 关键：NFS 服务不能开机自启（两台都是），否则故障切换时可能出现双活写
```

### 3.6 Keepalived 配置（VIP 浮动 + NFS 启停联动）

```bash
# --- 健康检查脚本（两台相同）---
install -m 755 /root/k8s-optimizations/optimization-plan/scripts/nfs-ha/keepalived-nfs-check.sh /etc/keepalived/nfs-check.sh

# --- 状态切换脚本（两台相同；keepalived 调用它做 DRBD提升/挂载/NFS启停）---
install -m 755 /root/k8s-optimizations/optimization-plan/scripts/nfs-ha/keepalived-nfs-notify.sh /etc/keepalived/nfs-notify.sh

# --- nfs01 配置（MASTER）---
cat > /etc/keepalived/keepalived.conf <<'EOF'
vrrp_script chk_nfs {
    script "/etc/keepalived/nfs-check.sh"   # 检查 DRBD Primary + 挂载 + NFS 进程
    interval 2                               # 每 2 秒检查
    fall 2                                   # 连续 2 次失败才判死（防抖）
    rise 2
}

vrrp_instance VI_NFS {
    state MASTER
    interface ens33                          # ⚠️ 按实际网卡名改（ip route 查默认路由网卡）
    virtual_router_id 60                     # 子网内唯一（已排查无其他 keepalived）
    priority 150                             # nfs01 优先
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass Lian@NFS7                  # 两台必须一致
    }
    virtual_ipaddress {
        192.168.10.130/24
    }
    track_script {
        chk_nfs
    }
    notify "/etc/keepalived/nfs-notify.sh"   # MASTER/BACKUP 切换时执行
}
EOF

# --- nfs02 配置（BACKUP，仅三处不同）---
# state BACKUP / priority 100，其余与 nfs01 完全一致

# --- 启动（两台）---
systemctl enable --now keepalived
systemctl status keepalived --no-pager | head -n 8

# --- 验证 VIP 落在 nfs01 ---
ip addr show ens33 | grep "192.168.10.130"
# 预期：只在 nfs01 上出现 VIP；nfs02 上无
```

### 3.7 集群侧 DNS 就绪（新 PV 用 `nfs-ha.lianan.local` 的前提）

```bash
# --- 8 个 k8s 节点的 /etc/hosts 都追加（kubelet 解析静态 PV 的 server 用）---
# 在 master01 上批量（本机直跑+ssh 其余 7 台）：
for h in 192.168.10.100 192.168.10.101 192.168.10.102 192.168.10.103 192.168.10.104 192.168.10.105 192.168.10.106 192.168.10.107; do
  ssh root@$h 'grep -q "nfs-ha.lianan.local" /etc/hosts || echo "192.168.10.130 nfs-ha.lianan.local nfs-ha" >> /etc/hosts'
done

# --- CoreDNS 加 hosts 段（CSI 类 PV 由 pod 内 DNS 解析）---
kubectl -n kube-system edit cm coredns
# 在 Corefile 任意 server 块内（如 .:53 { 内部、forward 之前）插入：
#     hosts {
#         192.168.10.130 nfs-ha.lianan.local
#         fallthrough
#     }
kubectl -n kube-system rollout restart deploy coredns

# --- 验证双链路解析 ---
kubectl run dns-check --rm -it --image=busybox:1.36 --restart=Never -- nslookup nfs-ha.lianan.local
# 预期：192.168.10.130
ssh root@192.168.10.101 'getent hosts nfs-ha.lianan.local'
# 预期：192.168.10.130 nfs-ha.lianan.local
```

### 3.8 Failover 演练（P1 的验收测试）

```bash
# --- 1. 在任一 k8s 节点通过 VIP 挂载测试 ---
mkdir -p /mnt/nfs-ha-test
mount -t nfs 192.168.10.130:/data/nfs /mnt/nfs-ha-test
echo "failover-test-$(date +%s)" > /mnt/nfs-ha-test/ha-test.txt
cat /mnt/nfs-ha-test/ha-test.txt        # 预期：正常读写

# --- 2. 模拟 nfs01 故障（停 keepalived 即可触发）---
ssh root@192.168.10.131 'systemctl stop keepalived'
# 观察 VIP 漂移（在 nfs02 上）：
ssh root@192.168.10.132 'ip addr show ens33 | grep 192.168.10.130'   # 预期：VIP 出现
# 时序：3 秒内完成 DRBD提升→挂载→NFS启动（看 nfs02 的 /var/log/syslog）

# --- 3. 通过 VIP 验证数据连续性（挂载点自动重连，无需重新 mount）---
cat /mnt/nfs-ha-test/ha-test.txt        # 预期：步骤1写入的内容仍在（DRBD 已同步）
echo "after-failover-$(date +%s)" >> /mnt/nfs-ha-test/ha-test.txt     # 新写入（落在 nfs02）

# --- 4. nfs01 恢复，VIP 回切（优先级抢占）---
ssh root@192.168.10.131 'systemctl start keepalived'
sleep 5
ssh root@192.168.10.131 'ip addr show ens33 | grep 192.168.10.130'    # 预期：VIP 回到 nfs01
cat /mnt/nfs-ha-test/ha-test.txt        # 预期：含 after-failover 行（nfs02 的写已同步回来）
# ⚠️ 生产建议 nopreempt（不回切）减少一次切换，见 §9

# --- 5. 清理 ---
umount /mnt/nfs-ha-test && ssh root@192.168.10.131 'rm /data/nfs/ha-test.txt'
```

**P1 验收标准**：上述 5 步全部通过 = NFS HA 基础设施就绪，可进入数据迁移。

---

## 4. P2 数据预同步（业务零感知）

```bash
# --- 1. 全量同步（master01 → nfs01，59G 约 30-60 分钟，只读源无风险）---
# 使用脚本（自动 echo 命令 + 统计 + 校验）：
bash /root/k8s-optimizations/optimization-plan/scripts/nfs-ha/nfs-data-sync.sh --full
# 内部执行：rsync -aHAX --numeric-ids --info=progress2 /data/nfs/ root@192.168.10.131:/data/nfs/

# --- 2. 增量同步 crontab（master01 上，每 5 分钟，保持接近零差量）---
# 1-56/5 * * * * /root/k8s-optimizations/optimization-plan/scripts/nfs-ha/nfs-data-sync.sh --incremental >> /var/log/nfs-sync.log 2>&1
# （不加 --delete：同步期间源删了文件镜像保留，切换时最终同步才处理删除）

# --- 3. 差量校验（每日人工抽查一次）---
bash /root/k8s-optimizations/optimization-plan/scripts/nfs-ha/nfs-data-sync.sh --verify
# 预期：diff 差量文件数为 0 或个位数（最近5分钟的写入）
```

---

## 5. P3 演练切换（选 kuboard：低价值、单 PV、影响面最小）

```bash
# --- 1. 找到 kuboard 的 PV/PVC 和使用方 ---
kubectl get pv | grep kuboard
kubectl -n kuboard get pvc                   # 假设为 kuboard-pvc / PV: kuboard-pv

# --- 2. 最终差量同步（该目录，带 --delete）---
ssh root@192.168.10.100 "rsync -aHAX --delete --numeric-ids /data/nfs/kuboard/ root@192.168.10.131:/data/nfs/kuboard/"
# 校验：rsync --dry-run 再跑一次，无输出 = 完全一致

# --- 3. 新建 PV（server 写 DNS 名）+ 新 PVC ---
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: kuboard-pv-ha
spec:
  capacity: {storage: 20Gi}
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  nfs:
    server: nfs-ha.lianan.local        # ⭐ DNS 名，此后存储迁移永不再重建 PV
    path: /data/nfs/kuboard
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: kuboard-pvc-ha
  namespace: kuboard
spec:
  accessModes: [ReadWriteMany]
  resources: {requests: {storage: 20Gi}}
  volumeName: kuboard-pv-ha
EOF

# --- 4. 切换工作负载引用（patch deployment 的 volumes）---
kubectl -n kuboard patch deployment kuboard -p '{"spec":{"template":{"spec":{"volumes":[{"name":"<原volume名>","persistentVolumeClaim":{"claimName":"kuboard-pvc-ha"}}]}}}}'
# （volume 名用 kubectl -n kuboard get deploy kuboard -o jsonpath='{.spec.template.spec.volumes[0].name' 查）
# patch 即触发滚动重启 = 秒级中断窗口

# --- 5. 验证 ---
kubectl -n kuboard rollout status deployment kuboard --timeout=120s
kubectl -n kuboard get pods -o wide
# 功能验证：浏览器访问 kuboard 确认数据完整（看板/用户都在）

# --- 6. 回滚演练（P3 必做！确认回滚路径通畅）---
kubectl -n kuboard patch deployment kuboard -p '{"spec":{"template":{"spec":{"volumes":[{"name":"<原volume名>","persistentVolumeClaim":{"claimName":"kuboard-pvc"}}]}}}}'
# 验证回到旧 NFS 正常后，再次 patch 回 kuboard-pvc-ha（二次切换也是练习）
```

**P3 产出**：确认切换 SOP 有效 + 回滚路径可用 → 形成 §7 的逐业务手册。

---

## 6. P4 逐业务切换（生产模式复用 P3 SOP）

切换顺序（低价值 → 高价值）：

```
第一批: mytest-*（2个）、kuboard（已演练）
第二批: user-*、kyt-*、kya-*、official-*（前后端业务数据）
第三批: trace-*（链路数据，量大但可重建）
第四批: db-*（数据库！最后切，切换前逐个确认业务低峰）
```

每业务操作 = §5 的步骤 1-5（差量同步 → 校验 → 新 PV/PVC → patch → 验证），单业务窗口 < 10 分钟（实际中断秒级）。

注意事项：

1. **db-* 里的 MySQL**：切前确认无长事务/备份任务在跑（`SHOW PROCESSLIST`），切换窗口=Pod 重启+MySQL 恢复（通常 30-60 秒）
2. **ES 有状态 Pod**：重建后分片自动恢复，切换后观察 `GET _cluster/health` 直到 green/yellow
3. **每次切换间隔 ≥ 30 分钟观察期**，不批量连切
4. CSI 类 PV（10 个）：SOP 相同，只是新 PV 的 spec 用 `csi` 段（driver/nfs，volumeAttributes.server 改为 nfs-ha.lianan.local）
5. 旧 PV/PVC **保留不删**（Retain 策略，天然回滚点），P5 收尾时统一处理

---

## 7. P5 收尾：master01 退役 + 备份体系上线

```bash
# --- 前提：全部 43 个 PV 已切换，观察一周无回滚需求 ---

# --- 1. 停止 master01 的 NFS 服务（单点退役）---
systemctl disable --now nfs-kernel-server
sed -i 's|^/data/nfs|#(retired) /data/nfs|' /etc/exports   # exports 注释保留作纪念

# --- 2. 旧数据转备份（每日硬链接轮转，保留 7 天，误删保护上线）---
install -m 750 /root/k8s-optimizations/optimization-plan/scripts/nfs-ha/nfs-daily-backup.sh /root/scripts/
# master01 crontab（每日 03:00 从 NFS-HA 拉备份）：
# 0 3 * * * /root/scripts/nfs-daily-backup.sh >> /var/log/nfs-backup.log 2>&1
# 原理：rsync --link-dest 硬链接轮转——首日全量，之后每天只占增量空间

# --- 3. 备份演练（第一天就做）---
bash /root/scripts/nfs-daily-backup.sh
ls -lh /data/nfs-backup/$(date +%Y%m%d)/ | head    # 预期：目录结构与 /data/nfs 一致
# 模拟误删恢复：从备份目录拷回任一文件验证可读

# --- 4. 同步停止 P2 的增量 crontab（数据源已切换）---
crontab -l | grep -v nfs-data-sync | crontab -

# --- 5. master01 资源回收（可选，谨慎）---
# /data/nfs 旧数据保留 ≥ 30 天后才考虑：umount /data/nfs && lvremove ubuntu-vg/nfs-lv
# ⚠️ 回收前确认备份体系已运行 ≥ 2 周且做过恢复演练
```

---

## 8. 回滚预案（任何阶段）

| 阶段 | 回滚方式 | 成本 |
|------|---------|------|
| P1/P2 | 无需回滚（未触碰生产数据） | - |
| P3/P4 单业务 | patch deployment 换回旧 PVC 名（旧数据一直在 master01 原地） | 秒级 |
| P4 全部完成后 | 旧 PV/PVC 全保留；批量换回旧 PVC 引用即整体回滚 | 分钟级/业务 |
| P5 之后 | 从备份恢复（rsync 反向拷回） | 小时级 |

**核心保障：master01 的旧数据在 P5 完成并确认备份体系稳定前，一个字节都不删。**

---

## 9. 生产环境（华为云）执行差异清单 ⭐

> 在华为云生产执行本手册时，替换以下差异项，其余步骤**逐字执行**。

| # | 差异项 | 测试环境 | 生产环境（华为云） |
|---|--------|---------|-------------------|
| 1 | 服务器 | VMware VM | **ECS × 2，同可用区（AZ）**（DRBD 同步复制对延迟敏感，跨 AZ 需实测 <2ms） |
| 2 | 规格 | 4C8G | 8C16G（按生产 NFS 负载调整） |
| 3 | 数据盘 | 150G VMDK | **EVS 200G+**（按生产数据量），两台等大 |
| 4 | VIP 实现 | 同子网 ARP 浮动 | **VPC 申请虚拟 IP，绑定到两台 ECS 的主网卡**；keepalived 改 **unicast 模式**（华为云 VPC 不透传 VRRP 组播，必须加 `unicast_srcip <本机IP>` + `unicast_peer { <对端IP> }`） |
| 5 | 防火墙 | 无（扁平网络） | **安全组**：nfs01↔nfs02 放通 TCP 7789；集群节点→NFS VIP 放通 TCP 2049、20048、20049、111（rpcbind/mountd/statd，端口已在 §3.5 固定） |
| 6 | exports 安全 | `*`（隔离测试网） | `192.168.X.0/24(rw,...)` 限定集群节点网段 |
| 7 | DNS 名 | /etc/hosts + CoreDNS hosts | 生产 VPC 内网 DNS 解析（或同样 hosts 方案） |
| 8 | NTP | 阿里/腾讯公共 NTP | **华为云内网 NTP：ntp.myhuaweicloud.com**（复用 ntp-sync-manager.sh） |
| 9 | 备份目标 | master01 本地目录 | **EVS 快照策略（每日）或 OBS**；master01 本地仅保留最近 3 天作为快速恢复层 |
| 10 | apt 源 | 公网/阿里镜像 | 华为云内网镜像源（mirrors.myhuaweicloud.com） |
| 11 | DRBD 装机 | §3.0 源码编译流程 | **同流程**（生产也 Ubuntu 24.04，无 drbd-dkms 包）；华为云内网 gitcode/gh-proxy 可达性需先验证，不通则在本地编译后打包 .ko 分发；ECS 无 Secure Boot 问题 |
| 12 | 回切策略 | preemptive（优先级抢占） | 建议 `nopreempt`（不自动回切，减少切换次数；主备角色变成"谁活着谁服务"） |

**生产执行前置确认**：生产 master01 的 `/etc/exports`、数据量（du -sh）、PV 清单（kubectl get pv -o json | jq ...server）与本手册 §1 现状对齐；差异处修订手册后再开工。

---

## 10. 风险与 FAQ

**Q1: nfs01 上误删文件，nfs02 会跟着删吗？**
会（DRBD 是块级镜像，忠实复制一切操作，包括误删）。防误删靠的是 P5 的每日备份轮转（保留 7 天历史版本），不是 DRBD。**HA 与备份是两套互补机制，缺一不可。**

**Q2: DRBD split-brain（脑裂）怎么处理？**
两台都活着但网络互断时，可能出现双 Primary。恢复流程（保留 nfs01 数据，弃 nfs02）：

```bash
nfs02: systemctl stop keepalived                     # 先停 VIP 争抢
nfs02: drbdadm disconnect nfs && drbdadm secondary nfs
nfs02: drbdadm connect --discard-my-data nfs         # 声明本侧数据作废
nfs01: drbdadm connect nfs                           # 触发从 nfs01 重新同步
# 观察 /proc/drbd 至 ds:UpToDate/UpToDate
nfs02: systemctl start keepalived
```

**Q3: 切换瞬间 Pod 会不会挂？**
静态 NFS PV 的挂载由内核 NFS 客户端维持 TCP 长连接，VIP 漂移后 3-10 秒内自动重连，多数 Pod 无感知；正在写的请求会重试。若出现 stale file handle（历史踩过），删除重建 Pod 即恢复。

**Q4: 为什么 keepalived 而不是 pacemaker？**
Pacemaker 是完整集群资源管理器（更强但复杂一个量级）。两节点 NFS 场景 keepalived+notify 脚本足够，排障心智负担小。若未来节点数多/资源多再升级。

**Q5: resync-rate 120M 会不会影响生产？**
仅初始同步和脑裂恢复时跑全量。平时协议 C 的实时复制走的是写路径（生产写入多大流量，复制流量就多大），测试环境 NFS 写入远低于千兆网卡上限。

---

## 11. 实施记录（部署时逐项填写，供生产复制时对照）

| 日期 | 阶段 | 操作 | 结果 | 备注 |
|------|------|------|------|------|
| 2026-08-25 | P1 VM 创建 | 模板克隆 2 台（4C8G/100G 单盘/Ubuntu 24.04） | ✅ | 模板内核 6.8.0-40 → 升级 6.8.0-124 |
| 2026-08-25 | P1 SecureBoot | vSphere 关闭 SB + 冷启动 | ✅ | 自编译模块未签名，开启时 modprobe 被拒 |
| 2026-08-25 | P1.0 DRBD 9.3.3 | gitcode 源码 + gh-proxy headers + coccinelle 编译 | ✅ | Ubuntu 24.04 无 drbd-dkms，流程见 §3.0 |
| 2026-08-25 | P1.3 DRBD 资源 | sda3 75G create-md + 初始同步 | ✅ | 同步约 15 分钟（resync-rate 120M） |
| 2026-08-25 | P1.5-3.6 NFS+Keepalived | exports/nfs.conf/notify/check 部署 | ✅ | 踩坑 2 个：/proc/drbd 格式变化 + BACKUP 误判 FAULT（§3.0 记录） |
| 2026-08-25 | P1.7 集群 DNS | 8 节点 hosts + CoreDNS hosts 插件 | ✅ | CoreDNS cm 备份于 backups/coredns-cm-backup-20260825-1811.yaml |
| 2026-08-25 | P1.8 failover 演练 | 5 步全通过 | ✅ | VIP 漂移 <8 秒；切换前写入漂移后可读；回切数据双向一致 |
| | P2 全量同步 | 59G 完成 | ⬜ | 待执行 |
| | P3 kuboard 演练 | 切换+回滚 | ⬜ | 待执行 |
| | P4 逐业务 | （每业务一行） | ⬜ | 待执行 |
| | P5 退役+备份 | | ⬜ | 待执行 |

---

## 关联文件

- 脚本目录：`scripts/nfs-ha/`
  - `keepalived-nfs-check.sh`（健康检查，keepalived 每 2s 调用）
  - `keepalived-nfs-notify.sh`（MASTER/BACKUP 切换动作：DRBD提升/挂载/NFS启停）
  - `nfs-data-sync.sh`（全量/增量/校验三模式）
  - `nfs-daily-backup.sh`（P5 后每日备份轮转）
