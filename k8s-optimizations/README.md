# Kubernetes 配置归档

本目录集中管理本集群所有 Kubernetes 运维配置、调优参数、诊断脚本与排障文档。
原散落在 /root 下的文件已全部迁入此处，/root 不再放置 k8s 配置。

## 目录结构

```
k8s-optimizations/
├── README.md                         # 本索引
├── ingress-nginx/                    # ingress-nginx 控制器配置
│   ├── ingress-nginx-direct.conf     # 集群B 直连链路(无 Cloudflare) ConfigMap
│   ├── ingress-nginx-cf.conf          # 集群A Cloudflare 链路 ConfigMap
│   ├── custom-headers.yaml            # 安全响应头 ConfigMap(HSTS/X-Frame 等)
│   └── ingress-nginx-controller-backup-*.yaml  # 变更前 ConfigMap 备份
├── node-tuning/                      # 节点级调优
│   ├── kubelet-config-optimized.yaml  # KubeletConfiguration(eviction/预留/优雅关机)
│   └── sysctl-k8s-optimized.conf       # 内核参数(ARP/conntrack/TCP/swap)
├── priority-class/                   # Pod 驱逐优先级分层
│   ├── priorityclass-config.yaml       # 5 档 PriorityClass 定义
│   ├── kyverno-priority-policy.yaml    # Kyverno 按 namespace 自动注入策略
│   └── inject-priorityclass.sh         # 一次性注入脚本(无 Kyverno 时用)
├── diagnostics/                      # 集群诊断
│   ├── k8s-diagnose.sh                 # 全集群诊断脚本(回显每条命令+结论)
│   └── k8s-cluster-troubleshooting-handbook.md  # 排障手册
└── docs/                             # 事故复盘文档
    └── k8s-sealos-reset-emergency-troubleshooting.md  # sealos reset 事故+ES恢复
```

---

## ingress-nginx 配置(重点)

### 链路对应关系
| 配置文件 | 适用链路 | 流量路径 | proxy-real-ip-cidr | 日志字段 |
|---|---|---|---|---|
| ingress-nginx-direct.conf | 集群B 直连 | 用户→华为云ELB→ingress:80 | 内网4段 | 23字段 |
| ingress-nginx-cf.conf | 集群A CF链路 | 用户→Cloudflare→华为云ELB→ingress:80 | 内网4段+CF官方15段 | 26字段(含cf_*) |

### 本次优化项(相对原集群 ConfigMap)
- A. 修复: 移除冗余 `log-format` 键(非 ingress-nginx 识别项, 仅 log-format-upstream 生效)
- B. 修复: 新增 `log-format-escape-json: "true"`(原缺失 → JSON 日志遇特殊字符会破坏解析)
- C. 安全: 新增 `server-tokens: "false"`(隐藏 nginx 自身错误页版本号; hide-headers 只隐藏上游响应头)
- D. 性能: 新增 `brotli-types`(原未设 → brotli 仅压缩 text/html、text/plain; API 集群 JSON/JS/CSS 漏压缩, 已对齐 gzip-types)
- E. 性能: 新增 `gzip-min-length: "1024"`(<1KB 响应压缩收益低)
- F. 安全: 新增 `ssl-session-tickets: "false"`(会话票据前向保密弱点, 保留 session-cache 已够)
- G. 可靠性: 显式 `proxy-next-upstream` + `tries=3` + `timeout=10`(限定重试, 防故障重试风暴)
- **H. 修复关键 bug: 移除 log-format 中 `$upstream_retry_count`(nginx 无此变量, 原配置会导致 controller 每次 reload 失败回滚!)**

### 测试集群验证记录(2026-08-20)
当前测试集群(直连链路)已完成验证, 结论可直接用于生产:

**direct 配置(已在测试集群应用并运行):**
- ✅ reload 成功: controller 日志 `Backend successfully reloaded` + Normal RELOAD 事件
- ✅ `nginx -t` 语法通过, nginx.conf mtime 已更新
- ✅ JSON 访问日志合法, 23 字段, `upstream_retry_count` 已移除
- ✅ `log-format-escape-json` 生效: 带 `"` 特殊字符的 URI 被正确转义为 `\"`, JSON 仍可解析
- ✅ `server-tokens off` 生效: 响应头无 `Server:` 字段(版本号已隐藏)
- ✅ 运行配置确认: brotli_types/gzip_min_length/server_tokens off/ssl_session_tickets off/proxy_next_upstream+tries+timeout 全部生效

**cf 配置(临时应用验证后已回滚到 direct):**
- ✅ reload 成功, nginx -t 通过, 26 字段日志含 cf_ray/cf_connecting_ip/cf_ipcountry(无CF流量时为空)
- 说明: nginx 语法和 reload 已验证; realip 取用户真实 IP 的行为需在真实 CF 链路上用 `kubectl logs` 验证 remote_addr 是否公网 IP

### 部署与回滚命令
```bash
# 集群B(直连) 部署:
kubectl apply -f k8s-optimizations/ingress-nginx/ingress-nginx-direct.conf
kubectl apply -f k8s-optimizations/ingress-nginx/custom-headers.yaml   # 安全头(如未部署)

# 集群A(Cloudflare) 部署:
kubectl apply -f k8s-optimizations/ingress-nginx/ingress-nginx-cf.conf
kubectl apply -f k8s-optimizations/ingress-nginx/custom-headers.yaml

# 验证 reload 是否成功(看近几行日志):
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=20 | grep -iE "reloaded|Error reloading"

# nginx 配置语法校验:
POD=$(kubectl get pods -n ingress-nginx -o name | head -1 | sed 's#pod/##')
kubectl exec -n ingress-nginx $POD -- nginx -t

# 回滚(apply 变更前的备份):
kubectl apply -f k8s-optimizations/ingress-nginx/ingress-nginx-controller-backup-*.yaml
```

### 生产部署建议
1. 两份 ConfigMap 分别在对应链路集群应用, 不要交叉(直连集群勿用 cf 配置, 会引入不必要的 CF 信任段)
2. apply 后 controller 热加载, Pod 不重启, 业务无感知; 若配置语法错误会自动回滚保持旧配置运行
3. CF 链路上线后, 首件事用 `kubectl logs` 确认 `remote_addr` 为公网用户 IP(非 CF 节点 IP), 证明 realip 生效
4. 如 ELB 有 IPv6 监听, cf 配置的 proxy-real-ip-cidr 需追加 https://www.cloudflare.com/ips-v6 的 7 段
5. ⚠ 孤儿键提醒: 若生产 ConfigMap 曾被 `kubectl edit` 直接改过(如原集群残留的无效 `log-format` 键,
   该键不在 last-applied 注解中), `kubectl apply` 不会删除它(3-way merge 只删 last-applied 中存在的键)。
   apply 后可用此命令清理无效键:
   kubectl patch cm -n ingress-nginx ingress-nginx-controller --type=json \
     -p='[{"op":"remove","path":"/data/log-format"}]'
   或先 diff 确认: kubectl get cm -n ingress-nginx ingress-nginx-controller -o jsonpath='{.data}' | python3 -m json.tool

---

## node-tuning(节点调优)

部署到所有节点(8C 30-32G 规格):
```bash
# 1. kubelet 配置(已在本集群 8 节点验证通过, 2026-08-17)
sudo cp node-tuning/kubelet-config-optimized.yaml /var/lib/kubelet/config.yaml
sudo systemctl restart kubelet   # 逐节点重启并验证 kubectl get nodes

# 2. 内核参数
sudo cp node-tuning/sysctl-k8s-optimized.conf /etc/sysctl.d/k8s-optimized.conf
sudo sysctl --system
```
关键项: evictionHard.memory.available=1Gi(防内核OOM)、mergeDefaultEvictionSettings=true、
systemReserved/kubeReserved 各 512Mi、shutdownGracePeriod 30s、neigh.gc_thresh 1024/2048/4096、
vm.swappiness=0、tcp_keepalive_time=600s。详见各文件内注释。

## priority-class(Pod 驱逐优先级)

按 namespace 后缀分 5 档: temp(100) < test(1000) < pre(5000) < default(10000) < prod(100000)。
```bash
# 方式1: Kyverno 自动注入(推荐, 长期运维)
kubectl apply -f priority-class/priorityclass-config.yaml
kubectl apply -f priority-class/kyverno-priority-policy.yaml

# 方式2: 一次性脚本注入(无 Kyverno 时)
kubectl apply -f priority-class/priorityclass-config.yaml
bash priority-class/inject-priorityclass.sh
```

## diagnostics(诊断) & docs(文档)
- `diagnostics/k8s-diagnose.sh`: 回显每条 kubectl 命令的集群诊断脚本, 兼作学习指南
- `diagnostics/k8s-cluster-troubleshooting-handbook.md`: 排障手册
- `docs/k8s-sealos-reset-emergency-troubleshooting.md`: sealos reset 事故 + ES 密码/索引恢复复盘

## 注意
- `/root/config`(kubeconfig) 与 `/root/.kube` 未迁入, kubectl 依赖, 保持原位
- `/root/docs/api/` 为 sealos 自动生成的命令文档, 非本集群运维配置, 未迁入

## node-tuning/chrony.conf + setup-chrony.sh — 集群 NTP 时间同步(2026-08-20)

**架构决策: 全节点直连国内 NTP 源(阿里云+腾讯), 不用 master01 做二级 NTP 服务器**
- 无单点(master01 宕机不影响其余节点) / 所有节点本就有外网 / NTP 查询量极小
- 同一上游源, 节点间互差 <10ms, 满足 k8s/etcd
- 备选层级架构(worker 无外网时用)见 chrony.conf 末尾注释

**部署(每台节点执行一次):**
```bash
scp node-tuning/chrony.conf node-tuning/setup-chrony.sh root@<节点IP>:/tmp/ntp-setup/
ssh root@<节点IP> 'bash /tmp/ntp-setup/setup-chrony.sh'
```

**验证:** `chronyc sources` 出现 `^*`; `chronyc tracking` 偏差 <100ms

**两次踩坑记录(生产部署前必读):**
1. **apt 源指向 focal(20.04) 但系统是 22.04**: 装 chrony 得到 3.5 老版本,
   其 seccomp 过滤器在 5.15 内核上 SIGSYS 崩溃(服务 core-dump)。
   修复: `sed -i 's/focal/jammy/g' /etc/apt/sources.list` 后装 chrony 4.2。
   (master02/03, worker03/04/05 均有此问题, 原始源已备份为 *.bak.focal-*)
2. **VMware Tools 时间同步与 chrony 拉锯(最重要!)**: vmtools timesync=Enabled 时,
   vmtoolsd 把虚机时钟拉向 ESXi 宿主机时间(实测宿主机偏差约 660 秒!), chrony 校正后
   又被拉回, 时钟反复大幅跳动。修复: `vmware-toolbox-cmd timesync disable`(全部节点)。
   ⚠ 另需在 ESXi 侧为宿主机配置 NTP(当前宿主机时钟偏差约 11 分钟, 影响其自身日志/监控)

**最终状态:** 8 节点偏差 0.2~1.7ms, 节点间互差 <2ms, 集群健康(节点 Ready / etcd Running / 业务 200)

**联动收益:** ingress-nginx JSON 访问日志的 time_iso8601 现在 8 节点一致, Graylog 时序统计不再错位\n
## node-tuning/ntp-sync-manager.sh — NTP 生产管理脚本(2026-08-20)

**一键检查/修复全集群时间同步**(在 master01 运行, SSH 免密到所有节点):
```bash
scp ntp-sync-manager.sh master01:/root/   # 或 git 同步
bash ntp-sync-manager.sh check            # 只读检查, 输出逐节点报告
bash ntp-sync-manager.sh fix              # 检查+一键修复
```

**特性:**
- NTP 源华为云优先(ntp.myhuaweicloud.com), 阿里云/腾讯自动回退(逐源 UDP 探测)
- 自动发现节点(kubectl), 串行逐台修复, 每台验证通过再下一台
- 识别 6 类故障: 未装 chrony / 版本<4 / 服务停 / 未同步 / 偏差大 / vmtools冲突 /
  apt源代号错配 / 配置漂移(server 列表须为候选集子集, 与探测抖动解耦)
- 修复动作全带备份(*.ntpbak.*), 幂等可重复执行
- 阶段3独立 NTP 实测(内嵌 python 客户端), 不信任 chrony 自报; 未达标自动
  makestep 重试 3 轮(兜住 vmtools 残留周期同步动作)

**本地集群已完成的测试:**
1. check: 8/8 全绿
2. 注入 5 类故障(卸载chrony/乱配置/vmtools enable/focal源/停服务) → check 全部精准识别 → fix 全部自动修复(每台 10s 收敛), 独立实测 8/8 达标
3. 幂等: 第二次 fix 全部跳过, 无重复操作
4. 抖动回归: 探测轮源数量波动(3 vs 4)不再误判配置漂移

**生产部署(华为云):**
1. 脚本拷到生产 master01(需 kubectl + 免密 SSH 全节点 + python3)
2. bash ntp-sync-manager.sh check  → 看报告
3. bash ntp-sync-manager.sh fix    → 修复(注意: 装机会动 apt 源, 源文件有备份)
4. 生产在华为云 VPC 内 → 华为云 NTP 必可达, 配置将使用华为云为主源
