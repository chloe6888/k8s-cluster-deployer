# artifacts：离线安装资源

按"类型 / 组件 / 版本"组织。`checksums/SHA256SUMS` 记录本目录内全部文件的校验和（路径相对于 `artifacts/`）；runc 另外对照上游官方 `runc.sha256sum` 校验，containerd 和 nerdctl 在入库时已对照上游 checksum 校验通过。

| 路径 | 版本 | 部署文档章节 | 来源 |
| --- | --- | --- | --- |
| `binaries/amd64/containerd/2.3.0/containerd-2.3.0-linux-amd64.tar.gz` | 2.3.0 | 3.1 | containerd release |
| `binaries/amd64/runc/1.4.2/runc.amd64`、`runc.sha256sum` | 1.4.2 | 3.3 | runc release |
| `binaries/amd64/nerdctl/2.3.0/nerdctl-2.3.0-linux-amd64.tar.gz` | 2.3.0 | 3.4 | nerdctl release |
| `sources/mergerfs/2.40.2/mergerfs-2.40.2.tar.gz` | 2.40.2 | 2.11 | mergerfs 源码标签（解压后目录 `mergerfs-2.40.2/`） |
| `manifests/calico/3.32.0/calico.yaml` | 3.32.0 | 7 | calico 仓库 manifests/calico.yaml |
| `manifests/metallb/0.15.3/metallb-native.yaml` | 0.15.3 | 10.2 | metallb 仓库 config/manifests/metallb-native.yaml |
| `manifests/envoy-gateway/1.7.1/envoy-gateway-install.yaml` | 1.7.1 | 10.1 | envoyproxy/gateway release 的 install.yaml |
| `manifests/kyverno/1.18.0/kyverno-install.yaml` | 1.18.0 | 10.3 | kyverno release 的 install.yaml |

`containerd.service`（3.1）放在 `templates/systemd/containerd.service.j2`，内容取自 containerd v2.3.0 标签，没有模板变量。

## 与部署文档 1.4 节文件名的对应

本仓库为了按组件和版本归档，部分文件名与部署文档 1.4 节不同。上传内网镜像站时运行 `scripts/package-offline.sh`，会自动按文档里的文件名展开成扁平目录：

| 仓库内文件名 | 文档里的文件名 |
| --- | --- |
| `mergerfs-2.40.2.tar.gz` | `2.40.2.tar.gz` |
| `calico.yaml` | `calico-3.32.0.yaml` |
| `metallb-native.yaml` | `metallb-native-v0.15.3.yaml` |
| `envoy-gateway-install.yaml` | `envoy-gateway-install-v1.7.1.yaml` |
| `kyverno-install.yaml` | `kyverno_install_v1.18.0.yaml` |
| `templates/systemd/containerd.service.j2` | `containerd.service` |

## 还没有放进来的

- **`keys/kubernetes/Release.key`**（5.1，k8s apt 源签名公钥）：来自 `https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key`，需要在能访问的机器上下载（`scripts/download-artifacts.sh` 会尝试），放入后运行 `scripts/verify-checksums.sh --update` 更新校验清单。
- **`packages/deb/kubernetes/`**：kubelet、kubeadm、kubectl、cri-tools 的 deb 包，目前走内网 apt 镜像站，占位。
- **`images/`**：calico、metallb、envoy-gateway、kyverno 的离线镜像，目前推 Harbor，占位。

## 升级版本时

改 `config/versions.yml` 和 `scripts/download-artifacts.sh` 里的版本与 URL，重新下载，运行 `scripts/verify-checksums.sh --update`，再同步修改本表和部署文档 1.1 / 1.4 节。
