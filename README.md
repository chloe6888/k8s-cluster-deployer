# k8s-cluster-deployer

Kubernetes v1.36.6 离线高可用部署项目（Ubuntu 24.04、containerd 2.3.0、内网 Harbor、双网卡、多集群复用）。
两部分组成：**离线资源工程化**（`artifacts/` + CI 自动下载校验）与 **Ansible 部署工程**（`playbooks/` + `roles/`，按《部署手册》逐阶段落地，实施方案见 [`docs/ansible-implementation.md`](docs/ansible-implementation.md)）。

## 目录

| 目录 | 用途 |
| --- | --- |
| `artifacts/` | 离线安装资源：二进制、chart、签名密钥、官方 manifest、校验清单（详见 [`artifacts/README.md`](artifacts/README.md)） |
| `config/` | `versions.yml`：组件版本唯一事实源 |
| `templates/` | Jinja2 配置模板（containerd systemd 单元） |
| `scripts/` | 资源下载 / 校验 / 展平打包工具 |
| `ansible.cfg`、`requirements.yml`、`collections/` | Ansible 控制机配置与离线 collection |
| `inventories/<集群>/` | 每个集群一个目录：`hosts.yml`、`group_vars`、`host_vars`、`files/harbor-ca.crt`（集群专属，不入库） |
| `playbooks/` | 阶段化 playbook：00 预检 → 10 系统基线 → 20 高可用入口 → 30 运行时 → 40 K8s 包 → 50/51 master → 60 Calico → 70 worker → 80 MetalLB → 81 Envoy Gateway → 90 验收；11 内核固定与 99 重置单独执行 |
| `roles/` | 各阶段实现，配置内容以《部署手册》对应章节为准 |
| `docs/` | `DECISIONS.md` 决策记录、`ansible-implementation.md` 实施方案 |

## Ansible 使用

```bash
# 准备：换集群 = 换 inventory 目录（默认 inventories/example）
# 密码变量放 inventories/<集群>/group_vars/all/vault.yml（ansible-vault 加密，已被 .gitignore 排除）

ansible-playbook playbooks/site.yml --vault-password-file ~/.vault_pass          # 整体部署（不含 11/99）
ansible-playbook playbooks/20-ha-entry.yml                                      # 单阶段
ansible-playbook playbooks/20-ha-entry.yml --tags haproxy                       # 单步骤
ansible-playbook playbooks/20-ha-entry.yml --tags verify                        # 只做验证
ansible-playbook playbooks/20-ha-entry.yml --limit k8s-master01                 # 单台主机
ansible-playbook playbooks/70-join-workers.yml --limit k8s-worker11,k8s-worker12  # worker 灰度
ansible-playbook playbooks/11-kernel-pin.yml                                    # 固定内核（需 pin_kernel=true，会重启）
ansible-playbook playbooks/90-verify.yml --tags failover                        # VIP 漂移演练（仅测试环境）
ansible-playbook playbooks/99-reset.yml -e confirm_reset=yes                    # 重置（仅测试环境）
```

## 离线资源命令

```bash
scripts/download-artifacts.sh      # 重新下载全部离线资源并校验（需访问 GitHub）
scripts/verify-checksums.sh        # 校验现有资源
scripts/package-offline.sh         # 展开成扁平目录（dist/offline-files），上传到内网镜像站 ${FILE_URL}
```
