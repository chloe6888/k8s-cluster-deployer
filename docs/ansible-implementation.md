# Kubernetes 1.36.6 离线高可用集群 —— Ansible 实施方案

> 本文说明如何用 Ansible 把《Kubernetes 1.36.6 离线高可用集群部署手册》（下称"手册"）落地：按阶段写清楚每一步做什么、在哪些主机上做、怎么验证、出问题怎么办。
> 本文**不含代码和模板**。配置文件的具体内容以手册对应章节为准，本文只写"与手册不同的地方"。
> 变量名沿用手册，在 Ansible 里统一写成小写（`CLUSTER_PREFIX` → `cluster_prefix`，`NODE_IP` → `node_ip`）。

---

## 1. 实施总览

### 1.1 做法

- **一个阶段一个 playbook**，编号即执行顺序；每个阶段末尾有验证，验证不过不进入下一阶段。
- **可重复执行**：同一阶段连续跑两次，第二次不应有任何变更。
- **可逐步执行**：整体（`site.yml`）、单阶段、单步骤（按标签）、单台主机（`--limit`）都能单独跑。
- **kubectl 与 helm 通过命令行调用**，不依赖 `kubernetes.core` 模块（被管节点不需要 Python `kubernetes` 库，离线环境依赖最少）。

### 1.2 阶段总表

| 阶段 | 名称 | 目标主机 | 批量方式 | 对应手册 | 完成标志 |
| --- | --- | --- | --- | --- | --- |
| 00 | 预检 | 全部节点 | 并行 | 1.3、1.4、2.1 | 全部检查通过 |
| 10 | 系统基线 | 全部节点 | 并行 | 2.1–2.4、2.6–2.8 | sysctl、swap、时间同步符合预期 |
| 11 | 固定内核（单独执行） | 全部节点 | master 逐台；worker 分批 | 2.5 | `uname -r` 为目标内核 |
| 20 | 高可用入口 | 3 台 master | HAProxy 并行；keepalived 逐台 | 第 3 章 | 两个 VIP 在 master01 上、16443 可连通 |
| 30 | 容器运行时 | 全部节点 | 并行 | 第 4 章 | 能从 Harbor 拉取镜像；镜像预检通过 |
| 40 | Kubernetes 软件包 | 全部节点 | 并行 | 5.1、5.2 | kubeadm 版本为 1.36.6 |
| 50 | 初始化 master01 | master01 | 单台 | 5.4、5.5、5.7 | apiserver `readyz` 通过 |
| 51 | 加入 master02、03 | master02、03 | 逐台 | 5.8 | 3 个 etcd 成员健康 |
| 60 | Calico | master01 | 单台 | 第 6 章 | 所有节点 `Ready` |
| 70 | 加入 worker | 全部 worker | 分批（默认 10 台） | 5.9 | 每批 `Ready` 且 `calico-node` 正常 |
| 80 | MetalLB | master01 | 单台 | 第 7 章 | 地址池已创建 |
| 81 | Envoy Gateway | master01 | 单台 | 第 8 章 | Gateway `Programmed`，外网 IP 正确 |
| 90 | 验收 | master01 与全部节点 | — | 第 9 章 | 验收清单全部通过 |
| 99 | 重置（可选，单独执行） | 全部节点 | 每次 5 台 | 附录 C（正文缺失） | 节点回到可重新部署的状态 |

执行顺序：`00 → 10 → 11 → 20 → 30 → 40 → 50 → 51 → 60 → 70 → 80 → 81 → 90`。

- **11 与 99 不放进 `site.yml`**：11 会重启节点，必须单独、有意识地执行，并且要在 20 之前做完；99 会清掉集群，只用于测试环境回收和失败重试。
- **Calico（60）排在 worker（70）之前**：按手册 5.9 的建议，先装 CNI，再分批加入 worker，便于逐批观察 BGP 邻居建立。

---

## 2. 工程骨架与约定

**目录结构**（在现有仓库上扩展，`config/`、`artifacts/`、`scripts/`、`templates/` 保持原样）：

```
k8s-cluster-deployer/
├── ansible.cfg                  # forks=20、pipelining=True、collections_path=collections
├── requirements.yml             # ansible.posix / community.general / community.crypto
├── collections/                 # ansible-galaxy collection download 后入库（离线）
├── config/versions.yml          # 版本唯一来源（已有）
├── inventories/<集群>/
│   ├── hosts.yml                # 分组：masters、workers、first_master、k8s_all
│   ├── files/harbor-ca.crt      # 集群专属，.gitignore；仅 harbor_use_private_ca=true 时需要（决策 #41）
│   ├── group_vars/all/main.yml  # 原 k8s-deploy.env
│   ├── group_vars/all/vault.yml # 原 k8s-secrets.env（ansible-vault 加密）
│   └── host_vars/k8s-master0*.yml  # 原 node.env（master 专属；worker 变量内联在 hosts.yml）
├── playbooks/                   # 00 ~ 90、99、site.yml
└── roles/
```

**贯穿全局的约定**

1. **换集群 = 换一个 inventory 目录**，role 里不出现任何集群专属值。
2. **`node_ip` 必须显式写入**（worker 内联在 `hosts.yml`，master 在 `host_vars/`），不用 `ansible_default_ipv4`（默认路由在外网网卡，会取到外网 IP）；预检断言 `node_ip` 落在 `node_cidr` 内。
3. **vault 文件必须放在 `group_vars/all/` 目录里**才会被自动加载（放成 `group_vars/vault.yml` 不会生效，因为没有名叫 `vault` 的组）。
4. **离线依赖**：控制机也要离线可用，collection 用 `ansible-galaxy collection download` 入库。kubectl 与 helm 步骤用 `command`（行为与手册完全一致，排障直观，被管节点也不需要 Python `kubernetes` 库），稳定后再考虑换成 `kubernetes.core`。
5. **下载校验**：控制机对 `artifacts/checksums/SHA256SUMS` 全量校验通过后再推送到节点（决策 #39，文件站分发已取消）；校验失败即停止。
6. **敏感信息**：token、certificate-key、stats 密码、TLS 私钥所在的任务全部 `no_log: true`；TLS 临时文件只写 `/dev/shm`，用完删除。
7. **幂等**：每个任务第二次执行必须 `changed=0`，这是验收标准之一。不可幂等的步骤（内核清理、`kubeadm init/join`）用开关变量或 `creates` 保护。
8. **标签对应章节**：`os`、`ha`、`runtime`、`kubeadm`、`cni`、`lb`、`gateway`、`verify`，支持单章重跑。
9. **危险操作单独成 playbook，或标签默认不执行**：内核固定（11）、重置（99）、VIP 漂移演练（`failover`）、外网探测（`probe`）、连通性测试（`connectivity`）。

---

## 3. 开工前准备（一次性）

### 3.1 控制机

- `ansible-core` 2.17 及以上；collection 需要 `ansible.posix`、`community.general`、`community.crypto`，离线环境提前放到本地目录。
- 能以 root 通过 SSH 登录所有节点（手册为 root 部署）。
- 密码类变量用 `ansible-vault` 保存，不入仓库。

### 3.2 同步 GitHub 仓库

仓库目前与手册不一致，先改，否则后面的版本号会对不上：

1. `config/versions.yml`：Calico 改为 **3.32.2**；删除 `mergerfs_version`、`kyverno_version`；新增 `helm_version: 3.22.1`、Tigera operator 镜像版本 `v1.42.6`、MetalLB 的 FRR 镜像版本 `10.4.1`、内核版本 `6.8.0-149-generic`。
2. `artifacts/`：删除 mergerfs 与 Kyverno；Calico 的 operator Chart 更新为 3.32.2，并**新增 CRD Chart**（`crd.projectcalico.org.v1` 3.32.2）；重新生成 `checksums/SHA256SUMS`。
3. `scripts/download-artifacts.sh`、`scripts/package-offline.sh`、`.github/workflows/download-artifacts.yml`：Calico 的下载地址和文件名从 3.32.0 改为 3.32.2，增加 CRD Chart，去掉 mergerfs 与 Kyverno。
4. `docs/DECISIONS.md`：#10（Calico 3.32.2、operator v1.42.6、节点地址探测改用 `NODE_CIDR`）、#13（Gateway 增加 443）、#24（CRD Chart 版本）、#6（keepalived 异常时降优先级并自动回升，不再是"停止服务不自动恢复"）。
5. `.gitignore` 增加：`inventories/*/files/`、`*.vault_pass`、各集群的 `vault.yml`。

### 3.3 离线介质到位

| 介质 | 要求 | 获取方式 |
| --- | --- | --- |
| 二进制、Chart、公钥 | 手册 1.6 文件清单中的全部文件 | 控制机把本仓库 `artifacts/`（79MB 级）校验后推送到节点（决策 #39，统一单来源；文件站分发已取消） |
| 镜像 | 手册 1.6 镜像清单，全部推到 Harbor 公开项目 | 资源准备机推送，Ansible 不负责推送，只在阶段 30 做检查 |
| deb 包 | Kubernetes 源与系统包都在内网 apt 站 | 内网 apt 站 |
| Harbor CA | 集群专属，不入仓库；仅私有 CA 签发的 Harbor 需要（决策 #41） | `harbor_use_private_ca: true` 时放在控制机上该集群的 `files/harbor-ca.crt`；公网可信 CA 签发则保持 false，不建 certs.d |

校验方式：控制机对 `artifacts/checksums/SHA256SUMS` 全量校验（仓库相对路径，决策 #25），逐文件断言 `: OK` 后再经 `copy` 推送；`copy` 幂等，重跑只推变化的文件。校验失败就停止，不会继续安装。`Release.key` 另外还要核对 sha256 与 GPG 指纹。**节点上不得访问公网**。

### 3.4 Inventory

- 分组：`masters`（按 master01、02、03 的顺序写，这个顺序就是 keepalived 启动和 master 加入的顺序）、`workers`、`first_master`（只放 master01，凡是只在 master01 上做的阶段都用它）、`k8s_all`（前两者的合集）。
- 主机名写 `k8s-master01`、`k8s-worker11` 这种形式；节点名 `node_name` 即 inventory 主机名（决策 #44）——主机名在节点创建阶段配置好，工程不代改，`common` 角色断言系统 hostname 与 inventory 一致（不符即中止），`cluster_prefix` 仅用于 clusterName 等集群标识。
- 每个集群一个目录（`inventories/<集群名>/`），换集群就换目录。

---

## 4. 变量设计

| 手册变量 | Ansible 落点 | 备注 |
| --- | --- | --- |
| 1.3 ① 集群公共变量 | `group_vars/all/main.yml` | `REGISTRY`、`FILE_URL` 由 `harbor`、`mirror` 派生，用 Jinja 拼接，不重复填写 |
| 1.3 ② 密码变量 | `group_vars/all/vault.yml`（加密） | `ka_auth_pass`（≤8 位，预检断言）、`stats_user`、`stats_pass`、`gw_tls_cert`、`gw_tls_key` |
| 1.3 ③ 节点变量 | worker 内联 `hosts.yml`；master 在 `host_vars/` | `node_ip`、`node_ext_ip`（master 另有 `ka_state`、`ka_priority`，01/02/03 对应 MASTER 100 / BACKUP 90 / BACKUP 80，预检断言，防止写错）。两种写法 Ansible 等价，断言读的是 hostvars |
| `NTP_SERVER`、`EXTRA_NETS` | 列表 `ntp_servers`、`extra_nets` | 手册里是空格分隔的字符串，Ansible 里改成 YAML 列表 |
| `IMAGE_LIST` | 列表 `preload_images` | 取代手册里的清单文件 |
| 组件版本（手册 1.1） | `config/versions.yml` | 各 playbook 引入，不在 `main.yml` 里重复 |

注意事项：

- `vault.yml` 必须放在 `group_vars/all/` 目录里才会被自动加载。
- `node_ip` 必须显式写入（worker 内联 `hosts.yml`、master `host_vars/`），**不要用 `ansible_default_ipv4`**（默认路由在外网网卡，会取到外网 IP）。
- 新增的变量（手册 1.3 里没有）：
  - `stats_user`、`stats_pass`：把手册的 `STATS_AUTH` 拆成两个；
  - `gw_tls_cert`、`gw_tls_key`、`gw_tls_secret`（默认 `gw-ext-tls`）：Gateway 的 HTTPS 证书；
  - `etcd_quota_bytes`（默认 4294967296）；
  - `gw_http_redirect`（默认 `false`）：是否创建 80 → 443 的跳转；
  - `worker_batch_size`（默认 10）；
  - `pin_kernel`、`purge_old_kernels`（均默认 `false`）；
  - `preload_images`：worker 预拉的业务镜像列表，取代手册里的 `IMAGE_LIST` 文件；
  - `k8s_release_key_sha256`、`k8s_release_key_fingerprint`：`Release.key` 的校验值。

---

## 5. 对手册的修订点（实施时按本表执行）

| # | 手册位置 | 问题 | 实施时的处理 |
| --- | --- | --- | --- |
| 1 | 3.2 外网 frontend | 定义了 `EXT_API_ALLOWED_CIDR` 却没使用，外网 16443 实际对所有来源开放 | 外网 frontend 增加源地址白名单，不在白名单内的连接直接拒绝。**2026-11-26 随决策 #37 取消**：白名单与 `ext_api_allowed_cidr` 变量移除，外网入口访问控制由网络侧（安全组 / 防火墙）落实 |
| 2 | 5.4 `certSANs` | ~~缺外网 VIP，运维机经外网 VIP 访问 API 会证书校验失败~~ | **2026-11-27 随决策 #48 取消**：`ext_vip` 移出 certSANs——外网访问走 NGINX 入口（地址在 `extra_cert_sans`），无客户端以 ext_vip 直连 apiserver；certSANs 与手册 5.4 对齐（内网 VIP、各 master IP+主机名、`localhost`、`127.0.0.1`），额外地址由各集群 inventory 的 `extra_cert_sans` 提供 |
| 3 | 3.1、3.3 | 健康检查脚本用到 `socat`，但没有安装 | 与 HAProxy 一起安装 |
| 4 | 4.2 | 提到 Harbor CA 与 `hosts.toml`，但没有写入节点的步骤 | 阶段 30 补：写入 CA、写 `hosts.toml`、设置 containerd 的 `config_path` |
| 5 | 5.4 | `etcd` 配置放在 `KubeProxyConfiguration` 之后，会被当作 kube-proxy 的字段 | 放回 `ClusterConfiguration` 内，与 `networking` 同级 |
| 6 | 5.4 `taints` | 使用旧的 `node-role.kubernetes.io/master`，且 master02、03 的 join 不读这份配置，三台污点不一致 | 整段改为显式 `taints: []`：master 可调度业务 Pod（2026-11-26 决定），init 与 join 配置保持一致 |
| 7 | 5.4 | `podSubnet`、`serviceSubnet`、`nodePortAddresses` 写死 | 改用 `pod_cidr`、`service_cidr`、`node_cidr` |
| 8 | 5.4 | `criSocket` 为 `/var/run/containerd/containerd.sock` | 改为 `/run/containerd/containerd.sock`，与 crictl 配置一致 |
| 9 | 3.3 | 健康检查脚本用不带引号的 heredoc 生成，`$i`、`${PORT}` 会在生成时被提前展开 | 用模板渲染，只替换端口，shell 变量原样保留 |
| 10 | 1.3、3.2 | `STATS_AUTH` 与 `STATS_USER/STATS_PASS` 混用 | 统一为 `stats_user`、`stats_pass` |
| 11 | 概述、8.4 | 概述写 HTTP 80/443，Gateway 只有 80 | 增加 443 的 HTTPS 监听器，证书放在 `gw_tls_secret` 指定的 Secret 中 |
| 12 | 5.8 | 要求 master 加入后先 `Ready`，但此时 Calico 还没装，节点必然 `NotReady` | 闸门改为：新 master 的 4 个静态 Pod 都在运行，且 etcd 成员数和健康检查正确；不要求 Ready |
| 13 | 3.4 | 外网 keepalived 实例 `advert_int` 为 5，与同节"建议 1、不超过 3"矛盾 | 内外网默认都用 1 |
| 14 | 全文 | 镜像缺失要到第 6–8 章才暴露 | 阶段 30 增加镜像预检，提前发现 |
| 15 | 全文 | 系统包（haproxy、keepalived 等）在内网镜像站缺失要到第 3 章才暴露 | 阶段 00 增加 apt 候选版本检查 |

---

## 6. 逐阶段实施

每个阶段按"目标 → 前置条件 → 步骤 → 验证 → 注意"来写。"步骤"里的配置内容除特别说明外，都与手册对应章节一致。

### 6.1 阶段 00：预检

- **目标**：在动任何东西之前，把会导致后面失败的问题找出来。全部只读，不修改节点。
- **主机**：全部节点，并行。
- **步骤**：
  1. 确认系统是 Ubuntu 24.04、x86_64，且以 root 登录。
  2. 检查手册 1.3 中必填的变量都已填写，列表类变量不为空。
  3. 检查取值：`cluster_prefix` 全小写；`vip_port` 不是 6443；`ka_auth_pass` 不超过 8 位；`vip` 与 `ext_vip` 不相同；`gw_ext_ip` 必须在 `metallb_ext_range` 内；内网 VIP 在 `node_cidr` 内，外网 VIP 与 `ext_iface` 同网段；三台 master 的 `ka_state/ka_priority` 分别为 MASTER/100、BACKUP/90、BACKUP/80。
  4. 检查唯一性：全部节点的 `machine-id`、`product_uuid`、`node_ip`、`node_name` 互不相同（克隆机最容易重复，重复会导致 join 异常）。
  5. 检查网卡与路由（手册 2.1）：`node_iface`、`ext_iface` 存在；`node_ip` 在 `node_iface` 上；默认路由只有一条且在 `ext_iface` 上；Harbor 域名能解析，且访问 Harbor 的路由走 `node_iface`。
  6. 检查系统包能装：`apt-get update` 成功，`haproxy`、`keepalived`、`socat`、`chrony`、`nftables`、`gnupg` 在内网 apt 站都有候选版本。
  7. 网段冲突检查（手册 1.4）：用一个只依赖 Python 标准库 `ipaddress` 的脚本，检查 Pod、Service 网段与路由表、`node_cidr`、`extra_nets` 是否重叠。**只在尚未安装 Calico 的节点上执行**（判据为 `/etc/cni/net.d` 不存在；早期用 `tunl0` 判断已被 #42 纠正——`ipip` 模块在阶段 10 就加载，`tunl0` 随之出现，会把之后的重跑全部误豁免）。
- **验证**：所有检查通过，且重复执行不产生任何变更。
- **注意**：任何一项失败都应直接中止并指出是哪台节点、哪个变量，不要尝试自动修复。

### 6.2 阶段 10：系统基线

- **目标**：落实手册第 2 章（除内核固定外）。
- **主机**：全部节点，并行。
- **步骤**：
  1. **解析**：主机名与 `/etc/hosts` 不代改不代写（决策 #44/#45，节点创建阶段统一配置）；核对每个节点名解析到其内网 IP、Harbor 域名可解析，不符即中止。探测与判定分为两步（#47）：`getent` 任务 `failed_when: false` 只采集，紧随的 `assert` 带上"解析到了什么/期望什么/常见原因（/etc/hosts 缺条目、Ubuntu 默认 127.0.1.1 回环行、解析到外网 IP）"的可操作报错。
  2. **内核模块**：写入开机加载清单（`overlay`、`br_netfilter`、`ipip`，以及 `nf_tables`、`nf_nat`、`nf_conntrack`），并立即加载。清单单一事实源在 role 的 `defaults/main.yml`（`os_modules_load`，决策 #46），片段文件、立即加载、verify 共用。
  3. **sysctl**：写入手册 2.2 的 9 项参数（含 `ip_nonlocal_bind=1`、`rp_filter=2`、三项 inotify），写入后执行 `sysctl --system`。期望值单一事实源在 `os_sysctl_expect`（决策 #46），模板与 verify 共用。`rp_filter` 即使与系统默认值重复也要写入，不能省略（防止加固基线改回 1）。
  4. **nftables**（手册 2.3，这一步最容易出事，单独说明）：
     - 只装 `nftables` 命令行工具，不使用它的服务；
     - 安装后立即 `disable` + `stop` + `mask`（决策 #36）：不启动、不开机启动、防误启动；
     - 原因：该服务 start / reload / stop 都会执行 `nft flush ruleset`，清空 kube-proxy、Calico 和主机防火墙的全部规则；mask 之后无法被误启动；
     - 任何阶段都禁止 `nft flush ruleset`。
  5. **关闭 swap**：有 swap 就 `swapoff -a`，并注释 `/etc/fstab` 里 `/swap.img` 那一行。
  6. **DNS**：无条件保证 `systemd-resolved` 服务 started+enabled（决策 #46 及勘误：要防的是"装了没起"——resolved 不 active 时 kubelet 会读到 127.0.0.53 stub 回环；24.04 的包随基础系统就位，故不做 apt 装包——离线/受限镜像节点的 apt 索引可能不含该包名，test 实测报 No package matching）。
  7. **时间同步**：安装 chrony（会自动卸载 timesyncd，属预期）；配置里只写 `ntp_servers` 每个地址一行 `server … iburst`，不配 `allow` 与 `local`；其余参数同手册 2.7；启动并设为开机启动。
  8. **journald**：先确保 `/etc/systemd/journald.conf.d` 存在（原装 Ubuntu 24.04 不带该目录，template 不建父目录，决策 #46），写入容量限制配置（`SystemMaxUse` 取 `journald_system_max_use`，默认 4G），重启 journald。
- **验证**：9 项 sysctl 与手册一致（逐项迭代内比较，期望值同 `os_sysctl_expect`）；swap 为 0；`nftables` 为 masked 且 inactive（排序后整体相等，缺行必拦）；`systemd-resolved` active 且 `/run` 上游文件含真实 nameserver（无 127.0.0.53）；`chronyc sources` 至少有一个可用源（初次同步最多等 2 分钟）；Harbor 域名可解析。
- **注意**：第一次执行有配置变更属正常，第二次必须没有变更。

### 6.3 阶段 11：固定内核（单独执行）

- **目标**：落实手册 2.5，把内核固定为 `kernel_version` 并锁定。
- **主机**：master 逐台（一次一台，不会三台同时重启）；worker 按 `worker_batch_size` 分批。
- **前置条件**：`pin_kernel` 设为 true（默认 false，没开则整个阶段直接跳过）；内网 apt 站已同步目标内核；必须在阶段 20 之前执行。
- **步骤**：
  1. 检查内网镜像站有目标内核的候选版本，没有就停止。
  2. 安装 `linux-image`、`linux-headers`、`linux-modules`、`linux-modules-extra` 四个包；确认 `/boot` 下的 `vmlinuz` 与 `initrd.img` 都存在（缺任何一个都不能重启）。
  3. 如果当前运行的内核不是目标内核：确认没有 `grub.d` 下的文件覆盖 `GRUB_DEFAULT`；更新 grub；确认菜单里有目标内核的标题；把 `GRUB_DEFAULT` 固定到该菜单项；再次更新 grub；重启；重启后确认 `uname -r` 就是目标内核。
  4. 清理旧内核**只在 `purge_old_kernels` 为 true 时执行**：先生成待移除包清单并输出，清单里不得出现 kubelet、containerd 等无关包；清理后把 `GRUB_DEFAULT` 改回 0，确认 `/boot` 下只剩目标内核。
  5. 锁定：对四个内核包执行 hold；对**已安装**的内核元包（`linux-generic`、`linux-image-generic`、`linux-headers-generic`、`linux-virtual` 系列、`linux-generic-hwe-24.04` 系列等，完整清单见手册 2.5 ⑤）逐个 hold。
  6. 关闭自动更新：把 `20auto-upgrades` 里的 `Unattended-Upgrade` 改为 0；停止并禁用 `unattended-upgrades` 与 `apt-daily-upgrade.timer`。
- **验证**：`uname -r` 是目标内核；`apt-mark showhold` 包含内核包与已安装的元包。
- **注意**：固定内核并关闭自动更新后，节点不再收到内核安全更新，这是手册附录 A.2 登记的风险接受项。

### 6.4 阶段 20：高可用入口（keepalived + HAProxy）

- **目标**：落实手册第 3 章，让内外两个 VIP 能漂移，并把 API 流量转到三台 master 的 6443。
- **主机**：3 台 master。
- **前置条件**：VRID 在二层网络内没有被占用（手册 3.0，用 `tcpdump vrrp` 抓包确认，这一步仍由人工做）；网卡名、VIP 已由网络侧确认。
- **步骤**：
  1. 安装 `haproxy`、`keepalived`、`socat`（修订点 3）；首次安装后先停止两个服务，配置完成前不启动。
  2. **HAProxy 配置**（手册 3.2，三台相同，只有统计页绑定的 `node_ip` 不同）：
     - 内网 frontend 绑定 `vip:vip_port`；外网 frontend 绑定 `ext_vip:vip_port`（源地址白名单已随决策 #37 取消）；
     - 后端三台 master 的 6443，服务器名取各自的 `node_name`；
     - 统计页账号用 `stats_user`、`stats_pass`；配置文件权限 0640（含密码）；
     - 写入前用 `haproxy -c` 校验。
  3. **健康检查脚本**（手册 3.3）：按模板渲染，只替换端口，不展开脚本里的 shell 变量（修订点 9）；属主 root，权限 0755。
  4. **keepalived 配置**（手册 3.4）：两个实例，状态与优先级取各节点的 `ka_state`、`ka_priority`（master01 为 MASTER/100，master02 BACKUP/90，master03 BACKUP/80）；`weight -30`；`advert_int` 内外网默认都为 1（修订点 13）；网卡标签超过 15 个字符时去掉 `label`（单播变体已随决策 #38 取消，不涉及 `node_ip`/`node_ext_ip`）；写入前用 `keepalived -t` 校验；权限 0600。
  5. **启动依赖**：让 keepalived 在 HAProxy 之后启动（systemd 的 drop-in）。
  6. **启动顺序**：三台 master 同时启动并启用 HAProxy；然后 keepalived **按 master01、02、03 的顺序逐台启动**，master01 启动后要等到两个 VIP 都出现在它身上，再启动下一台。
  7. 对 `haproxy`、`keepalived` 执行 hold。
- **使用注意**（决策 #42）：在已运行的集群上重跑本阶段、且 HAProxy/keepalived 配置真有变更时，第一段 play 不做串行——三台的 handler 并行触发，HAProxy/keepalived 同时重启，API 入口会有一次短暂中断/VIP 漂移（配置未变则 handler 不触发，无影响）。生产集群改 HA 配置请安排窗口，或逐台 `--limit` 执行。
- **验证**：
  - master01 持有内外两个 VIP；
  - 每台 master 上 `vip:vip_port`、`ext_vip:vip_port` 都能连通；
  - 两个服务都在运行并已设为开机启动。
- **不放进主流程的检查**（会停 HAProxy 或需要外部探测机，放在阶段 90 的 `failover`、`probe` 标签里，需要时单独执行）：漂移演练（手册 3.6）；手册 3.7 要求的 `6443/2379/10250` 外网探测必须全部不通（由网络侧 ACL 落实，是上线准入项）。

### 6.5 阶段 30：容器运行时

- **目标**：落实手册第 4 章，并确认后续需要的镜像都在 Harbor 里。
- **主机**：全部节点，并行。
- **步骤**：
  1. **containerd 2.3.0**：获取并校验压缩包与 systemd 单元（单元文件随 artifact 渠道取到 `package_dir`，同样受控于控制机侧校验；仓库侧源文件是 `templates/systemd/containerd.service.j2`，纯静态内容）；当前版本不是 2.3.0 才解压安装，只装到 `/usr/local/bin`，并确认只有这一个 `containerd`；从 `package_dir` 安装单元，确认 `ExecStart` 是 `/usr/local/bin/containerd`。
  2. **生成配置**：只在 `config.toml` 不存在时执行 `containerd config default`。然后做三处修改：sandbox 镜像改成 `${REGISTRY}/google_containers/pause:3.10.2`（与 kubeadm 的 `imageRepository` 同路径，决策 #4）；`SystemdCgroup` 改为 true；registry 的 `config_path` 设为 `/etc/containerd/certs.d`（修订点 4；2.x 的 default 输出是单引号，且 transfer 段也有 `config_path` 键，替换必须锚定 registry 段头，不能按 `"config_path = \"\"` 字面匹配）。修改后用 `containerd config dump` 逐项确认，**任何一项不符就停止**（手册 4.2 注明 2.3.0 的键位待验证，以实测为准；实测通过后，把这份配置固化成模板，以后用模板生成）。三处替换与解压安装都挂 `Restart containerd` 通知，flush 点在 Harbor 访问配置之前（后续 hosts.toml 依赖运行态）。
  3. **Harbor 访问**（修订点 4，决策 #41）：`harbor_use_private_ca` 为 true 时，对 Harbor 以及 `app_registry`（不为空且主机不同）的主机，建 `/etc/containerd/certs.d/<主机>/`，放入 Harbor CA，写 `hosts.toml`（`server` 为 https，`capabilities` 为 pull 与 resolve，`ca` 指向该目录里的 CA）。为 false（默认，Harbor 证书是公网可信 CA 签发）则整段跳过，containerd 走系统信任链。生产环境不使用 `skip_verify`。
  4. **runc 1.4.2**：获取并校验 `runc.amd64` 与 `runc.sha256sum`；卸载 apt 版 runc；安装到 `/usr/local/sbin/runc`；变更后重启 containerd。
  5. **nerdctl 2.3.0**：获取并校验压缩包，解压到 `/usr/local/bin`。
  6. 启动 containerd 并设为开机启动。
  7. **镜像预检**（只在 master01 上执行一次）：用 `nerdctl --namespace k8s.io` 逐个拉取下列镜像，**任何一个失败都中止**并列出缺失的镜像：
     - `google_containers/pause:3.10.2`、`tigera/operator:v1.42.6`；
     - `calico/` 下的 `node`、`cni`、`typha`、`kube-controllers`、`apiserver`、`pod2daemon-flexvol`、`key-cert-provisioner`，版本均为 `v3.32.2`；
     - `metallb/controller:v0.15.3`、`metallb/speaker:v0.15.3`、`frrouting/frr:10.4.1`；
     - `envoyproxy/gateway:v1.7.1`、`envoyproxy/envoy:distroless-v1.37.1`；
     - `calico/csi`、`calico/node-driver-registrar`：手册注明以安装后实测为准，拉取失败只提示，不中止。

     Kubernetes 系统镜像（kube-apiserver、etcd、coredns 等）由阶段 50 的 `kubeadm config images pull` 验证。
- **验证**：containerd 在运行；`runc --version` 为 1.4.2；能从 Harbor 拉取 pause 镜像；第 2 步三项配置确认无误。

### 6.6 阶段 40：Kubernetes 软件包

- **目标**：落实手册 5.1、5.2，并安装 helm。
- **主机**：全部节点，并行；helm 只装在 master。
- **步骤**：
  1. **公钥核对**：下载 `Release.key`，核对 sha256 与 GPG 指纹（分别对照 `k8s_release_key_sha256`、`k8s_release_key_fingerprint`），**不一致立即停止**——这把公钥的可信度只靠内网镜像站，必须核对；通过后转成 apt 使用的 keyring。
  2. **配置 apt 源**：写入 `apt_k8s_url`；执行 `apt update`；确认 `kubeadm` 版本表含 `1.36.6-1.1` 条目且来源是配置的镜像站（决策 #43：多版本公共源的 Candidate 是仓库最高版而非目标版，故不再断言 Candidate == 1.36.6；内网单版本镜像站下两语义等价）。
  3. **安装**：`kubelet`、`kubeadm`、`kubectl` 固定为 1.36.6，并 hold；kubelet 只设为开机启动，**不要启动**。
  4. **固定节点 IP**：写入 `/etc/default/kubelet`，内容为 `--node-ip=<本机 node_ip>`（双网卡节点必须在 init/join 之前完成）。**这是全部节点 node-ip 的唯一来源**：worker 用 `kubeadm token create --print-join-command` 的命令行加入、没有配置文件，必须靠它；因此 kubeadm 的 init / join 配置里不再写 `kubeletExtraArgs`。
  5. **crictl**：没有就安装 `cri-tools` 并 hold；写入 `/etc/crictl.yaml`，指向 containerd 的 socket。
  6. **安装 helm**（只在 master）：获取并校验 `helm-v3.22.1-linux-amd64.tar.gz`，按版本号建解压目录再复制到 `/usr/local/bin/helm`，随后用 `helm version --short` 校验版本。Calico、MetalLB、Envoy Gateway 阶段由 master01 调用它。
- **验证**：`kubeadm version` 为 v1.36.6；`apt-mark showhold` 含 kubelet、kubeadm、kubectl、cri-tools；`crictl info` 正常。

### 6.7 阶段 50：初始化 master01

- **目标**：落实手册 5.4、5.5、5.7。
- **主机**：master01。
- **步骤**：
  1. **渲染 kubeadm 配置**：内容同手册 5.4，并应用修订点 2、5、6、7、8：`certSANs` 含内网 VIP、各 master 内网 IP 与节点名、`localhost`、`127.0.0.1` 及 `extra_cert_sans`（决策 #48：ext_vip 不进 SAN）；`etcd` 放进 `ClusterConfiguration`；`taints: []`（master 可调度）；网段与 `nodePortAddresses` 用变量；`criSocket` 用 `/run/...`；`imageRepository` 为 `${REGISTRY}/google_containers`；叶子与 CA 有效期均 `175200h`；node-ip 不在此设置（见 6.6 第 4 步）。配置文件权限 0600。
  2. 用 `kubeadm config validate` 校验配置，不通过就停止。
  3. 只在集群尚未初始化时执行（判据：apiserver 中不存在 `kube-system/kubeadm-config`；不用 `admin.conf` 是否存在来判断，因为 init 中途失败也会留下它）：先确认 `vip:vip_port` 可连，再 `kubeadm config images pull`，再 `kubeadm init --config`，命令自动重试 2 次、间隔 30s（决策 #49：静态 Pod 冷启动+HAProxy 后端转绿可能超过 kubeadm 内部 ~60s bootstrap 超时，该失败模式下 init 可重入、证书复用，重试自愈慢启动）。不加 `--upload-certs`，join 凭据由 6.8 每台现生成；init 输出不屏蔽，失败时能直接看到原因。
  4. 把 `admin.conf` 复制到 `~/.kube/config`，权限 0600。
  5. **证书有效期校验**：用 `openssl x509 -checkend 599184000`（19 年）确认 `ca.crt` 与 `apiserver.crt` 确已按 20 年签发。helm 不在本阶段安装，已移到阶段 40（6.6 第 6 步）。
- **验证**：
  - apiserver 的 `/readyz` 返回 ok；
  - `kubeadm certs check-expiration` 显示叶子证书与 CA 均约 20 年；
  - etcd 静态 Pod 的参数里 `quota-backend-bytes` 等于 `etcd_quota_bytes`；
  - 节点此时显示 `NotReady` 属正常（Calico 还没装），**不要对 Ready 做断言**。

### 6.8 阶段 51：加入 master02、master03

- **目标**：落实手册 5.8。
- **主机**：master02、master03，**逐台执行，一台完成并通过闸门后才开始下一台**。
- **步骤**（对每一台）：
  1. 确认该节点的 `/etc/default/kubelet` 里是本机 `node_ip`，且能连通 `vip:vip_port`。
  2. 在 master01 上**现生成**凭据（`certificate-key` 只有 2 小时有效，所以每台 join 前都重新生成）：`kubeadm token create --ttl 1h` 取得 token，计算 CA 公钥 hash，`kubeadm init phase upload-certs --upload-certs` 取得 `certificate-key`。这些任务都 `no_log`。
  3. 渲染本节点专用的 JoinConfiguration（权限 0600，含 token 与 certificate-key；`controlPlane.localAPIEndpoint.advertiseAddress=<本机 node_ip>`、`bindPort: 6443`——v1beta4 的 JoinControlPlane 只有 `localAPIEndpoint` 与 `certificateKey` 两个字段，`apiserverAdvertiseAddress` 是命令行 flag，写进配置会被严格解码拒绝——必须带，否则双网卡下 etcd peer 可能用错地址；`taints: []`）；渲染后先过 `kubeadm config validate`（输出不含凭据，不屏蔽），再执行 `kubeadm join --config`；已存在 `kubelet.conf` 则跳过。join 命令的命令行不含凭据，输出也不屏蔽，失败时直接可见；配置文件在 `always` 中删除，成功或失败都不遗留。
  4. 把 `admin.conf` 复制到该节点的 `~/.kube/config`。
  5. **闸门**（修订点 12）：反复检查（最多约 5 分钟），直到新节点的 etcd、kube-apiserver、kube-controller-manager、kube-scheduler 四个静态 Pod 都在运行，并且 etcd 成员数等于已加入的 master 数、`endpoint health --cluster` 全部 healthy。
  6. `kubeadm certs check-expiration` 同样应为约 20 年。
- **验证**：三个 etcd 成员健康；三台 master 的证书有效期符合预期。

### 6.9 阶段 60：Calico 3.32.2

- **目标**：落实手册第 6 章。
- **主机**：master01。
- **步骤**：
  1. 获取并校验两个 Chart：`tigera-operator-v3.32.2.tgz` 与 `crd.projectcalico.org.v1-v3.32.2.tgz`（**CRD Chart 不能漏**）。
  2. **nft 预检**（强制）：在节点上用 `calico/node:v3.32.2` 镜像运行 `nft list tables`，返回码必须是 0。3.32.0 的 nft 曾在这里崩溃，不通过就不要继续。
  3. **安装 CRD**：用 `helm template --include-crds` 渲染 CRD Chart 到文件，用 `kubectl diff --server-side` 判断有无差异，有差异才 **server-side apply**（CRD 太大，普通 apply 会超出注解长度上限）。`tigera-operator` 命名空间由 `helm upgrade --install --create-namespace` 创建。
  4. **渲染 values**（手册 6.4）：`manageCRDs: false`；`registry` 为 `${REGISTRY}/`（结尾要有斜杠）；BGP 开启；节点地址探测用 `node_cidr`；IP 池为 `pod_cidr`、IPIP、`blockSize 25`、`natOutgoing`；启用 apiServer；**显式关闭 goldmane 与 whisker**；operator 镜像 `tigera/operator:v1.42.6`；不设置 `imagePath`。
  5. **安装 operator**（`helm upgrade --install --history-max 5`）：只在 release 不存在、状态不是 `deployed`、chart 版本变化或 values 文件有变化时执行。
  6. 等待 `tigerastatus` 全部为 Available（最多约 10 分钟）。
  7. **镜像核对**：核对 `calico-system` 里实际运行的 Pod 镜像都以 `${REGISTRY}/` 开头。`helm template` 的结果只含 operator 自己的镜像，其余组件镜像由 operator 按 `Installation.spec.registry` 在运行时生成，所以必须在安装后检查。
  8. 等待所有节点 Ready（最多约 10 分钟）。
- **验证**：IP 池的网段、IPIP Always、`blockSize 25`、`natOutgoing` 与配置一致；`calico-system` 里 `calico-node` 全部 Ready；三台 master 都是 `Ready`。

### 6.10 阶段 70：加入 worker

- **目标**：落实手册 5.9，分批加入。
- **主机**：全部 worker，每批 `worker_batch_size` 台（默认 10）。
- **步骤**（每一批）：
  1. 在 master01 生成这一批共用的 token（`--ttl` 默认 4 小时，只需 token 与 hash，不需要 certificate-key）；凭据不写日志。
  2. 对批内每台 worker：
     - 确认 `/etc/default/kubelet` 已写好；
     - 预检 nft（同阶段 60 第 2 步，同时会把 `calico/node` 镜像预拉到该节点）；
     - 预拉 `preload_images` 列表里的业务镜像（列表为空就跳过；私有仓库需要事先登录）；
     - 执行 `kubeadm join <vip>:<vip_port>`，带 token、hash、`--node-name`；已存在 `kubelet.conf` 则跳过。
  3. **批次闸门**：批内每台都要等到节点 `Ready`，且该节点上的 `calico-node` Pod 是 Ready，才开始下一批。
- **验证**：每批通过闸门；全部 worker 加入后所有节点 `Ready`。
- **注意**：任何一批失败整个 playbook 中止，后面的批次不会执行，便于逐批排查 BGP 邻居问题。

### 6.11 阶段 80：MetalLB

- **目标**：落实手册第 7 章。
- **主机**：master01。
- **步骤**：
  1. 获取并校验 `metallb-0.15.3.tgz`。
  2. 创建 `metallb-system` 命名空间，并给它打上 Pod Security 的 `privileged` 标签（speaker 需要特权）。
  3. 渲染 values：controller、speaker、frr 三处镜像都指向 `${REGISTRY}`。
  4. 用 `helm template … | grep image:` 核对三个镜像都在 `${REGISTRY}` 下。
  5. 安装，等待 `metallb-controller` 与 `metallb-speaker` 就绪。
  6. 创建地址池 `pool-ext`（`autoAssign: false`，地址取 `metallb_ext_range`）和 L2 广播 `l2-ext`（接口为 `ext_iface`）。admission webhook 还没就绪时会报错，重试最多约 100 秒。
- **验证**：`pool-ext`、`l2-ext` 存在；speaker 在所有节点上都是 Ready。

### 6.12 阶段 81：Envoy Gateway 1.7.1（含 HTTPS）

- **目标**：落实手册第 8 章，并补上 443（修订点 11）。
- **主机**：master01。
- **步骤**：
  1. 获取并校验 `gateway-helm-v1.7.1.tgz`；values 只设 `global.imageRegistry`；核对渲染出的镜像都是 `${REGISTRY}/envoyproxy/gateway:v1.7.1`。
  2. 安装，等待 `envoy-gateway` 部署 Available；确认 Gateway API 的 CRD 已存在，缺失就停止。
  3. 创建 EnvoyProxy 与 GatewayClass（手册 8.3）：数据面 2 副本、镜像 `envoyproxy/envoy:distroless-v1.37.1`、Service 类型 LoadBalancer、`externalTrafficPolicy: Cluster`、地址池 `pool-ext`、固定 IP 为 `gw_ext_ip`。
  4. **创建 TLS Secret**（`gw_tls_enabled` 为 true 时）：
     - 先在控制机上校验证书未过期，且证书与私钥匹配（公钥指纹相同）；
     - 把证书与私钥写到 master01 的内存目录（`/dev/shm`）下的临时文件，权限 0600，任务不输出内容；
     - 用 `kubectl create secret tls … --dry-run | kubectl apply` 创建，Secret 名为 `gw_tls_secret`、命名空间为 `envoy-gateway-system`；
     - 无论成功失败，**都要删除临时文件**。
  5. 创建 Gateway `gw-ext`：监听器 `http`（80）；启用 TLS 时增加监听器 `https`（443，TLS 终止，引用上面的 Secret）；两个监听器的 `allowedRoutes` 都是 `from: All`（风险接受项，多团队共用集群时应改为按标签选择）。
  6. **可选 HTTP 跳转**（`gw_http_redirect` 为 true 才创建，默认 false）：创建挂在 `http` 监听器上的路由，把请求 301 跳转到 https。注意它会接管 80 上所有未被其他路由匹配的请求。
- **验证**：
  - `gw-ext` 的 `Programmed` 为 True，每个监听器也是；
  - Envoy 的 Service 的外网 IP 等于 `gw_ext_ip`（最多等约 2.5 分钟），端口包含 80 与 443；
  - 数据面 Deployment 的镜像都以 `${REGISTRY}` 开头。
- **注意**：证书若来自企业内部 CA，外网客户端必须信任该 CA，这是交付侧的前置条件。

### 6.13 阶段 90：验收

- **目标**：把手册 9.1 的验收清单逐项变成自动检查，只读。
- **主机**：master01（集群级检查）与全部节点（节点级检查）。
- **检查项**（全部通过才算完成，失败项在最后汇总输出，而不是遇到第一个就停）：
  - 节点：全部 `Ready`，`INTERNAL-IP` 与各自的 `node_ip` 一致；
  - 系统 Pod：没有非 Running、非 Completed 的；
  - 离线纯净度：`kube-system`、`calico-system`、`calico-apiserver`、`tigera-operator`、`metallb-system`、`envoy-gateway-system` 里所有镜像都来自 `${REGISTRY}`；
  - apiserver：`/readyz?verbose` 以 `readyz check passed` 结尾；
  - 内核与锁定：`uname -r` 与 hold 列表（所有节点）；
  - inotify 三项为 8192 / 1048576 / 65536（所有节点）；
  - kube-proxy：模式为 nftables，`nodePortAddresses` 为 `node_cidr`；
  - 证书：每台 master 叶子与 CA 均约 20 年；
  - Calico：`tigerastatus` 全部 Available；IPIP Always、`/25`、`natOutgoing`；
  - VIP：内、外网 VIP 各只在一台 master 上；
  - kubelet 配置：`maxPods`、预留、驱逐阈值（含 `nodefs.inodesFree`）、日志轮转与配置一致（所有节点）；
  - journald：`SystemMaxUse` 与配置一致；
  - MetalLB 与 Gateway：同阶段 81 的验证；
  - etcd：全部 healthy。
- **默认不执行的检查**（需要用标签单独指定）：
  - `failover`：VIP 漂移演练——停掉持有 VIP 的 HAProxy，确认两个 VIP 迁走，恢复后 master01 抢回；会短暂影响 API 入口，只在测试环境做；
  - `probe`：从探测机（`delegate_to`）对 master 外网 IP 的 6443/2379/10250 做探测，必须全部不通（网络侧准入项）。
- **可选连通性测试**（手册 9.2，默认不执行，需要指定 `busybox_tag`）：测试 DNS 解析，以及在两个不同节点上各起一个 Pod 互相 ping，测完无论成败都删除测试 Pod。

### 6.14 阶段 99：重置（可选，单独执行）

- **目标**：测试环境反复重建和失败重试的退路。手册只在附录 C 提到清理，但正文没有内容，所以这里补上。
- **主机**：全部节点，每次 5 台。
- **前置条件**：必须带 `-e confirm_reset=yes`，不放进 `site.yml`。
- **步骤**：
  1. 执行 `kubeadm reset -f`（节点没初始化过则忽略错误）。
  2. 清理 CNI 配置（`/etc/cni/net.d`、`/var/lib/cni`）、`/var/lib/kubelet`、master 上的 `/var/lib/etcd`、`~/.kube`、`/root/kubeadm`。
  3. 删除 `tunl0` 网卡（存在时）；卸载 `ipip` 模块为可选。
  4. 网络规则：先 `nft list tables` 输出到日志，**只删除自己创建的表**（默认只有 `kube-proxy`），**绝不 `nft flush ruleset`**。
  5. 清理容器：`crictl rm -fa`、`crictl rmp -fa`（失败忽略）。
  6. 默认保留 HAProxy 与 keepalived、内核固定和已安装的软件包；设置 `reset_ha=true` 才停止并禁用 HAProxy 与 keepalived。
- **验证**：节点上没有 kubelet 数据，`tunl0` 不存在；重新执行 `site.yml` 能完整跑通。

---

## 7. 逐步执行方式

| 想做什么 | 怎么做 |
| --- | --- |
| 整体部署 | 执行 `site.yml`（不含阶段 11） |
| 只跑某个阶段 | 执行对应编号的 playbook，如 `playbooks/20-ha-entry.yml` |
| 看某阶段有哪些步骤 | 加 `--list-tasks` |
| 预演，不实际修改 | 加 `--check --diff` |
| 只跑某一步 | 加 `--tags <步骤标签>`，如 `haproxy`、`sysctl` |
| 只做验证 | 加 `--tags verify` |
| 只跑某台主机 | 加 `--limit <主机名>` |
| worker 灰度 | 阶段 70 加 `--limit` 指定几台，确认没问题再放开 |
| 只做 VIP 漂移演练（仅测试环境） | 执行 `90-verify.yml --tags failover` |
| 重置（仅测试环境） | 执行 `99-reset.yml -e confirm_reset=yes` |
| 使用加密变量 | 加 `--vault-password-file <文件>` |

---

## 8. 测试与交付节奏

每个里程碑的完成标准都一样：语法检查与 `ansible-lint` 通过；在测试环境（3 master + 2 worker，双网卡，能访问内网 Harbor、apt 站）连续运行两次，第二次没有变更；对应阶段的验证全部通过。

| 里程碑 | 内容 | 额外验收 |
| --- | --- | --- |
| M0 | 同步仓库（3.2）、建工程骨架与 inventory 样例、实现"获取并校验文件"的公共任务 | 能 ping 通所有节点 |
| M1 | 阶段 00、10 | 故意制造重复 machine-id、错误网段，预检能拦截 |
| M2 | 阶段 11（可选）、20、30、40 | VIP 漂移按手册 3.6 手工演练通过；镜像预检通过；`config.toml` 固化为模板 |
| M3 | 阶段 50、51 | 3 个 master，etcd 3 成员健康，证书有效期正确 |
| M4 | 阶段 60、70 | 全部节点 Ready；先加入 2 台 worker，再放大到整批 |
| M5 | 阶段 80、81、90 | Gateway Programmed，80 与 443 可访问；验收全部通过 |
| M6 | 阶段 11、99，阶段 90 的 `failover`、`probe` 标签 | 从重置到验收完整跑通一次 |

每个里程碑都做三件事：**空环境首跑 → 立刻二次运行（应零变更）→ 中途故意中断再重跑（应能续上）**。阶段 11 因为要重启节点，单独验证。

---

## 9. 默认假设与待确认

**默认假设**（没有异议就按此实施）：

- 控制机已离线可用，collection 入库。
- kubectl 与 helm 步骤先用 `command`，稳定后再考虑替换。
- containerd 的 `config.toml`：在测试机上用 2.3.0 生成基线并确认三项（pause、`SystemdCgroup`、`config_path`）后，固化成完整模板，不用 sed。
- `purge_old_kernels` 默认 `false`。
- 证书有效期：叶子证书与 CA 均 20 年（`175200h`，2026-11-26 由叶子 10 年改为 20 年；叶子不得超过 CA）；init 阶段用 `openssl -checkend` 校验，验收按 `kubeadm certs check-expiration` 的实际输出断言。
- 重置、漂移演练、外网探测默认不执行。

### 待确认

1. 外网 keepalived 的 `advert_int` 是保留手册的 5，还是按同节建议改为 1（本文默认 1）。
2. Harbor CA 放在控制机的 `inventories/<集群>/files/harbor-ca.crt` 是否合适；`app_registry` 如果在另一台主机，是否使用同一张 CA。
3. containerd 2.3.0 生成的配置键位，需要在测试机上实测后固化。
4. worker 编号：inventory 默认从 `k8s-worker11` 起；若 51 台需要连续编号，请直接给出清单。
5. 连通性测试使用的 `busybox_tag`。
