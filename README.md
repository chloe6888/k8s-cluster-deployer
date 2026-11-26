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
| `inventories/example/` | 带完整注释的参考样例（hosts/group_vars/host_vars）；真实集群 inventory 只存部署机本地，不入本仓库 |
| `playbooks/` | 阶段化 playbook：preflight → os-baseline → ha-entry → container-runtime → k8s-packages → init-master/join-masters → calico → join-workers → metallb → envoy-gateway → verify；kernel-pin 与 reset 单独执行 |
| `roles/` | 各阶段实现，配置内容以《部署手册》对应章节为准 |
| `docs/` | `DECISIONS.md` 决策记录、`ansible-implementation.md` 实施方案 |

## 多集群规划

一套代码、多个 inventory；组件版本全局唯一（`config/versions.yml`），集群差异只存在于各自 inventory：

- **集群 inventory（网段、VIP、VRID、网卡名、Harbor/mirror 实址）属内部信息，只存部署机本地，不入本仓库**；新集群 = 复制 `inventories/example/` 为 `inventories/<集群名>/` 并逐项替换
- 多集群同二层时 VRID 必须互不重叠（确认各自独立二层可复用同一对）；Pod/Service CIDR 各集群错开，为将来跨集群组网/互联留余量
- 每集群一份独立 `vault.yml`（独立 vault 口令）与 `files/harbor-ca.crt`；若多集群共用同一套 Harbor/文件站，实址填同一值即可
- 上线顺序建议：**测试环境全流程演练 → 生产集群**（先验证 playbook 与镜像，再上生产）
- `ansible.cfg` 无默认 inventory：**不带 `-i` 一律拒绝执行**，且 preflight-vars 会先打印"当前集群"横幅（集群名/节点数/VIP/VRID）供肉眼确认

## Ansible 使用

```bash
# 换集群 = 换 -i 目录（集群 inventory 在部署机本地，从 inventories/example/ 复制创建）
# 密码变量放 inventories/<集群>/group_vars/all/vault.yml（ansible-vault 加密，已被 .gitignore 排除）

ansible-playbook -i inventories/<集群> playbooks/site.yml --vault-password-file ~/.vault_pass.<集群>  # 整体部署（不含 kernel-pin/reset）
ansible-playbook -i inventories/<集群> playbooks/ha-entry.yml            # 单阶段
ansible-playbook -i inventories/<集群> playbooks/ha-entry.yml --tags verify    # 只做验证（所有阶段的 verify 块）
ansible-playbook -i inventories/<集群> playbooks/ha-entry.yml --limit k8s-master01  # 单台主机
ansible-playbook -i inventories/<集群> playbooks/join-workers.yml --limit k8s-worker11,k8s-worker12  # worker 灰度
ansible-playbook -i inventories/<集群> playbooks/kernel-pin.yml --tags os   # 固定内核（需 pin_kernel=true，会重启；never 标签须显式点名）
ansible-playbook -i inventories/<集群> playbooks/verify.yml --tags connectivity  # DNS/跨节点连通性演练（仅测试环境）
ansible-playbook -i inventories/<集群> playbooks/verify.yml --tags failover     # VIP 漂移演练（仅测试环境）
ansible-playbook -i inventories/<集群> playbooks/reset.yml --tags reset -e confirm_reset=yes  # 重置（双确认，仅测试环境）
```

阶段标签（`--tags`）：`os` / `ha` / `runtime` / `kubeadm` / `cni` / `lb` / `gateway`；`verify` 为只读验证；
`kernel-pin`、`reset`、连通性与漂移演练带 `never`，必须显式 `--tags` 才会执行（任务书写规范见 `docs/ansible-task-style.md`）。

## 离线资源命令

```bash
scripts/download-artifacts.sh      # 重新下载全部离线资源并校验（需访问 GitHub）
scripts/verify-checksums.sh        # 校验现有资源
scripts/package-offline.sh         # 展开成扁平目录（dist/offline-files），上传到内网镜像站 ${FILE_URL}
```
