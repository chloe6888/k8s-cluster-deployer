#!/usr/bin/env bash
# 校验 artifacts/ 下的文件。
#   scripts/verify-checksums.sh            校验：runc 对照上游 checksum，其余对照 checksums/SHA256SUMS
#   scripts/verify-checksums.sh --update   重新生成 checksums/SHA256SUMS（增删文件后使用）
set -euo pipefail
cd "$(dirname "$0")/../artifacts"

if [ "${1:-}" = "--update" ]; then
  find binaries sources keys manifests -type f ! -name .gitkeep | LC_ALL=C sort | xargs sha256sum > checksums/SHA256SUMS
  echo "已更新 artifacts/checksums/SHA256SUMS"
  exit 0
fi

(cd binaries/amd64/runc/1.4.2 && grep ' runc.amd64$' runc.sha256sum | sha256sum -c -)
sha256sum -c checksums/SHA256SUMS
