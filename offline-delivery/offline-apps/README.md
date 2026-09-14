# offline-apps - 业务应用离线镜像打包与部署

> 适用版本：v1.0
> 支持架构：ARM64 / AMD64
> 目标：业务应用 K8s YAML + 容器镜像 离线打包 / 部署

本项目提供**两条独立流水线**，覆盖业务应用离线场景：

```
                ┌────────────────────────────────────────┐
                │  流水线 A：image-list 拉取打包          │
                │  适用: 已知业务镜像列表                  │
                │  入口: images.conf 纯列表               │
                │  工具: pack_apps.sh → load_apps.sh      │
                └────────────────────────────────────────┘

                ┌────────────────────────────────────────┐
                │  流水线 B：namespace 导出              │
                │  适用: 在已部署 K8s 集群导出 namespace   │
                │  入口: apps.conf namespace 列表         │
                │  工具: export_apps.sh → deploy_apps.sh │
                └────────────────────────────────────────┘
```

两条流水线**完全独立**，可以单独使用其中任意一条。

---

## 1. 流水线 A：image-list 拉取打包

### 1.1 适用场景

- 已经知道需要哪些业务镜像（一般是开发/运维提供的镜像清单）
- 没有可导出的源 K8s 集群
- 镜像来自外部 registry（如 swr.cn-east-3.myhuaweicloud.com）

### 1.2 文件结构

```
offline-apps/
├── images.conf                    # ★ 镜像清单 (纯列表, 唯一真相源)
├── scripts/
│   ├── pack_apps.sh               # 在线: 拉取 + 导出 + 打包
│   └── load_apps.sh               # 离线: 导入到 K8s containerd
├── images/                        # 本地镜像 tar (拉取后生成)
└── manifests/                     # K8s YAML (可选, 按 namespace 组织)
```

### 1.3 images.conf 格式

```bash
# 注释行以 # 开头
# 一行一个完整镜像引用 (registry/path:tag)
# 空行忽略

# 业务应用 1
swr.cn-east-3.myhuaweicloud.com/beosin-develop/common/common-web:feature-kubernetes-20260701163003-be2527f

# 业务应用 2
swr.cn-east-3.myhuaweicloud.com/beosin-develop/trace/trace-front:beosin-saas-release-20260701164322-8efcdb90
```

### 1.4 在线机器：拉取并打包

```bash
cd offline-apps

# 1. 编辑 images.conf 填入所有业务镜像
vim images.conf

# 2. 一键打包
bash scripts/pack_apps.sh
# 或: CONF_FILE=/path/to/list.conf bash scripts/pack_apps.sh
# 或: FORCE_PULL=1 bash scripts/pack_apps.sh    # 强制重新拉取

# 3. 产出
ls -lh ../bundle/${ARCH}/apps/
# offline-app-images-aarch64-20260713132418.tar.gz
# offline-app-images-aarch64-20260713132418.tar.gz.sha256
```

**包内结构**：
```
offline-app-images-aarch64/
├── images/
│   ├── images.list                        # 镜像清单
│   ├── sha256sum.txt                      # 校验
│   ├── swr.cn-east-3_..._tag-image_20260701.tar
│   ├── swr.cn-east-3_..._common-web_...tar
│   └── ...
├── scripts/
│   └── load_apps.sh                       # 离线导入脚本
├── VERSION.txt
└── sha256sum.txt
```

### 1.5 离线 K8s 节点：导入并部署

```bash
# 1. 上传离线包到 K8s 节点
scp offline-app-images-aarch64-*.tar.gz root@<k8s-node>:/opt/install/

# 2. 解压
cd /opt/install
tar xzf offline-app-images-aarch64-*.tar.gz
cd offline-app-images-aarch64

# 3. 导入镜像到 K8s containerd
bash scripts/load_apps.sh
# 自动检测 containerd, 逐个 ctr import

# 4. 验证镜像可见
ctr -n k8s.io images ls | grep -E "beosin|trace|common"
# 或
crictl images | grep -E "beosin|trace|common"
```

### 1.6 K8s YAML 部署

镜像导入后，**K8s YAML 中的 `image:` 字段保持原样**（swr.cn-east-3.myhuaweicloud.com/...），containerd 命中本地即可。

确保 Pod YAML 中：
```yaml
spec:
  containers:
  - name: myapp
    image: swr.cn-east-3.myhuaweicloud.com/beosin-develop/common/common-web:feature-kubernetes-20260701163003-be2527f
    imagePullPolicy: IfNotPresent   # ★ 必须, 默认就是 IfNotPresent
```

或配合 `image-cri-shim` 自动重写（见 offline-k8s 项目的部署）。

---

## 2. 流水线 B：namespace 导出

### 2.1 适用场景

- 在已有的 K8s 集群上运行着 namespace（如 common / trace）
- 需要把整个 namespace 的资源 + 关联镜像离线化
- 用于客户环境/测试环境复现

### 2.2 文件结构

```
offline-apps/
├── apps.conf                      # ★ namespace 列表 (一行一个)
├── scripts/
│   ├── export_apps.sh             # 在线: 从 K8s 导出 namespace 全量资源 + 镜像
│   └── deploy_apps.sh             # 离线: 加载镜像 + 部署 YAML
├── manifests/                     # 导出的 K8s YAML (export 后生成)
│   ├── cluster/                   # 集群级资源 (PV, StorageClass)
│   ├── common/                    # namespace: common
│   └── trace/                     # namespace: trace
└── images/                        # 导出的镜像 tar
```

### 2.3 apps.conf 格式

```bash
# 注释行以 # 开头
# 一行一个 namespace 名称

common
trace
```

或通过环境变量：
```bash
NAMESPACES=common,trace bash export_apps.sh
```

### 2.4 在线机器：从 K8s 导出

```bash
cd offline-apps

# 1. 编辑 apps.conf 填入要导出的 namespace
vim apps.conf

# 2. 执行导出 (需要 kubectl 能连到源集群)
bash scripts/export_apps.sh
# 或: NAMESPACES=common,trace bash scripts/export_apps.sh

# 3. 产出
ls -lh ../bundle/${ARCH}/apps/
# offline-app-images-aarch64-20260713132418.tar.gz  (含 manifests + images)
```

**导出范围**：
- namespace 下所有 K8s 资源（动态发现，含 CRD）
- 关联的 PV / StorageClass（集群级资源）
- namespace 中 Pod 引用的所有容器镜像

### 2.5 离线 K8s 节点：一键部署

```bash
# 1. 上传离线包
scp offline-app-images-aarch64-*.tar.gz root@<target>:/opt/install/

# 2. 解压
cd /opt/install
tar xzf offline-app-images-aarch64-*.tar.gz
cd offline-app-images-aarch64

# 3. 一键部署 (加载镜像 + apply YAML)
bash scripts/deploy_apps.sh
# 或: SKIP_IMAGES=true bash scripts/deploy_apps.sh   # 跳过镜像加载 (假设已 load)
```

### 2.6 验证

```bash
# Pod 启动情况
kubectl get pods -A

# 镜像可见性
crictl images | grep -E "beosin|trace|common"
```

---

## 3. 对比两种流水线

| 维度 | 流水线 A (image-list) | 流水线 B (namespace 导出) |
|------|---------------------|---------------------------|
| **入口配置** | `images.conf` (纯列表) | `apps.conf` (namespace 列表) |
| **源数据** | 外部 registry | 已部署的 K8s namespace |
| **需要 kubectl** | 否 (只用 docker pull) | 是 |
| **适用** | 已知镜像/无源集群 | 已有集群/复现环境 |
| **镜像打包** | `pack_apps.sh` 拉取 | `export_apps.sh` 从 ctr 导出 |
| **离线加载** | `load_apps.sh` | `load_apps.sh` (复用) |
| **离线部署** | 手动 apply YAML | `deploy_apps.sh` 自动 apply |

## 4. 关键文件

| 文件 | 用途 |
|------|------|
| `images.conf` | 流水线 A: 镜像清单 |
| `apps.conf` | 流水线 B: namespace 列表 |
| `scripts/pack_apps.sh` | 流水线 A 在线: 拉取打包 |
| `scripts/load_apps.sh` | 流水线 A/B 离线: 镜像导入 |
| `scripts/export_apps.sh` | 流水线 B 在线: K8s 导出 |
| `scripts/deploy_apps.sh` | 流水线 B 离线: YAML 部署 |
| `manifests/` | K8s YAML (可手动维护或 export 生成) |
| `images/` | 镜像 tar 暂存目录 |

## 5. 与 K8s 镜像 shim 的关系

offline-k8s 项目会部署 `image-cri-shim` 服务，自动将 Pod YAML 中的外部 registry 引用重写为本地 `sealos.hub:5000/...`。这是**另一种思路**：

| 方式 | 适用 |
|------|------|
| **offline-apps (本项目)** | 镜像直接导入 containerd，地址不变 |
| **offline-k8s (shim)** | 镜像推到 sealos.hub:5000，自动重写 image 引用 |

两者**可以共存**：用 offline-apps 加载业务镜像，用 offline-k8s 的 shim 兜底任意 K8s 清单中的外部 registry 引用。
