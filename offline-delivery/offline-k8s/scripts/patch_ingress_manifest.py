#!/usr/bin/env python3
"""
patch_ingress_manifest.py - 重新应用离线定制到 ingress-nginx manifest

上游 ingress-nginx cloud/deploy.yaml 默认:
  - ConfigMap data: null (不允许 configuration-snippet annotations)
  - Service type: LoadBalancer
  - Controller: Deployment + externalTrafficPolicy: Local

离线单机 K8s 部署需要:
  - ConfigMap data: 启用 allow-snippet-annotations + annotations-risk-level
  - Service type: ClusterIP
  - Controller: DaemonSet + hostNetwork: true + dnsPolicy: ClusterFirstWithHostNet
    + tolerations (匹配 master 节点)

用法:
  patch_ingress_manifest.py <manifest.yaml>
"""
import pathlib
import re
import sys


def patch(manifest_path: pathlib.Path) -> int:
    text = manifest_path.read_text()
    original = text
    patched = 0

    # 1) ConfigMap: 启用 snippet annotations
    #    上游格式: data: null 出现在 kind: ConfigMap 之前 (YAML 字段按字母排序)
    new = re.sub(
        r'(apiVersion: v1\n)data: null\n'
        r'(kind: ConfigMap\n'
        r'metadata:\n'
        r'(?:[ \t]+.*\n)*?'
        r'[ \t]+name: ingress-nginx-controller\n'
        r'[ \t]+namespace: ingress-nginx\n)',
        r'\1\2'
        r'data:\n'
        r'  allow-snippet-annotations: "true"\n'
        r'  annotations-risk-level: "Critical"\n',
        text,
        count=1,
    )
    if new != text:
        text = new
        patched += 1
        print("  [1] ConfigMap 启用 snippet annotations")
    elif "allow-snippet-annotations" in text:
        print("  [1] ConfigMap 已包含 snippet annotations，跳过")
    else:
        print("  [1] WARN: 未匹配到 ConfigMap ingress-nginx-controller")

    # 2) Service: 强制 ClusterIP (hostNetwork 直绑宿主机 80/443)
    new = re.sub(
        r'(kind: Service\n'
        r'(?:.|\n)*?'
        r'[ \t]+name: ingress-nginx-controller\n'
        r'(?:.|\n)*?'
        r'[ \t]+type: )LoadBalancer',
        r'\1ClusterIP',
        text,
        count=1,
    )
    if new != text:
        text = new
        patched += 1
        print("  [2] Service 改为 ClusterIP")
    # 移除 externalTrafficPolicy (ClusterIP 下无意义)
    new = re.sub(r'\n[ \t]+externalTrafficPolicy: [^\n]+\n', '\n', text, count=1)
    if new != text:
        text = new
        print("  [2b] 移除 externalTrafficPolicy")

    # 3) Deployment -> DaemonSet (hostNetwork 模式需要每节点一个 Pod)
    new = re.sub(
        r'(apiVersion: apps/v1\n)kind: Deployment\n(.*?)(?=\n---|\Z)',
        r'\1kind: DaemonSet\n\2',
        text,
        count=1,
        flags=re.DOTALL,
    )
    if new != text:
        text = new
        patched += 1
        print("  [3] Deployment -> DaemonSet")

    # 4) 移除 Deployment 专属字段 (replicas / strategy / minReadySeconds / revisionHistoryLimit)
    removed = 0
    for pat in [
        r'\n[ \t]+replicas: \d+\n',
        r'\n[ \t]+minReadySeconds: \d+\n',
        r'\n[ \t]+revisionHistoryLimit: \d+\n',
        # strategy: 块 (rollingUpdate + type)
        r'\n[ \t]+strategy:\n'
        r'[ \t]+rollingUpdate:\n'
        r'[ \t]+maxUnavailable: \d+\n'
        r'[ \t]+type: RollingUpdate\n',
    ]:
        new = re.sub(pat, '\n', text, count=1)
        if new != text:
            text = new
            removed += 1
    if removed:
        print(f"  [4] 移除 {removed} 个 Deployment 专属字段")

    # 5) 插入 hostNetwork: true / dnsPolicy / tolerations 到 controller Pod spec
    #    上游容器缩进: spec(4) > containers(6) > - args(6) / name(8)
    #    目标位置: 在第一个 "      containers:" 之前插入 (controller Pod)
    #    注意: admission Job 也有 containers: 块, 但应避免重复插入
    if "      hostNetwork: true" in text:
        print("  [5] 已包含 hostNetwork，跳过")
    else:
        hostnet_block = (
            "      hostNetwork: true\n"
            "      dnsPolicy: ClusterFirstWithHostNet\n"
            "      tolerations:\n"
            "      - operator: Exists\n"
        )
        new = re.sub(
            r'(\n      containers:\n)',
            '\n' + hostnet_block + r'\1',
            text,
            count=1,
        )
        if new != text:
            text = new
            patched += 1
            print("  [5] 插入 hostNetwork/dnsPolicy/tolerations")
        else:
            print("  [5] WARN: 未找到 '      containers:' (缩进 6 空格)")

    if text != original:
        manifest_path.write_text(text)

    return patched


def main() -> int:
    if len(sys.argv) != 2:
        print(f"用法: {sys.argv[0]} <manifest.yaml>", file=sys.stderr)
        return 1
    manifest = pathlib.Path(sys.argv[1])
    if not manifest.exists():
        print(f"错误: manifest 不存在: {manifest}", file=sys.stderr)
        return 1
    print(f"补丁 ingress-nginx manifest: {manifest}")
    count = patch(manifest)
    print(f"==== 应用 {count} 处定制 ====")
    return 0


if __name__ == "__main__":
    sys.exit(main())
