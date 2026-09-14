# 组件版本调研与选择记录

## 结论

本次离线包不再采用“每次执行都自动取最新”的策略，改为类似 `requirements.txt` 的固定版本清单：`config/component-versions.env`。

推荐目标版本：

- Kubernetes：`v1.35.6`
- sealos：`v5.1.1`
- Calico：`v3.32.0`
- ingress-nginx：`controller-v1.15.1` / chart `4.15.1`
- Helm：`v3.21.2`
- Kuboard：`v3`

## 为什么不直接用 v1.33.6

`v1.33.6` 是当前 `labring/kubernetes` 预构建 sealos cluster image 中能直接拉到的较新 tag，不等于“当前最适合长期使用的 Kubernetes 版本”。

调研发现：

1. Kubernetes 官方只维护最近三个 minor 分支，约 1 年补丁窗口。
2. Kubernetes 1.33 已进入维护末期，生命周期明显短于 1.35。
3. 如果目标是尽量长期稳定，应该选当前支持窗口中更靠新的稳定分支，而不是被 sealos 预构建镜像仓库的最新 tag 限制。

## 为什么选择 v1.35.x

1. `v1.35` 不是最新首发分支，比 `v1.36` 更稳。
2. `v1.35` 比 `v1.34`、`v1.33` 生命周期更长。
3. 生态组件兼容性更合适：Calico 最新文档测试 Kubernetes `1.34/1.35/1.36`；ingress-nginx 新版本也覆盖 Kubernetes 1.35。
4. 对内网离线环境来说，版本稳定性和生命周期比“立即追最新”更重要。

## 关于“两年以上不升级”

自建 upstream Kubernetes 不适合承诺两年以上不升级仍持续获得社区安全补丁。社区维护窗口通常约 1 年，并且只覆盖最近几个 minor。

可执行策略：

1. 本次固定 `v1.35.x`，交付后默认不自动升级。
2. 每 6-12 个月做一次安全和生命周期评估。
3. 只在以下情况升级：
   - 关键 CVE；
   - 当前版本接近 EOL；
   - 业务组件需要新 API；
   - openEuler/内核/容器运行时兼容性要求。
4. 如果必须“两年以上不动且仍要安全补丁”，需要考虑商业发行版或带扩展维护的 Kubernetes 发行版。

## 后续执行调整

1. `component-versions.env` 是版本事实来源。
2. 下载脚本优先读取固定版本，不再默认更新到最新。
3. 如果 sealos 预构建 cluster image 没有 `v1.35.6`，则需要构建自定义离线 cluster image 或改用 kubeadm/containerd 离线封装方式；不能自动降到 `v1.33.6` 作为最终交付版本，除非明确记录为临时验证包。
