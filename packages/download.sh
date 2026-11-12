#!/usr/bin/env bash
# 重新下载 packages 下的全部文件并校验。在能访问 GitHub 的机器上运行。
# 用法：cd packages && ./download.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p runtime storage manifests apt-keys

dl() { echo "下载 $2"; curl -fsSL --retry 3 -o "$2" "$1"; }

dl https://github.com/containerd/containerd/releases/download/v2.3.0/containerd-2.3.0-linux-amd64.tar.gz runtime/containerd-2.3.0-linux-amd64.tar.gz
dl https://raw.githubusercontent.com/containerd/containerd/v2.3.0/containerd.service                    runtime/containerd.service
dl https://github.com/opencontainers/runc/releases/download/v1.4.2/runc.amd64                           runtime/runc.amd64
dl https://github.com/opencontainers/runc/releases/download/v1.4.2/runc.sha256sum                       runtime/runc.sha256sum
dl https://github.com/containerd/nerdctl/releases/download/v2.3.0/nerdctl-2.3.0-linux-amd64.tar.gz     runtime/nerdctl-2.3.0-linux-amd64.tar.gz
dl https://github.com/trapexit/mergerfs/archive/refs/tags/2.40.2.tar.gz                                 storage/2.40.2.tar.gz
dl https://raw.githubusercontent.com/projectcalico/calico/v3.32.0/manifests/calico.yaml                 manifests/calico-3.32.0.yaml
dl https://github.com/envoyproxy/gateway/releases/download/v1.7.1/install.yaml                          manifests/envoy-gateway-install-v1.7.1.yaml
dl https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml      manifests/metallb-native-v0.15.3.yaml
dl https://github.com/kyverno/kyverno/releases/download/v1.18.0/install.yaml                            manifests/kyverno_install_v1.18.0.yaml

# k8s apt 源公钥：pkgs.k8s.io 不在 GitHub，网络不通时跳过，手动下载放到 apt-keys/Release.key
if curl -fsSL --retry 2 -m 30 -o apt-keys/Release.key https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key; then
  echo "下载 apt-keys/Release.key"
else
  echo "警告：Release.key 下载失败，请在能访问 pkgs.k8s.io 的机器上手动下载" >&2
  rm -f apt-keys/Release.key
fi

echo "校验上游官方 checksum ..."
(cd runtime && grep ' runc.amd64$' runc.sha256sum | sha256sum -c -)
echo "与仓库 SHA256SUMS 对比 ..."
sha256sum -c SHA256SUMS --ignore-missing
