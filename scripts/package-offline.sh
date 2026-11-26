#!/usr/bin/env bash
# 把 artifacts/ 展开成扁平目录，文件名与部署文档 1.6 节一致，直接上传到内网镜像站的 ${FILE_URL} 目录。
# 用法：scripts/package-offline.sh [输出目录，默认 dist/offline-files]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-dist/offline-files}"
A=artifacts
CALICO=3.32.2
METALLB=0.15.3
EG=1.7.1
HELM=3.22.1
mkdir -p "$OUT"

cp $A/binaries/amd64/containerd/2.3.0/containerd-2.3.0-linux-amd64.tar.gz "$OUT/"
cp templates/systemd/containerd.service.j2                                "$OUT/containerd.service"
cp $A/binaries/amd64/runc/1.4.2/runc.amd64 $A/binaries/amd64/runc/1.4.2/runc.sha256sum "$OUT/"
cp $A/binaries/amd64/nerdctl/2.3.0/nerdctl-2.3.0-linux-amd64.tar.gz       "$OUT/"
cp $A/tools/helm/${HELM}/helm-v${HELM}-linux-amd64.tar.gz                 "$OUT/"
cp $A/charts/calico/${CALICO}/tigera-operator-v${CALICO}.tgz              "$OUT/"
cp $A/charts/calico/${CALICO}/crd.projectcalico.org.v1-v${CALICO}.tgz     "$OUT/"   # CRD Chart 勿漏
cp $A/charts/metallb/${METALLB}/metallb-${METALLB}.tgz                    "$OUT/"
cp $A/charts/envoy-gateway/${EG}/gateway-helm-v${EG}.tgz                  "$OUT/"
cp $A/manifests/calico/${CALICO}/calico.yaml                              "$OUT/calico-${CALICO}.yaml"
cp $A/manifests/envoy-gateway/${EG}/envoy-gateway-install.yaml            "$OUT/envoy-gateway-install-v${EG}.yaml"
cp $A/manifests/metallb/${METALLB}/metallb-native.yaml                    "$OUT/metallb-native-v${METALLB}.yaml"

if [ -f $A/keys/kubernetes/Release.key ]; then
  cp $A/keys/kubernetes/Release.key "$OUT/"
else
  echo "警告：artifacts/keys/kubernetes/Release.key 不存在，部署文档 5.1 需要它，请先补上" >&2
fi

# 决策 #25：文件站清单条目为展平文件名（artifact role 按 $2==<展平名> 提取），
# SHA256SUMS 本身不进清单；重跑时旧清单会被 find 排除后重新生成
( cd "$OUT" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' \
    | LC_ALL=C sort | xargs -r sha256sum ) > "$OUT/SHA256SUMS"
echo "已生成 $OUT/SHA256SUMS（$(wc -l < "$OUT/SHA256SUMS") 个条目）"
echo "已生成 $OUT（$(ls "$OUT" | wc -l) 个文件）"
