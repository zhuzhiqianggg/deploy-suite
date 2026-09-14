# ARM64/openEuler 离线 Kubernetes 一键部署包制作计划

## Summary

目标是在当前有外网的 ARM64 服务器上，制作并验证一套可拷贝到完全内网目标服务器的一键 Kubernetes 部署包。目标服务器系统为 openEuler 24.03 LTS-SP3 aarch64，当前制作服务器为 openEuler 22.03 LTS aarch64，架构一致但系统版本不同。

建议采用 **sealos**（用户消息中的 seolos 应理解为 sealos）作为 Kubernetes 离线部署入口：在当前服务器下载 sealos 二进制、Kubernetes 集群镜像、容器运行时、网络插件、ingress-nginx、Kuboard 及必要依赖；在当前服务器先完成单节点部署验证；验证通过后导出 sealos cluster image、普通容器镜像、安装脚本、配置文件、校验文件并整体打包。目标内网服务器只需解压后执行一个入口脚本，即可部署单节点 Kubernetes；脚本和配置保留扩展为多节点的参数能力。

## Current State Analysis

1. 当前工作目录为空：[/opt/install](file:///opt/install) 下未发现已有脚本、配置、镜像包或 Kubernetes 相关文件。
2. 当前制作服务器系统信息来自 [/etc/os-release](file:///etc/os-release#L1-L5)：openEuler 22.03 LTS。
3. 当前制作服务器 CPU 为 ARM64/aarch64，来自 [/proc/cpuinfo](file:///proc/cpuinfo#L1-L18)。
4. 用户提供的目标服务器为 openEuler 24.03 LTS-SP3 aarch64，Linux 6.6 内核。
5. 因当前目录没有现成工程，本次需要从零创建离线交付目录、下载脚本、打包脚本、安装脚本和配置文件。
6. 目标部署为单节点 Kubernetes，但应选择 sealos 方式以便后续同一套离线包支持 `--masters`、`--nodes` 扩展为多节点。

## Assumptions & Decisions

1. **部署工具**：使用 sealos，不使用 kubeadm 手写全流程。原因是 sealos 更适合把 Kubernetes、运行时、插件和应用做成可离线加载的 cluster image，并支持一条命令安装。
2. **架构**：所有二进制、镜像和包均锁定 `linux/arm64` / `aarch64`。
3. **系统兼容**：当前 openEuler 22.03 与目标 openEuler 24.03 都是 aarch64，sealos、containerd、Kubernetes 镜像层面通常可跨这两个系统版本使用；但 OS rpm 依赖需要尽量减少，必要时按 openEuler 24.03 额外缓存 rpm 包。
4. **部署形态**：默认做单节点 all-in-one。安装脚本设计为配置驱动，后续可以通过修改主机清单扩展到多节点。
5. **网络插件**：优先使用 Calico。原因是 sealos 生态中常见、离线镜像容易整理、单节点和多节点均可用。
6. **Ingress**：使用 ingress-nginx，并提前拉取 ARM64 镜像与 Helm chart/manifest。
7. **面板**：部署 Kuboard，并提前准备 Kuboard 所需镜像。Kuboard 依赖的具体镜像以其官方安装 YAML/版本为准，下载阶段解析并补齐。
8. **离线包形式**：最终产物为一个 tar.gz，例如 `k8s-offline-openEuler-aarch64.tar.gz`，包含 sealos 二进制、cluster image tar、应用镜像 tar、部署脚本、配置模板、校验文件和安装说明。
9. **验证优先级**：先在当前服务器完整安装验证，再执行导出打包；不直接把未经验证的资源交付给内网。
10. **版本选择策略**：执行阶段必须在线查询 sealos、Kubernetes、Calico、ingress-nginx、Kuboard 的 **最新稳定版**，写入版本锁定文件，后续下载、验证和打包均使用同一版本集合。禁止使用 alpha、beta、rc、nightly、dev、snapshot 等预发布版本；也不主动下载多个历史老版本。只有当最新版稳定版不支持 ARM64 或与 openEuler 验证失败时，才回退到最近一个稳定小版本，并记录回退原因。

## Proposed Changes

### 1. 创建离线制作目录结构

计划创建以下目录和文件：

* `/opt/install/offline-k8s/`

  * `config/`

    * `versions.env`

    * `cluster.env`

    * `hosts.example`

  * `scripts/`

    * `00_check_env.sh`

    * `01_download_online.sh`

    * `02_build_cluster_images.sh`

    * `03_test_install_local.sh`

    * `04_export_offline_bundle.sh`

    * `install_offline.sh`

    * `cleanup_test_cluster.sh`

  * `manifests/`

    * `ingress-nginx/`

    * `kuboard/`

  * `apps/`

    * `README.placeholder`

  * `images/`

  * `pkgs/`

  * `bin/`

  * `bundle/`

  * `logs/`

原因：把在线制作、离线安装、配置、镜像、二进制和最终交付物分离，便于排查和重新打包。

### 2. 编写版本与集群配置

文件：`/opt/install/offline-k8s/config/versions.env`

内容包括：

* `ARCH=arm64`

* `RPM_ARCH=aarch64`

* `VERSION_POLICY=latest-stable-only`

* `ALLOW_PRERELEASE=false`

* `SEALOS_VERSION=...`（执行时查询最新稳定版后锁定）

* `KUBERNETES_VERSION=...`（执行时查询最新稳定版后锁定）

* `CONTAINERD_VERSION=...`（如 sealos cluster image 已包含则仅记录）

* `CNI_TYPE=calico`

* `CALICO_VERSION=...`（执行时查询最新稳定版后锁定）

* `INGRESS_NGINX_VERSION=...`（执行时查询最新稳定版后锁定）

* `KUBOARD_VERSION=...`（执行时查询最新稳定版后锁定）

* `PAUSE_IMAGE=...`

* `IMAGE_REGISTRY=...`

文件：`/opt/install/offline-k8s/config/cluster.env`

内容包括：

* 单节点默认配置：本机 IP、主机名、SSH 用户、SSH 端口。

* Kubernetes service CIDR、pod CIDR。

* sealos 安装参数。

* 是否安装 ingress-nginx。

* 是否安装 Kuboard。

原因：版本与部署参数必须固定，否则无法保证离线目标环境与测试环境一致。

### 3. 在线下载脚本

文件：`/opt/install/offline-k8s/scripts/01_download_online.sh`

执行内容：

1. 从 GitHub Release、官方镜像仓库或官方 chart 仓库查询各组件最新稳定版，过滤 alpha/beta/rc/nightly/dev/snapshot，生成 `versions.lock`。
2. 校验最新稳定版是否支持 `linux/arm64`；不支持时只回退到最近一个支持 ARM64 的稳定版，并在 `versions.lock` 记录原因。
3. 下载 ARM64 sealos 二进制并放入 `bin/`。
4. 下载/拉取 ARM64 Kubernetes cluster image。
5. 下载/拉取 Calico cluster image 或所需镜像。
6. 下载 ingress-nginx Helm chart 或 manifest，并解析其中镜像列表。
7. 下载 Kuboard 安装 YAML，并解析其中镜像列表。
8. 拉取所有普通容器镜像，强制指定 `linux/arm64`。
9. 保存镜像到 `images/*.tar`。
10. 下载目标系统可能缺失的基础工具 rpm（如 socat、conntrack、ipvsadm、ipset、nfs-utils 等，按实际 sealos 检查结果决定），放入 `pkgs/`。
11. 生成 `bundle/manifest.txt` 和 `bundle/sha256sum.txt`。

原因：目标服务器完全无外网，所有二进制、镜像、manifest、chart 和 rpm 必须在当前服务器准备完整。

### 4. 构建 sealos 离线 cluster image

文件：`/opt/install/offline-k8s/scripts/02_build_cluster_images.sh`

执行内容：

1. 使用 sealos 拉取官方 ARM64 Kubernetes cluster image。
2. 如官方镜像不能完整覆盖需求，则用 Kubefile 构建自定义 cluster image，把 Kubernetes、containerd、Calico 组合为一个内部镜像。
3. 对 ingress-nginx 和 Kuboard 两类应用，优先作为普通 manifest/Helm 资源加离线镜像包交付；如 sealos 支持更合适的方式，也可打成独立 cluster image。
4. 使用 `sealos save` 导出 cluster image tar 到 `bundle/sealos-images/`。
5. 使用 `sealos load` 在测试前验证 tar 可重新导入。

原因：sealos 的核心优势是 cluster image 离线分发，目标服务器只需加载 tar 后运行。

### 5. 本机安装验证

文件：`/opt/install/offline-k8s/scripts/03_test_install_local.sh`

执行内容：

1. 执行环境检查：系统架构、root 权限、磁盘空间、内核模块、端口占用、时间同步、swap、SELinux/firewalld 状态。
2. 使用 sealos 在当前服务器安装单节点 Kubernetes。
3. 等待 kubelet、containerd、apiserver、scheduler、controller-manager 就绪。
4. 检查节点状态：`kubectl get nodes -o wide`。
5. 检查系统 Pod：`kubectl get pods -A`。
6. 部署测试 Pod 和 Service，验证集群 DNS 与 Pod 网络。
7. 安装 ingress-nginx，并验证 controller Pod Ready。
8. 安装 Kuboard，并验证 Service/Pod 正常。
9. 将完整安装日志写入 `logs/test-install-*.log`。

原因：只有当前服务器验证成功后，离线包才有交付价值。

### 6. 导出最终离线包

文件：`/opt/install/offline-k8s/scripts/04_export_offline_bundle.sh`

执行内容：

1. 清理临时缓存和测试残留，不删除已验证的离线资源。
2. 汇总以下内容到 `bundle/k8s-offline-openEuler-aarch64/`：

   * `bin/sealos`

   * sealos cluster image tar

   * ingress-nginx/Kuboard 镜像 tar

   * manifests/Helm charts

   * rpm 依赖包

   * `install_offline.sh`

   * `config/versions.env`

   * `config/cluster.env`

   * `config/hosts.example`

   * `sha256sum.txt`
3. 生成最终压缩包：`bundle/k8s-offline-openEuler-aarch64.tar.gz`。
4. 生成最终校验文件：`bundle/k8s-offline-openEuler-aarch64.tar.gz.sha256`。

原因：目标服务器只需要一个压缩包和一个校验文件。

### 7. 离线一键安装脚本

文件：`/opt/install/offline-k8s/scripts/install_offline.sh`

目标服务器执行方式：

```bash
bash install_offline.sh
```

脚本逻辑：

1. 校验当前系统为 aarch64。
2. 校验 root 权限、磁盘空间、内核模块、端口、swap、防火墙等。
3. 安装本地 rpm 依赖包。
4. 安装 `bin/sealos` 到 `/usr/local/bin/sealos`。
5. 使用 `sealos load` 导入 Kubernetes/Calico cluster image。
6. 使用 `sealos run` 部署单节点 Kubernetes。
7. 导入 ingress-nginx 和 Kuboard 所需容器镜像。
8. 应用 ingress-nginx manifest/Helm chart。
9. 应用 Kuboard manifest。
10. 等待所有核心组件 Ready。
11. 输出 kubeconfig 路径、节点状态、ingress-nginx 状态、Kuboard 访问方式。

原因：内网目标服务器不能依赖人工逐条执行命令，必须一键完成。

### 8. 保留多节点兼容能力

虽然本次目标是单节点，配置仍预留：

* `config/hosts.example` 描述 master/worker 格式。

* `install_offline.sh` 根据配置拼接 sealos `--masters` 与 `--nodes` 参数。

* 单节点时只填写一个 master IP。

原因：sealos 本身支持单节点和多节点，同一离线资源包可以复用于后续扩容场景。

### 9. 预留业务系统离线打包能力

文件：`/opt/install/offline-k8s/scripts/05_package_business_apps.sh`

后续业务系统上线时，按以下原则处理：

1. 业务系统不直接混入基础 Kubernetes 离线包，避免基础集群包频繁变化。
2. 每套业务系统单独生成一个业务离线包，例如 `business-app-xxx-aarch64.tar.gz`。
3. 如果业务系统已有 Helm chart 或 Kubernetes YAML，则打包内容包括：
   - 业务镜像 tar；
   - Helm chart 或 YAML；
   - values 配置；
   - namespace、Secret、ConfigMap 模板；
   - 一键安装脚本。
4. 如果业务系统适合 sealos 应用镜像化，则使用 sealos build/Kubefile 把业务 YAML、chart、镜像依赖打成可离线 `sealos load` 的应用包。
5. 目标服务器部署顺序固定为：
   - 先执行基础包 `install_offline.sh`，部署 Kubernetes、Calico、ingress-nginx、Kuboard；
   - 再执行业务包安装脚本，导入业务镜像并部署业务资源。
6. 每个业务包都生成独立 `versions.lock`、`images.list`、`sha256sum.txt`，便于后续升级和回滚。

原因：这样既能利用 sealos 的一键打包/加载能力，又不会把业务系统和基础集群强耦合；后续业务升级只需要重新打业务包，不需要重做整套 Kubernetes 离线包。

## Verification Steps

执行阶段完成后，需要按以下顺序验证：

1. **下载完整性与版本策略验证**
   - 检查所有下载文件存在。
   - 校验 sha256。
   - 确认 `versions.lock` 中所有组件均为最新稳定版。
   - 确认没有 alpha、beta、rc、nightly、dev、snapshot 等预发布版本。
   - 确认所有镜像均为 ARM64 或 multi-arch 且包含 ARM64。

2. **sealos 离线镜像验证**

   * `sealos load` 能从本地 tar 导入。

   * 断网或屏蔽外网后，`sealos run` 不再访问公网。

3. **当前服务器安装验证**

   * Kubernetes 节点 Ready。

   * CoreDNS Ready。

   * Calico Ready。

   * 测试 Pod 可启动。

   * Service DNS 可解析。

   * ingress-nginx controller Ready。

   * Kuboard Pod/Service Ready。

4. **业务包扩展验证**

   * 基础 Kubernetes 离线包安装后，不需要重新安装集群即可导入业务包。

   * 业务包能独立校验 sha256、导入镜像、应用 Helm/YAML。

   * 业务包升级失败时不影响基础 Kubernetes 集群。

5. **打包验证**

   * 最终 tar.gz 可解压。

   * `sha256sum -c` 通过。

   * 离线包内不缺少 `install_offline.sh`、sealos、cluster image tar、镜像 tar、manifest、配置文件。

6. **目标服务器验证建议**

   * 在目标 openEuler 24.03 LTS-SP3 aarch64 上解压。

   * 执行 `bash install_offline.sh`。

   * 验证 `kubectl get nodes -o wide`。

   * 验证 `kubectl get pods -A`。

   * 验证 ingress-nginx 与 Kuboard 可访问。

## Execution Order After Approval

1. 创建 `/opt/install/offline-k8s` 目录结构。
2. 编写配置文件与脚本骨架。
3. 在线查询各组件最新稳定版，过滤预发布版本，确认 ARM64 支持后生成 `versions.lock`。
4. 下载 sealos、Kubernetes cluster image、Calico、ingress-nginx、Kuboard 和依赖包。
5. 构建/导出 sealos 离线 cluster image。
6. 在当前服务器执行单节点安装测试。
7. 如测试失败，基于日志补齐缺失镜像或依赖后重新验证。
8. 测试通过后导出最终离线包和 sha256 文件。
9. 保留业务系统离线打包脚本入口和目录规范，后续业务镜像/Helm/YAML 可单独打包为应用离线包。
10. 输出目标服务器一键安装命令与离线包路径。

## Risks & Mitigations

1. **openEuler 22.03 制作、24.03 部署存在 rpm 差异**

   * 缓解：尽量依赖 sealos 内置运行时和容器镜像；rpm 仅准备通用基础依赖；目标服务器安装前做依赖检查。

2. **Kuboard 镜像较多或版本镜像源变化**

   * 缓解：执行阶段解析实际安装 YAML，逐个拉取并保存镜像，避免手工遗漏。

3. **部分镜像没有 ARM64 架构**
   - 缓解：下载阶段强制检查 manifest；若最新稳定版不支持 ARM64，只回退到最近一个支持 ARM64 的稳定版并记录原因，不下载一堆老版本试错。

4. **当前服务器测试会改动系统环境**

   * 缓解：测试前记录环境，提供 `cleanup_test_cluster.sh`，但清理脚本只在明确执行时运行。

5. **目标服务器完全离线导致安装失败难以补包**

   * 缓解：最终包内保留镜像清单、版本清单、sha256、安装日志路径和环境检查脚本，先在当前服务器模拟离线验证。

