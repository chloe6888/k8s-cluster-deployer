#!/usr/bin/env bash
# 把 artifacts/ 展开成扁平目录，文件名与部署文档 1.4 节一致，直接上传到内网镜像站的 ${FILE_URL} 目录。
# 用法：scripts/package-offline.sh [输出目录，默认 dist/offline-files]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-dist/offline-files}"
A=artifacts
mkdir -p "$OUT"

cp $A/binaries/amd64/containerd/2.3.0/containerd-2.3.0-linux-amd64.tar.gz "$OUT/"
cp templates/systemd/containerd.service.j2                                "$OUT/containerd.service"
cp $A/binaries/amd64/runc/1.4.2/runc.amd64 $A/binaries/amd64/runc/1.4.2/runc.sha256sum "$OUT/"
cp $A/binaries/amd64/nerdctl/2.3.0/nerdctl-2.3.0-linux-amd64.tar.gz       "$OUT/"
cp $A/sources/mergerfs/2.40.2/mergerfs-2.40.2.tar.gz                      "$OUT/2.40.2.tar.gz"
cp $A/manifests/calico/3.32.0/calico.yaml                                 "$OUT/calico-3.32.0.yaml"
cp $A/manifests/envoy-gateway/1.7.1/envoy-gateway-install.yaml            "$OUT/envoy-gateway-install-v1.7.1.yaml"
cp $A/manifests/metallb/0.15.3/metallb-native.yaml                        "$OUT/metallb-native-v0.15.3.yaml"
cp $A/manifests/kyverno/1.18.0/kyverno-install.yaml                       "$OUT/kyverno_install_v1.18.0.yaml"

if [ -f $A/keys/kubernetes/Release.key ]; then
  cp $A/keys/kubernetes/Release.key "$OUT/"
else
  echo "警告：artifacts/keys/kubernetes/Release.key 不存在，部署文档 5.1 需要它，请先补上" >&2
fi
echo "已生成 $OUT（$(ls "$OUT" | wc -l) 个文件）"
