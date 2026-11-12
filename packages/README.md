# packages：K8S v1.36.6 部署所需的二进制与 manifest

对应《K8S v1.36.6 root 部署方案》1.4 节的安装文件清单。**文件名与文档保持一致**，扁平上传到内网镜像站的 `${FILE_URL}` 即可。

## 目录

| 目录 | 文件 | 版本 | 用于章节 | 来源 |
| --- | --- | --- | --- | --- |
| `runtime/` | `containerd-2.3.0-linux-amd64.tar.gz` | 2.3.0 | 3.1 | containerd release |
| `runtime/` | `containerd.service` | v2.3.0 | 3.1 | containerd 仓库 v2.3.0 标签 |
| `runtime/` | `runc.amd64`、`runc.sha256sum` | v1.4.2 | 3.3 | runc release |
| `runtime/` | `nerdctl-2.3.0-linux-amd64.tar.gz` | 2.3.0 | 3.4 | nerdctl release |
| `storage/` | `2.40.2.tar.gz`（解压后目录 `mergerfs-2.40.2/`） | 2.40.2 | 2.11 | mergerfs 源码标签 |
| `manifests/` | `calico-3.32.0.yaml` | v3.32.0 | 7 | calico 仓库 manifests/calico.yaml |
| `manifests/` | `envoy-gateway-install-v1.7.1.yaml` | v1.7.1 | 10.1 | envoyproxy/gateway release 的 install.yaml |
| `manifests/` | `metallb-native-v0.15.3.yaml` | v0.15.3 | 10.2 | metallb 仓库 config/manifests/metallb-native.yaml |
| `manifests/` | `kyverno_install_v1.18.0.yaml` | v1.18.0 | 10.3 | kyverno release 的 install.yaml |

`SHA256SUMS` 是本仓库内所有文件的校验和；containerd、runc、nerdctl 三个二进制另外已对照上游官方 checksum 校验通过。

## 不在本仓库里的

- **`Release.key`**（5.1，k8s apt 源签名公钥）：来自 pkgs.k8s.io，不在 GitHub，需要在能访问的机器上下载后放进 `apt-keys/`（`download.sh` 会尝试下载）：`https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key`
- **kubelet / kubeadm / kubectl / cri-tools**：走内网 apt 镜像站，不放在这里。
- **容器镜像**（calico、Envoy Gateway、MetalLB、kyverno、kubeadm 系统镜像、pause 等）：要推到 Harbor，不是文件，不放在这里。

## 上传到内网镜像站

文档按扁平目录取文件，所以上传时把子目录展开：

```bash
cp runtime/* storage/* manifests/* apt-keys/* /path/to/mirror/k8sv1.36/    # 目标即 ${FILE_URL} 对应目录
```

上传后用文档 1.4 节的检查命令确认每个文件都返回 200。

## 重新下载 / 校验

```bash
./download.sh                  # 重新下载并校验（需访问 GitHub）
sha256sum -c SHA256SUMS        # 只校验现有文件
```

## 升级版本时

改 `download.sh` 里的版本号和 URL，重新运行，再更新 `SHA256SUMS` 和本表，并同步修改部署文档 1.1 / 1.4 节。
