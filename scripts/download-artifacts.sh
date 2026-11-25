#!/usr/bin/env bash
# 下载 artifacts/ 下的全部离线资源并校验。需要能访问 GitHub。
# 用法：scripts/download-artifacts.sh
# 版本号统一维护在 config/versions.yml，本文件改动须与之同步。
set -euo pipefail
cd "$(dirname "$0")/.."
A=artifacts
CALICO=3.32.2
METALLB=0.15.3
EG=1.7.1

dl() { echo "下载 $2"; mkdir -p "$(dirname "$2")"; curl -fsSL --retry 3 -o "$2" "$1"; }

dl https://github.com/containerd/containerd/releases/download/v2.3.0/containerd-2.3.0-linux-amd64.tar.gz $A/binaries/amd64/containerd/2.3.0/containerd-2.3.0-linux-amd64.tar.gz
dl https://github.com/opencontainers/runc/releases/download/v1.4.2/runc.amd64                           $A/binaries/amd64/runc/1.4.2/runc.amd64
dl https://github.com/opencontainers/runc/releases/download/v1.4.2/runc.sha256sum                       $A/binaries/amd64/runc/1.4.2/runc.sha256sum
dl https://github.com/containerd/nerdctl/releases/download/v2.3.0/nerdctl-2.3.0-linux-amd64.tar.gz     $A/binaries/amd64/nerdctl/2.3.0/nerdctl-2.3.0-linux-amd64.tar.gz
dl https://raw.githubusercontent.com/projectcalico/calico/v${CALICO}/manifests/calico.yaml              $A/manifests/calico/${CALICO}/calico.yaml
dl https://raw.githubusercontent.com/metallb/metallb/v${METALLB}/config/manifests/metallb-native.yaml  $A/manifests/metallb/${METALLB}/metallb-native.yaml
dl https://github.com/envoyproxy/gateway/releases/download/v${EG}/install.yaml                          $A/manifests/envoy-gateway/${EG}/envoy-gateway-install.yaml
# containerd.service 在 templates/systemd/containerd.service.j2（内容取自 containerd v2.3.0 标签，无模板变量）

# k8s apt 源公钥：来自 pkgs.k8s.io，网络不通时跳过，手动下载放到 artifacts/keys/kubernetes/Release.key
if curl -fsSL --retry 2 -m 30 -o $A/keys/kubernetes/Release.key https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key; then
  echo "下载 $A/keys/kubernetes/Release.key"
else
  echo "警告：Release.key 下载失败，请在能访问 pkgs.k8s.io 的机器上手动下载" >&2
  rm -f $A/keys/kubernetes/Release.key
fi

scripts/verify-checksums.sh
