# 部署方案决策记录

Kubernetes 1.36.6 离线高可用集群 —— 讨论阶段结论汇总。
日期：2026-11-18（持续更新）

| # | 决策项 | 结论 |
|---|---|---|
| 1 | 部署方式 | kubeadm；kubeadm / kubelet / kubectl 同为 1.36.6 |
| 2 | 集群拓扑 | 3 master（stacked etcd）+ N worker（当前约 51 台）；master 保留默认 `node-role.kubernetes.io/control-plane:NoSchedule` 污点，不调度业务 Pod |
| 3 | 操作系统 | Ubuntu 24.04 LTS amd64；**内核固定 6.8.0-149-generic 并连同元包 hold**；所有节点同一基线 |
| 4 | 网络环境 | 纯内网离线；内网 registry 为 Harbor。**镜像项目约定 `REGISTRY=${HARBOR}/k8s_dmz`（系统镜像，公开项目）、`APP_REGISTRY`（业务镜像，私有）**；不做集群级登录；业务私有镜像由业务侧 `imagePullSecrets` / 节点预拉取。**Harbor 私有 CA 证书 `harbor-ca.crt` 纳入介质清单**，每节点放 `/etc/containerd/certs.d/${HARBOR}/ca.crt`（certs.d + hosts.toml，7.2）。离线分发三渠道：deb → 内网 apt 镜像站（pkgs.k8s.io v1.36 镜像 + Ubuntu 源）；二进制/chart/模板/CA 证书 → `package-offline.sh` 产出 → 内网文件镜像站 `${FILE_URL}`；容器镜像 → Harbor |
| 5 | 容器运行时 | containerd 2.3.0 + runc 1.4.2 官方 amd64 二进制（containerd `/usr/local/bin`、runc `/usr/local/sbin`）；systemd cgroup 驱动；pause 3.10.2；nerdctl 2.3.0 调试客户端（拉镜像须 `-n k8s.io`）；crictl（cri-tools）随 k8s deb 安装，`/etc/crictl.yaml` 手动配置 |
| 6 | API 高可用 | keepalived + haproxy 于 3 台 master。**内外两个 VIP 独立漂移（不使用 vrrp_sync_group），同节点两实例优先级一致 100/90/80，`weight -30`**；HAProxy **两个 frontend 分别显式绑 `${VIP}:16443` 与 `${EXT_VIP}:16443`**（依赖 `ip_nonlocal_bind=1`），后端同为 3 台 master 内网:6443，**httpchk GET /healthz**（匿名认证保持默认，关闭时换 `ssl-hello-chk`）；统计页 `${NODE_IP}:8888`；外网 frontend 源地址 ACL（`${EXT_API_ALLOWED_CIDR}`，不得 0.0.0.0/0）+ 网络侧双重限制；检查脚本端口写死、不 source env；`controlPlaneEndpoint = ${VIP}:16443`；VRRP 默认组播，**二层禁组播时用单播变体（6.3，待网络确认）** |
| 7 | API 外网暴露 | 经外网 VIP:16443 暴露，仅授权运维网段 |
| 8 | 证书 SAN | 显式枚举：内网 VIP、外网 VIP、3 台 master 内网 IP；有内外 API DNS 名一并列入（可选） |
| 9 | kube-proxy | nftables 模式；**`nodePortAddresses: [${NODE_CIDR}]`（NodePort 只在内网监听）**；nftables 仅装 CLI，服务保持 disabled/masked，禁止 `flush ruleset` |
| 10 | CNI | Calico 3.32.0，**官方 Helm 两件套：CRD Chart（crd.projectcalico.org.v1）+ Tigera Operator Chart，缺一不可**；参数落 Installation CR：BGP full-mesh（默认，不建 RR/BGPConfiguration）+ IPIP Always、`cidr`=`${POD_CIDR}`、`blockSize: 25`、`natOutgoing: true`、`nodeAddressAutodetectionV4.interface: "^${NODE_IFACE}$"`；`installation.registry=${REGISTRY}/ + imagePath: calico`，`tigeraOperator.registry=${REGISTRY}`（无斜杠）；**apiServer enabled、goldmane/whisker disabled**；operator 版本 v1.42.0（待与 chart 默认核对）；`helm template \| grep image:` 安装前强制核对；calico.yaml manifest 归档兜底 |
| 11 | kubelet | `maxPods: 110`；日志轮转 50Mi×5；`--node-ip` 内网 IP；**kubeReserved 4C/4Gi、systemReserved 2C/2Gi、enforceNodeAllocatable [pods]、evictionHard/Soft（含 nodefs.inodesFree）经 kubeadm KubeletConfiguration 统一下发**；journald SystemMaxUse=2G |
| 12 | MetalLB | 0.15.3 Helm，**L2 模式**；仅外网地址池 `pool-ext`，**`autoAssign: false`**，L2Advertisement `interfaces: [${EXT_IFACE}]`；关闭 FRR（frrk8s/speaker.frr，字段待验证）；metallb-system PSA privileged；nftables 模式无需 strictARP |
| 13 | Ingress | Envoy Gateway 1.7.1 官方 OCI Chart（CRDs 随 chart，不单独 pin）；values 只覆盖控制面镜像，数据面经 EnvoyProxy 资源：envoy `${REGISTRY}/envoyproxy/envoy:distroless-v1.37.1`、replicas 2、LoadBalancer + `metallb.io/address-pool: pool-ext` + `metallb.io/loadBalancerIPs: ${GW_EXT_IP}`、`externalTrafficPolicy: Cluster`；Gateway 仅 HTTP 80、allowedRoutes from: All |
| 14 | 策略 | **Kyverno 取消安装（2026-11-18 决定）**：版本矩阵、介质清单、工程仓库同步移除；将来启用再单独评审。部署工具 Helm 3.22.1（`HELM_VERSION`，仅 master） |
| 15 | 离线介质 | k8s 三件套 deb（内网 apt 源）+ 二进制 tarball + **4 个 chart（calico 两件套/metallb/EG）** + Release.key（sha256+GPG 指纹核对）+ harbor-ca.crt + 镜像清单（4.2）；haproxy/keepalived/chrony 等 Ubuntu 系统包走内网 apt 镜像站，不入 artifacts 仓库 |
| 16 | 工程仓库 | `github.com/chloe6888/k8s-cluster-deployer` 为离线资源工程化载体：`config/versions.yml` 版本单一事实源；artifacts 按类型/组件/版本归档；CI 自动下载校验。安装路径：Calico / MetalLB / Envoy Gateway 用 helm chart；各组件 manifest 归档作离线兜底。**文档章节编号以本目录《Kubernetes-1.36.6-离线高可用部署文档.md》为准**（仓库原引用编号废弃，修改件见 `repo-changes/`） |
| 17 | Envoy Gateway 二级镜像 | 数据面 envoy `distroless-v1.37.1`（EnvoyProxy 资源指定）、ratelimit `c8765e89`（仅启用限流时）；以 `helm template` 渲染结果为准逐一入 Harbor |
| 18 | mergerfs | **不采用**（2026-11-18）：仓库与文档整体移除 |
| 19 | 集群证书 | **kubeadm v1beta4 原生字段（1.31+）：`certificateValidityPeriod: 87600h`（10 年）、`caCertificateValidityPeriod: 175200h`（20 年），无需重签**；以 init 后 `kubeadm certs check-expiration` 实测为准；CA 私钥备份与权限管控交运维（附录 A） |
| 20 | 系统软件包 | haproxy、keepalived、chrony、nftables、gettext-base 等经内网 Ubuntu apt 镜像站安装 |
| 21 | 参数机制 | 集群差异全部收进 `/etc/k8s-deploy.env`（600 权限，含密码）；文档不写死 IP/域名；`NODE_IP` 过滤 secondary（VIP）地址；多集群复用 |
| 22 | 协作方式 | github.com 在工作机不可达（raw/api 可达）：本地 `repo-changes/` 产出修改件，用户同步至 GitHub |
| 23 | 主文档 | **以本地《Kubernetes-1.36.6-离线高可用部署文档.md》为主文档**（2026-11-18 确认）；《v1.36.6 集群部署方案（评审定稿 2026-11-16）》内容全部并入后作废；v1.26.3 手册仅第 12 章排障经验并入附录 C |
| 24 | CI 补充 | workflow `download-artifacts.yml` 增加 Calico CRD Chart 拉取（`helm pull projectcalico/crd.projectcalico.org.v1 --version v3.32.0`）；Kyverno 下载行删除 |

## 尚未填写的占位符（部署前必须确认，见主文档 §2.2 登记表）

节点清单与 IP、`${HARBOR}`/`${MIRROR}`/`${FILE_URL}` 实际地址、内外 VIP、VRID、口令（KA_AUTH_PASS/STATS_AUTH）、`${NODE_IFACE}`/`${EXT_IFACE}`/`${NODE_CIDR}`、`${EXT_API_ALLOWED_CIDR}`、`${METALLB_EXT_RANGE}`/`${GW_EXT_IP}`、`${POD_CIDR}`/`${SERVICE_CIDR}`、内外二层是否允许 VRRP 组播、内网 NTP、`Release.key` 指纹、worker 预拉镜像清单。
