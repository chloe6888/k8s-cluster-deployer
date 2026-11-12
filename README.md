# k8s-cluster-deployer

Kubernetes v1.36.6 离线部署项目（Ubuntu 24.04、containerd 2.3.0、内网 Harbor、双网卡、多集群复用）。目录规划如下，当前已落地的部分标注在右侧，其余目录随后续开发补充。

| 目录 | 用途 | 当前状态 |
| --- | --- | --- |
| `artifacts/` | 所有离线安装资源：二进制、源码、签名密钥、官方 manifest、系统软件包、离线镜像、校验清单 | 二进制、源码、manifest、校验清单已就绪；`keys/`、`packages/`、`images/` 为占位 |
| `config/` | 统一版本及参数配置 | 仅 `versions.yml` |
| `templates/` | Jinja2 配置模板 | 仅 `systemd/containerd.service.j2` |
| `scripts/` | 辅助工具 | `download-artifacts.sh`、`verify-checksums.sh`、`package-offline.sh` |
| `inventories/`、`playbooks/`、`roles/`、`manifests/`、`docs/`、`tests/` | Ansible 部署、自定义 K8s 配置、文档与测试 | 待补充 |

详细的离线资源清单、版本、来源见 [`artifacts/README.md`](artifacts/README.md)。

## 常用命令

```bash
scripts/download-artifacts.sh      # 重新下载全部离线资源并校验（需访问 GitHub）
scripts/verify-checksums.sh        # 校验现有资源
scripts/package-offline.sh         # 展开成扁平目录（dist/offline-files），可直接上传到内网镜像站 ${FILE_URL}
```
