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
| `playbooks/` | 阶段化 playbook：preflight → os-baseline → ha-entry → container-runtime → k8s-packages → init-master/join-masters → calico → join-workers → metallb → envoy-gateway → verify；kernel-pin 与 reset 单独执行 |
| `roles/` | 各阶段实现，配置内容以《部署手册》对应章节为准 |
| `docs/` | `DECISIONS.md` 决策记录、`ansible-implementation.md` 实施方案 |

## 多集群规划（cqjf / ms / msbc / test）

一套代码、四个 inventory；组件版本全局唯一（`config/versions.yml`），集群差异只存在于各自 inventory：

| 集群 | inventory | 内网段（占位） | 外网段（占位） | VRID 内/外 | Pod CIDR | Service CIDR |
| --- | --- | --- | --- | --- | --- | --- |
| cqjf | `inventories/cqjf/` | 10.1.0.0/24 | 10.101.0.0/24 | 51 / 52 | 10.244.0.0/14 | 10.96.0.0/12 |
| ms | `inventories/ms/` | 10.2.0.0/24 | 10.102.0.0/24 | 53 / 54 | 10.240.0.0/14 | 10.112.0.0/12 |
| msbc | `inventories/msbc/` | 10.3.0.0/24 | 10.103.0.0/24 | 55 / 56 | 10.248.0.0/14 | 10.128.0.0/12 |
| test | `inventories/test/` | 10.4.0.0/24 | 10.104.0.0/24 | 57 / 58 | 10.252.0.0/14 | 10.144.0.0/12 |

- **VRID 已按四集群互不重叠分配（51–58）**：即使某两个集群碰巧在同一二层也不会互抢；若确认各自独立二层可自行改回 51/52，同二层必须错开
- Pod/Service CIDR 四集群错开，为将来跨集群组网/互联留余量
- `inventories/*/` 内均为占位骨架（网段、VIP、网卡名、NTP、harbor/mirror 实址），部署前逐项替换；`inventories/example/` 保留为带完整注释的参考样例
- 每集群一份独立 `vault.yml`（独立 vault 口令）与 `files/harbor-ca.crt`；若四集群共用同一套 Harbor/文件站，实址填同一值即可
- 上线顺序建议：**test 全流程演练 → cqjf → ms → msbc**（先测试环境验证 playbook 与镜像，再上生产）
- `ansible.cfg` 无默认 inventory：**不带 `-i` 一律拒绝执行**，且 preflight-vars 会先打印"当前集群"横幅（集群名/节点数/VIP/VRID）供肉眼确认

## Ansible 使用

```bash
# CLUSTER=inventories/cqjf（换集群 = 换 -i 目录）
# 密码变量放 inventories/<集群>/group_vars/all/vault.yml（ansible-vault 加密，已被 .gitignore 排除）

ansible-playbook -i inventories/cqjf playbooks/site.yml --vault-password-file ~/.vault_pass.cqjf  # 整体部署（不含 kernel-pin/reset）
ansible-playbook -i inventories/cqjf playbooks/ha-entry.yml            # 单阶段
ansible-playbook -i inventories/cqjf playbooks/ha-entry.yml --tags haproxy   # 单步骤
ansible-playbook -i inventories/cqjf playbooks/ha-entry.yml --tags verify    # 只做验证
ansible-playbook -i inventories/cqjf playbooks/ha-entry.yml --limit k8s-master01  # 单台主机
ansible-playbook -i inventories/cqjf playbooks/join-workers.yml --limit k8s-worker11,k8s-worker12  # worker 灰度
ansible-playbook -i inventories/test  playbooks/kernel-pin.yml         # 固定内核（需 pin_kernel=true，会重启）
ansible-playbook -i inventories/test  playbooks/verify.yml --tags failover  # VIP 漂移演练（仅测试环境）
ansible-playbook -i inventories/test  playbooks/reset.yml -e confirm_reset=yes  # 重置（仅测试环境）
```

## 离线资源命令

```bash
scripts/download-artifacts.sh      # 重新下载全部离线资源并校验（需访问 GitHub）
scripts/verify-checksums.sh        # 校验现有资源
scripts/package-offline.sh         # 展开成扁平目录（dist/offline-files），上传到内网镜像站 ${FILE_URL}
```
