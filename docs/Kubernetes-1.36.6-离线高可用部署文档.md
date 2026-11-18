# Kubernetes 1.36.6 离线高可用集群部署文档

## 1. 概述与架构

### 1.1 组件版本矩阵

| 组件 | 版本 | 说明 |
|---|---:|---|
| 操作系统 | Ubuntu 24.04 LTS | amd64；内核固定 `6.8.0-149-generic`，内核包与元包一并 hold |
| Kubernetes | 1.36.6 | kubeadm、kubelet、kubectl 同一版本；kube-proxy nftables 模式 |
| containerd | 2.3.0 | 官方二进制，装 `/usr/local/bin`；systemd cgroup 驱动 |
| runc | 1.4.2 | 官方二进制（containerd 2.3.0 配套版本），装 `/usr/local/sbin` |
| pause | 3.10.2 | sandbox 镜像，必须提前推到 Harbor |
| nerdctl | 2.3.0 | 调试客户端，拉镜像须 `-n k8s.io` |
| crictl（cri-tools） | 随 k8s 源 | kubeadm 依赖自动安装，手动写 `/etc/crictl.yaml` |
| Calico | 3.32.0 | **官方 Helm Chart 两件套**（CRD Chart + Tigera Operator Chart）；BGP full-mesh + IPIP Always；blockSize /25；启用 apiServer，关闭 goldmane/whisker |
| MetalLB | 0.15.3 | 官方 Helm Chart；L2 模式；仅外网地址池；关闭 FRR |
| Envoy Gateway | 1.7.1 | 官方 OCI Helm Chart（CRDs 随 chart）；仅 HTTP 80 |
| envoy（数据面） | distroless-v1.37.1 | 由 EnvoyProxy 资源指定 |
| Helm | 3.22.1 | 仅 master 安装；OCI 拉取需 ≥3.8 |


### 1.2 架构拓扑

```
 外部客户端(业务)          授权运维网段                    集群节点 / 管理网
      │                        │                              │
 GW_EXT_IP:80          外网 VIP:16443                 内网 VIP:16443 ← controlPlaneEndpoint
 (MetalLB L2 宣告)     (Keepalived 实例二)            (Keepalived 实例一)
      │                        │              ┌───────────────┘
      │                        ▼              ▼
      │              ┌──────────────────────────────┐
      │              │ HAProxy：两个 frontend 分别绑两个 │
      │              │ VIP:16443，后端同为 3 台 master  │
      │              │ 外网入口做源地址 ACL             │
      │              └──┬───────────┬───────────┬────┘
      │             master01     master02     master03  :6443（内网 IP）
      │             kube-apiserver ×3（证书 SAN：两 VIP + 3 台 master 内网 IP）
      │             controller-manager / scheduler ×3
      │             stacked etcd ×3（2379/2380）
      │                  │
      │        ┌─────────┴────────────────────────────┐
      └───────►│ Calico：BGP full-mesh + IPIP         │
               │ Pod CIDR（变量 POD_CIDR）；节点 IP 探测 │
               │ 限定内网网卡                          │
               └──┬───────────────────────────────────┘
                worker11…worker1N（约 48 台）
```

要点（其余细节见各章）：

- **内外两个 API VIP 独立漂移**（不使用 vrrp_sync_group）：外网网络更不稳定，同步组会让外网 VRRP 抖动连累内网 VIP；两个 VIP 允许落在不同 master，正常时都在 master01。
- 集群内部通信（API/etcd/kubelet/Pod 底层/存储）一律走内网网卡；默认路由、业务入口、外部运维 API 走外网网卡。各组件逐项配置见 2.5 索引表。

### 1.3 设计原则

- 换集群只改 `/etc/k8s-deploy.env` 一个文件（2.2），本文不写死任何 IP/域名/密码。
- 有官方 Helm Chart 的组件一律 chart 安装（Calico / MetalLB / Envoy Gateway），manifest 仅作离线兜底。
- 离线分发三渠道：deb → 内网 apt 镜像站；二进制/chart/证书 → `${FILE_URL}`；镜像 → Harbor 公开项目。
- 讨论过程与决策理由记录在仓库 `docs/DECISIONS.md`，本文只写结论与操作步骤。

### 1.4 执行总览

| 阶段 | 范围 | 章节 |
|---|---|---|
| 规划与准备 | 所有节点 | 2（变量文件、网段冲突检查、介质与镜像） |
| 系统初始化 | 所有节点 | 5 |
| 容器运行时 | 所有节点 | 7 |
| 高可用入口 | master | 6（两个 VIP 可用后才能 init） |
| K8s 组件与初始化 | 所有节点 → master01 | 8 |
| Calico | master01 | 9 |
| master/worker 加入 | master02/03、workers | 8.8、8.9 |
| MetalLB / Envoy Gateway | 任一 master | 10、11 |
| 验收 | 任一 master | 12 |

---

## 2. 部署前必须确认的参数

### 2.1 节点规划

- 物理机，双 10G 网卡，分区全给根目录，root 部署。
- 节点名统一 `${CLUSTER_PREFIX}-k8s-master0N` / `${CLUSTER_PREFIX}-k8s-worker1N`（全小写）。
- 当前规划约 51 台（3 master + 48 worker），同一二层网络，BGP full-mesh（N×(N-1)/2 ≈ 1275 对邻居，上线前须实测 TCP 179 与 IPIP 连通性）。

| 节点 | 内网 IP | 外网 IP | 安装软件 |
|---|---|---|---|
| `${CLUSTER_PREFIX}-k8s-master01..03` | 按集群填 | 按集群填 | containerd、keepalived、haproxy、kubeadm 套件、helm |
| `${CLUSTER_PREFIX}-k8s-worker11..1N` | 按集群填 | 按集群填 | containerd、kubeadm 套件 |
| API VIP | 内网 VIP + 外网运维 VIP | — | keepalived 各自独立漂移 |

### 2.2 集群变量文件（多集群复用的核心）

文档不写死任何域名/IP，统一引用 `/etc/k8s-deploy.env`；换集群只改这一个文件。每节点创建（每集群一份）：

```bash
cat > /etc/k8s-deploy.env << 'EOF'
# ===== 本集群专属，部署前逐项确认 =====
export CLUSTER_PREFIX=xxx                    # 集群前缀
export NODE_IFACE=                           # 内网网卡名（集群流量统一走这块）
export NODE_CIDR=                            # 内网网段，如 10.0.0.0/24；NodePort 仅在内网监听
export EXT_IFACE=                            # 外网网卡名（默认路由、对外入口）
# 本节点内网 IP：过滤 keepalived 加上的 secondary（VIP）地址
export NODE_IP=$(ip -4 -o addr show dev ${NODE_IFACE} scope global | grep -v secondary | awk '{print $4}' | cut -d/ -f1 | head -n1)
export HARBOR=                               # 本集群 Harbor 域名
export REGISTRY=${HARBOR}/k8s_dmz            # 系统镜像仓库项目（pause/calico/metallb/envoy/kubeadm 镜像）
export APP_REGISTRY=                         # 业务镜像仓库（worker 预拉取用）
export MIRROR=                               # 内网 apt 镜像站
export FILE_URL=${MIRROR}/repository/tmp-file/k8sv1.36   # 安装文件目录（需自行上传，见 4.1）
export HELM_VERSION=v3.22.1                  # 仅 master 与资源准备机
export VIP=                                  # apiserver 内网 VIP（NODE_CIDR 内、未占用）
export VIP_PREFIX=                           # 内网 VIP 掩码长度，如 24
export EXT_VIP=                              # apiserver 外网运维 VIP
export EXT_VIP_PREFIX=                       # 外网 VIP 掩码长度
export EXT_API_ALLOWED_CIDR=                 # 允许访问外网 API VIP 的网段（不得 0.0.0.0/0）
export VIP_PORT=16443                        # 内外 API VIP 同端口
export MASTER01_IP=                          # 三台 master 内网 IP
export MASTER02_IP=
export MASTER03_IP=
export KA_VRID=51                            # 内网 VRRP ID（内网二层内唯一）
export KA_EXT_VRID=52                        # 外网 VRRP ID（外网二层内唯一）
export KA_AUTH_PASS=                         # keepalived 认证密码（≤8 位）
export STATS_AUTH=admin:ChangeMe             # haproxy 统计页 账号:密码，必须改强密码
export POD_CIDR=10.244.0.0/14
export SERVICE_CIDR=10.96.0.0/12
export IMAGE_LIST=/etc/k8s-preload-images.txt   # worker 预拉镜像清单（8.9 用）
export METALLB_EXT_RANGE=                    # MetalLB 外网地址池（与节点外网 IP、EXT_VIP 避让）
export GW_EXT_IP=                            # 入口 Gateway 固定外网 IP（须在 METALLB_EXT_RANGE 内）
# 仅 master 每台单独设置：master01=MASTER/100，master02=BACKUP/90，master03=BACKUP/80
export KA_STATE=
export KA_PRIORITY=
EOF

chmod 600 /etc/k8s-deploy.env          # 含密码
source /etc/k8s-deploy.env             # 每个新终端都要 source
echo 'source /etc/k8s-deploy.env' >> /root/.bashrc   # 可选：登录自动加载
```

变量规则：
- `NODE_NAME` 不进共享文件，执行前单独 `export NODE_NAME=${CLUSTER_PREFIX}-k8s-master01` 等。
- `KA_STATE`/`KA_PRIORITY` 每台 master 不同；worker 留空。
- `NODE_IP` 每次 source 重算；5 章之后要确认它不是 VIP。
- 后文所有 `${...}` 来自此文件；命令前先 `echo ${REGISTRY}` 等确认非空。

各集群取值登记表（部署前填好）：

| 集群 | CLUSTER_PREFIX | 节点数 | HARBOR | MIRROR/FILE_URL | 内网 VIP:端口 | 外网 VIP:端口 | POD_CIDR | SERVICE_CIDR | EXT_IFACE | 运维允许网段 | METALLB_EXT_RANGE / GW_EXT_IP |
|---|---|---|---|---|---|---|---|---|---|---|---|
| A | | | | | | | | | | | |
| B | | | | | | | | | | | |

### 2.3 网段冲突检查（Calico 安装前执行）

Pod/Service 网段必须与内网、外网、Harbor、镜像站、存储、运维网段互不重叠。`EXTRA_NETS` 填路由表看不到的网段：

```bash
source /etc/k8s-deploy.env
EXTRA_NETS="<Harbor网段> <存储网段> <运维网段>" python3 - <<'PY'
import ipaddress, os, subprocess
def nets(items):
    out = []
    for s in items:
        try: out.append(ipaddress.ip_network(s, strict=False))
        except ValueError: pass
    return out
pod = ipaddress.ip_network(os.environ['POD_CIDR'])
svc = ipaddress.ip_network(os.environ['SERVICE_CIDR'])
routes = subprocess.run(['ip','-4','route','show'],capture_output=True,text=True).stdout.split('\n')
others = nets([l.split()[0] for l in routes if l.split()])
others += nets(os.environ.get('EXTRA_NETS','').split())
others += nets([os.environ.get('NODE_CIDR','')])
bad = 0
if pod.overlaps(svc): print('冲突: POD_CIDR 与 SERVICE_CIDR 重叠'); bad += 1
for name,c in (('POD_CIDR',pod),('SERVICE_CIDR',svc)):
    for o in others:
        if o.prefixlen>0 and c.overlaps(o): print('冲突:',name,c,'与',o); bad += 1
print('无冲突' if bad==0 else '存在冲突，必须调整后再继续')
PY
```

在尚未安装 Calico 的节点执行（装完后路由表会出现 Pod 网段路由，造成误报）。

### 2.4 镜像仓库约定

| 项 | 约定 |
|---|---|
| 系统镜像 | `${REGISTRY}` = `${HARBOR}/k8s_dmz`，项目设为**公开**（否则 kubelet 拉 pause/calico 401） |
| Calico 组件 | `installation.registry: ${REGISTRY}/` + `imagePath: calico` → `${REGISTRY}/calico/node` 等 |
| Tigera Operator | `tigeraOperator.registry: ${REGISTRY}` + `image: tigera/operator` → `${REGISTRY}/tigera/operator` |
| k8s 组件镜像 | `imageRepository: ${REGISTRY}`（kubeadm） |
| 业务镜像 | `${APP_REGISTRY}`（独立仓库/项目），业务侧 `imagePullSecrets`，节点预拉取用 `nerdctl login` |
| Harbor 私有 CA | 证书文件分发到每节点 `/etc/containerd/certs.d/${HARBOR}/ca.crt`（见 4.1、7.2） |

### 2.5 多网卡规划

集群流量走内网网卡；外网网卡承载默认路由、业务入口、外部运维 VIP。组件不指定时会按默认路由（外网）选错：

| 组件 | 指定方式 | 章节 |
|---|---|---|
| 路由 | 默认路由只在外网网卡；内网非直连目的地加静态路由 | 5.1 |
| keepalived/haproxy | 两个独立 VRRP 实例（内 `${NODE_IFACE}`、外 `${EXT_IFACE}`）；HAProxy 分别绑两个 VIP | 6 |
| kubelet | `/etc/default/kubelet` 设 `--node-ip=${NODE_IP}` | 8.1 |
| apiserver/etcd | `advertiseAddress: ${NODE_IP}`；join 加 `--apiserver-advertise-address` | 8.4、8.8 |
| kube-proxy | `nodePortAddresses: [${NODE_CIDR}]` | 8.4 |
| calico | `nodeAddressAutodetectionV4.interface: "^${NODE_IFACE}$"` | 9.3 |
| MetalLB | L2Advertisement `interfaces: [${EXT_IFACE}]` | 10.3 |
| 入口 Gateway | 固定 `GW_EXT_IP` | 11.3 |
| 存储 | 流量走内网，配置沿用现有方案 | 附录 A |

每节点加载变量后先检查：

```bash
source /etc/k8s-deploy.env
echo "${NODE_IFACE} ${NODE_IP} ${NODE_CIDR} ${EXT_IFACE}"    # 四项非空
[ "${NODE_IP}" != "${VIP}" ] && [ "${NODE_IP}" != "${EXT_VIP}" ] || echo "NODE_IP 取到 VIP，请在 env 写死"
stat -c '%a %n' /etc/k8s-deploy.env                          # 应为 600
sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter   # 不能是 1
```

---

## 3. 网络与防火墙要求

主机防火墙与网络侧 ACL 不在本文配置范围，下表部署前交网络/安全侧对照放通：

| 来源 | 目的 | 协议/端口 | 用途 |
|---|---|---|---|
| 集群节点/管理网 | 内网 VIP | TCP 16443 | API（HAProxy 前端） |
| 授权运维网段（仅） | 外网 VIP | TCP 16443 | 外部运维 API；其余来源必须拒绝 |
| HAProxy（master） | 3 台 master 内网 IP | TCP 6443 | HAProxy → apiserver |
| master ↔ master | master 内网 IP | TCP 2379–2380 | stacked etcd |
| control plane | 所有节点 | TCP 10250 | kubelet API |
| 所有节点 ↔（内网） | 所有节点 | TCP 179 | Calico BGP full-mesh |
| 所有节点 ↔（内网） | 所有节点 | IP 协议 4 | Calico IPIP 封装 |
| calico 节点 | calico-typha | TCP 5473 | Typha（大规模时 Operator 部署，待验证） |
| kube-apiserver | calico apiserver | TCP 5443 | Calico 聚合 API（待验证） |
| keepalived 节点（内网二层） | VRRP peer | IP 协议 112（组播 224.0.0.18） | 内网 VIP |
| keepalived 节点（外网二层） | VRRP peer | IP 协议 112 | 外网 VIP；**若二层禁组播改单播**（6.3 变体） |
| 所有节点 ↔（内网） | 所有节点 | TCP/UDP 7946 | MetalLB speaker memberlist |
| 运维机 | master 内网 IP | TCP 8888 | HAProxy 统计页（仅内网） |
| 外网客户端 | `${GW_EXT_IP}` | TCP 80 | Envoy Gateway 业务入口 |
| 外网 → 节点外网 IP | — | TCP/UDP 30000–32767 | **应拒绝**（NodePort 只在内网监听） |
| 节点 | Harbor / 镜像站 | TCP 443/80 | 镜像拉取、文件下载 |
| 节点 | DNS / NTP | 53 / 123 | 解析、时间同步 |
| 运维机 | 所有节点 | TCP 22 | SSH |

说明：
- Calico 3.32 默认 `CLUSTER_TYPE=k8s,bgp`、IPIP Always、VXLAN Never；改数据面模式时本表须同步调整。
- MetalLB L2 依赖外网二层 ARP/免费 ARP 通告，请网络侧确认交换机 ARP 检测、端口安全不拦截。
- kube-proxy nftables 不会自动放通 NodePort，业务入口单独规划。
- HAProxy 外网入口有源地址 ACL，但**不能只依赖它**，网络侧须做相同限制。

---

## 4. 离线介质准备（在可上网的资源准备机执行）

### 4.1 文件清单与上传

统一上传到 `${FILE_URL}`，部署前逐个确认可下载（HTTP 200）。资源准备可用工程仓库 CI（`download-artifacts.yml`）自动完成，`scripts/package-offline.sh` 展开为下表文件名：

| 文件 | 用于章节 | 来源 |
|---|---|---|
| `containerd-2.3.0-linux-amd64.tar.gz`（+官方 sha256sum） | 7.1 | GitHub containerd v2.3.0 release |
| `containerd.service` | 7.1 | containerd v2.3.0 源码仓库 |
| `runc.amd64`、`runc.sha256sum` | 7.3 | GitHub runc v1.4.2 release |
| `nerdctl-2.3.0-linux-amd64.tar.gz`（+SHA256SUMS） | 7.4 | GitHub nerdctl v2.3.0 release |
| `helm-v3.22.1-linux-amd64.tar.gz`（+sha256sum） | 8.7 | get.helm.sh |
| `Release.key` | 8.1 | `pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key`；**上传时记录 sha256 与 GPG 指纹** |
| `harbor-ca.crt` | 7.2 | 本集群 Harbor 私有 CA 证书（新增：内网 CA 分发载体） |
| `tigera-operator-v3.32.0.tgz` | 9 | Calico 官方 Operator Chart |
| `crd.projectcalico.org.v1-v3.32.0.tgz` | 9 | Calico 官方 **CRD Chart（必备，勿漏）** |
| `metallb-0.15.3.tgz` | 10 | MetalLB 官方 Chart |
| `gateway-helm-v1.7.1.tgz` | 11 | `oci://docker.io/envoyproxy/gateway-helm` |

检查命令：

```bash
source /etc/k8s-deploy.env
for f in containerd-2.3.0-linux-amd64.tar.gz containerd-2.3.0-linux-amd64.tar.gz.sha256sum \
         containerd.service runc.amd64 runc.sha256sum \
         nerdctl-2.3.0-linux-amd64.tar.gz nerdctl-2.3.0-SHA256SUMS \
         helm-v3.22.1-linux-amd64.tar.gz helm-v3.22.1-linux-amd64.tar.gz.sha256sum \
         Release.key harbor-ca.crt \
         tigera-operator-v3.32.0.tgz crd.projectcalico.org.v1-v3.32.0.tgz \
         metallb-0.15.3.tgz gateway-helm-v1.7.1.tgz; do
  echo -n "$f  "; curl -s -o /dev/null -w "%{http_code}\n" -I ${FILE_URL}/$f
done
```

### 4.2 镜像清单与推送 Harbor

所有镜像推到 `${REGISTRY}`（公开项目），部署中任何一步禁止依赖公网拉取：

| 类别 | 镜像 | 依据 |
|---|---|---|
| K8s 系统 | `kubeadm config images list --kubernetes-version v1.36.6 --image-repository ${REGISTRY}` 的全部输出（含 pause:3.10.2） | 8.3 |
| Calico | operator（`${REGISTRY}/tigera/operator`）+ `${REGISTRY}/calico/` 下 node、cni、typha、kube-controllers、apiserver、csi、node-driver-registrar 等；**以 `helm template` 渲染与 Operator 实际拉取为准**；goldmane/whisker 已禁用不推 | 9.3 |
| MetalLB | `metallb/controller:v0.15.3`、`metallb/speaker:v0.15.3`（L2 不需要 FRR） | 10 |
| Envoy Gateway | 控制面 `envoyproxy/gateway:v1.7.1`、数据面 `envoyproxy/envoy:distroless-v1.37.1`；ratelimit `c8765e89` 仅启用限流时推；其余以 `helm template` 结果为准 | 11.1 |
| 验收用 | busybox（版本自定） | 12 |

推送方式（资源准备机，需能访问公网源与 Harbor）：

```bash
# 以 pause 为例；其余按上表循环。nerdctl/skopeo 均可
nerdctl pull registry.k8s.io/pause:3.10.2
nerdctl tag registry.k8s.io/pause:3.10.2 ${REGISTRY}/pause:3.10.2
nerdctl push ${REGISTRY}/pause:3.10.2
```

### 4.3 apt 源与系统包

- k8s 源：内网 apt 镜像站镜像 `pkgs.k8s.io/core:/stable:/v1.36/deb/`，公钥 `Release.key`（指纹核对见 8.1）。
- 系统包（haproxy、keepalived、chrony/systemd-timesyncd、nftables、gettext-base 等）：内网 Ubuntu 镜像站，不入工程仓库。

### 4.4 仓库归档名与上传文件名映射

| 工程仓库内 | `${FILE_URL}` 文件名 |
|---|---|
| `binaries/amd64/containerd/2.3.0/containerd-2.3.0-linux-amd64.tar.gz` | 同名 |
| `binaries/amd64/runc/1.4.2/runc.amd64`、`runc.sha256sum` | 同名 |
| `binaries/amd64/nerdctl/2.3.0/nerdctl-2.3.0-linux-amd64.tar.gz` | 同名 |
| `tools/helm/3.22.1/helm-v3.22.1-linux-amd64.tar.gz` | 同名 |
| `templates/systemd/containerd.service.j2` | `containerd.service` |
| `keys/kubernetes/Release.key` | 同名 |
| `charts/calico/3.32.0/tigera-operator-v3.32.0.tgz` | 同名 |
| `charts/calico/3.32.0/crd.projectcalico.org.v1-v3.32.0.tgz` | 同名 |
| `charts/metallb/0.15.3/metallb-0.15.3.tgz` | 同名 |
| `charts/envoy-gateway/1.7.1/gateway-helm-v1.7.1.tgz` | 同名 |

由 `scripts/package-offline.sh` 自动完成展开。`harbor-ca.crt` 为集群专属（内网 Harbor 私有 CA），不在工程仓库归档，由 Harbor 管理员提供后随 `dist/offline-files` 一并上传。

---

## 5. 操作系统基线（所有节点）

### 5.1 主机名、解析、内网路由与唯一性

```bash
source /etc/k8s-deploy.env
export NODE_NAME=${CLUSTER_PREFIX}-k8s-master01    # 按本节点改
hostnamectl set-hostname ${NODE_NAME}
```

无内部 DNS 时，所有节点名与内网 API VIP 写入 `/etc/hosts`（用内网 IP；外网 VIP 不用于节点解析）：

```bash
cat >> /etc/hosts << EOF
${MASTER01_IP} ${CLUSTER_PREFIX}-k8s-master01
${MASTER02_IP} ${CLUSTER_PREFIX}-k8s-master02
${MASTER03_IP} ${CLUSTER_PREFIX}-k8s-master03
# …worker 各行…
EOF
getent hosts ${HARBOR}    # Harbor 域名必须可解析
```

静态路由：默认路由只在外网网卡，内网网卡不配 default。Harbor/镜像站/NFS/运维机不在内网直连网段的，在 netplan 内网网卡定义下加路由（`netplan try` 应用，失败自动回滚）：

```yaml
network:
  version: 2
  vlans:
    vlan1254:            # 即 NODE_IFACE
      routes:
        - to: <目的网段>
          via: <内网网关>
```

验证与唯一性检查（克隆机易重复，重复导致 join 异常）：

```bash
ip route get <Harbor/镜像站 IP>   # dev 应为 ${NODE_IFACE}，src 为本节点内网 IP
ip route | grep default            # 只应有一条，在 ${EXT_IFACE} 上
cat /sys/class/dmi/id/product_uuid
cat /etc/machine-id                # 各节点必须互不相同；重复时：
# rm -f /etc/machine-id /var/lib/dbus/machine-id && systemd-machine-id-setup && reboot
```

### 5.2 内核模块与 sysctl

```bash
cat << EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
ipip
EOF
modprobe overlay && modprobe br_netfilter && modprobe ipip   # ipip：Calico IPIP 封装（tunl0）必需

cat << EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.ipv4.ip_nonlocal_bind = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
EOF
sysctl --system
sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables \
       net.ipv4.ip_forward net.ipv4.ip_nonlocal_bind \
       net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter
# 期望依次为 1 1 1 1 2 2，任何一项不符先解决再继续
```

- `ip_nonlocal_bind=1`：**必配**（内核/Ubuntu 默认 0）。HAProxy 显式绑定两个 VIP，VIP 未漂到本机时也要能启动，否则 bind 报 `EADDRNOTAVAIL`（master 必须，worker 无害）。
- `rp_filter=2`（宽松）：双网卡不对称路由防丢包；严格模式（1）下 Calico IPIP 报文会被直接丢弃（Felix 检测到 strict RPF 也会拒绝工作）。生效值取 `max(all, 各网卡)`，`all=2` 已保证全部网卡宽松（网卡残留 1 不会生效）；`default=2` 让之后创建的 tunl0/veth 等接口同样宽松。注意：Ubuntu 24.04 默认已是 2（`/usr/lib/sysctl.d/10-network-security.conf`），此处显式写入是为了防安全加固基线（如 CIS 会改回 1）与镜像漂移，**不要因为"与默认重复"而删除**。
- `ipip`：Calico IPIP 封装必需；内核 6.8 通常可按需自动加载，显式预加载消除一个失败点（清理时对应 `modprobe -r ipip`，见附录 C）。
- IPv6 未启用，故无 `net.ipv6.conf.all.forwarding` 等项；其余内核调优（fs.inotify、nf_conntrack_max 等）按既定决策保持默认。

### 5.3 nftables 工具（只装命令行，服务禁用并 mask）

kube-proxy nftables 模式自行管理 `ip kube-proxy` 表，不依赖 nftables.service；该服务反而是危险对象（Ubuntu 24.04 实测，`systemctl cat nftables`）：

- `ExecStart`/`ExecReload` = `nft -f /etc/nftables.conf`，而该文件第一行就是 **`flush ruleset`** → start/reload 先清空全部规则（kube-proxy、Calico、主机防火墙一起没）；
- **最隐蔽的是 stop：单元的 `ExecStop=/usr/sbin/nft flush ruleset`，"停个服务"本身就是清空规则**。

因此只装命令行工具，并把服务 **mask**（mask 后 start/stop/reload 全部被 systemd 直接拒绝，把"不要碰"变成硬约束；确需恢复时 `systemctl unmask`）：

```bash
cat << EOF | tee /etc/modules-load.d/nftables.conf
nf_tables
nf_nat
nf_conntrack
EOF
modprobe nf_tables && modprobe nf_nat && modprobe nf_conntrack

apt install -y nftables                 # 只为 nft 命令行（8.6 验证、附录 C 清理用）
systemctl is-enabled nftables           # 应 disabled；若 enabled 只 disable，绝不加 --now（--now 触发 stop=清空规则）
systemctl mask nftables

nft --version                           # Ubuntu 24.04 为 1.0.9；kube-proxy nftables 要求内核 ≥5.13（6.8 满足）
iptables -V                             # 应显示 (nf_tables)：kube-proxy 与 Calico 同走 nft 后端，规则统一可见；若镜像曾被改为 legacy 需先改回
systemctl is-active ufw                 # 记录结果：ufw 走 iptables-nft 与集群共存，但 flush ruleset 同样会清掉它；若节点启用了 ufw，通知网络/安全侧纳入 §3 的防火墙责任
```

自定义规则用独立 table（`nft add table ...`），任何时候禁止 `flush ruleset`（包括排障和清理，见附录 C）。

### 5.4 关闭 swap

```bash
swapoff -a
sed -i 's|^/swap.img|#/swap.img|' /etc/fstab
free -h | grep -i swap               # 应为 0
```

### 5.5 内核固定与锁定、关闭自动更新

```bash
apt-cache policy linux-image-6.8.0-149-generic
apt install -y linux-image-6.8.0-149-generic linux-headers-6.8.0-149-generic linux-modules-extra-6.8.0-149-generic
reboot
uname -r                              # 必须 6.8.0-149-generic，否则先处理启动项

apt-mark hold linux-image-6.8.0-149-generic linux-headers-6.8.0-149-generic \
  linux-modules-6.8.0-149-generic linux-modules-extra-6.8.0-149-generic
# 内核元包一并 hold，否则 apt upgrade 会经元包装入更高版本内核
for p in linux-generic linux-image-generic linux-headers-generic \
         linux-generic-hwe-24.04 linux-image-generic-hwe-24.04 linux-headers-generic-hwe-24.04; do
  dpkg -s "$p" >/dev/null 2>&1 && apt-mark hold "$p"
done
apt-mark showhold
dpkg -l 'linux-image-*' | grep '^ii'  # 确认无更高版本内核已装

sed -i 's/Unattended-Upgrade "1"/Unattended-Upgrade "0"/' /etc/apt/apt.conf.d/20auto-upgrades
systemctl disable --now unattended-upgrades
```

固定内核不再收安全更新，需定期评估升级。

### 5.6 DNS（systemd-resolved）

kubelet 从 `/run/systemd/resolve/resolv.conf` 读上游 DNS，缺失会报错：

```bash
systemctl is-active systemd-resolved
ls -l /run/systemd/resolve/resolv.conf    # 正常则跳过；否则：
# apt install -y systemd-resolved && systemctl enable --now systemd-resolved
```

### 5.7 时间同步

证书、etcd、token 都依赖时钟一致：

```bash
timedatectl status | grep -E 'synchronized|NTP'   # synchronized 应为 yes
# 未同步时按本集群 NTP 服务器配置 systemd-timesyncd 或 chrony
```

### 5.8 journald 容量限制

```bash
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/10-k8s-node.conf <<'EOF'
[Journal]
SystemMaxUse=2G
EOF
systemctl restart systemd-journald && journalctl --disk-usage
```

### 5.9 存储（沿用现有配置）

本文不安装/配置 NFS/autofs，不定义挂载路径与参数，不创建 StorageClass/PVC，不部署 NFS CSI；只要求存储流量按 2.5 走内网。各套存储以对应存储部署文档为准。

---

## 6. 高可用入口：keepalived + HAProxy（仅 master）

3 台 master 均部署。两个 VRRP 实例**独立漂移**；HAProxy 两个 frontend 分别绑两个 VIP:16443，后端同为 3 台 master 内网:6443。

先通过 2.5 的通用检查，再确认本章专属变量——任何一项为空或告警，先改 env 再继续：

```bash
source /etc/k8s-deploy.env
echo "${VIP} ${VIP_PREFIX} ${EXT_VIP} ${EXT_VIP_PREFIX} ${EXT_API_ALLOWED_CIDR} ${VIP_PORT}"
echo "${KA_STATE} ${KA_PRIORITY} ${KA_VRID} ${KA_EXT_VRID}"
echo "${MASTER01_IP} ${MASTER02_IP} ${MASTER03_IP}"
[ "${STATS_AUTH}" != "admin:ChangeMe" ] || echo "STATS_AUTH 是默认值，必须改强密码"
[ "${#KA_AUTH_PASS}" -ge 1 ] && [ "${#KA_AUTH_PASS}" -le 8 ] || echo "KA_AUTH_PASS 为空或超 8 位"
```

### 6.1 安装与 HAProxy 配置

```bash
apt install -y keepalived haproxy
source /etc/k8s-deploy.env

cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    timeout connect 5s
    timeout client 3600s
    timeout server 3600s
    timeout tunnel 3600s

frontend kube-apiserver-internal
    bind ${VIP}:${VIP_PORT}
    default_backend kube-apiserver-backend

frontend kube-apiserver-external-ops
    bind ${EXT_VIP}:${VIP_PORT}
    tcp-request connection reject if !{ src ${EXT_API_ALLOWED_CIDR} }
    default_backend kube-apiserver-backend

backend kube-apiserver-backend
    balance roundrobin
    # /healthz 匿名可访问（system:public-info-viewer），HTTP 层检查比 TCP 更真实；
    # 若日后关闭 --anonymous-auth，请整体换回 "option ssl-hello-chk" 并删除下面三行 httpchk
    option httpchk GET /healthz
    http-check connect ssl verify none
    http-check expect status 200
    default-server inter 2s fall 3 rise 2
    server master01 ${MASTER01_IP}:6443 check
    server master02 ${MASTER02_IP}:6443 check
    server master03 ${MASTER03_IP}:6443 check

listen stats
    mode http
    bind ${NODE_IP}:8888
    stats auth ${STATS_AUTH}
    stats refresh 5s
    stats uri /stats
EOF

haproxy -c -f /etc/haproxy/haproxy.cfg
```

### 6.2 健康检查脚本

端口写死进脚本，运行时不 source env（每 2 秒执行一次，避免重算 NODE_IP 且 env 含密码）：

```bash
source /etc/k8s-deploy.env
cat > /etc/keepalived/check-haproxy.sh <<EOF
#!/bin/bash
pgrep -x haproxy >/dev/null || exit 1
ss -lntH "sport = :${VIP_PORT}" | grep -q . || exit 1
exit 0
EOF
chmod 755 /etc/keepalived/check-haproxy.sh
cat /etc/keepalived/check-haproxy.sh     # 确认端口已是数字，不是空值
```

### 6.3 keepalived 配置（内外 VIP 独立漂移）

master01 = `MASTER/100`，master02 = `BACKUP/90`，master03 = `BACKUP/80`：

```bash
source /etc/k8s-deploy.env
cat > /etc/keepalived/keepalived.conf <<EOF
global_defs {
    router_id $(hostname)
    script_user root
    enable_script_security
}

vrrp_script checkhaproxy {
    script "/etc/keepalived/check-haproxy.sh"
    interval 2
    timeout 3
    weight -30
    fall 2
    rise 1
    init_fail
}

vrrp_instance VI_API_INTERNAL {
    state ${KA_STATE}
    interface ${NODE_IFACE}
    virtual_router_id ${KA_VRID}
    priority ${KA_PRIORITY}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass ${KA_AUTH_PASS}
    }
    virtual_ipaddress {
        ${VIP}/${VIP_PREFIX} dev ${NODE_IFACE}
    }
    track_script {
        checkhaproxy
    }
}

vrrp_instance VI_API_EXTERNAL {
    state ${KA_STATE}
    interface ${EXT_IFACE}
    virtual_router_id ${KA_EXT_VRID}
    priority ${KA_PRIORITY}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass ${KA_AUTH_PASS}
    }
    virtual_ipaddress {
        ${EXT_VIP}/${EXT_VIP_PREFIX} dev ${EXT_IFACE}
    }
    track_script {
        checkhaproxy
    }
}
EOF

chmod 600 /etc/keepalived/keepalived.conf
keepalived -t -f /etc/keepalived/keepalived.conf
systemctl enable --now haproxy keepalived
apt-mark hold keepalived haproxy
```

- 两实例共用检查脚本：HAProxy 死亡时两个 VIP 一起迁移（可能落到不同 master，预期行为）；仅外网层故障时只有外网 VIP 迁移。
- `weight -30` 与 100/90/80 配合（100-30=70 < 90 才会迁移）；调整优先级间距时重新核算。
- 默认抢占开启：master01 恢复后 VIP 抢回，上线前在测试环境验证（附录 B）。
- **单播变体（若内外任一二层禁组播）**：两实例分别添加
  `unicast_src_ip <本机该网卡IP>` 与 `unicast_peer { <另外两台该网卡IP> }`，并要求网络侧放通 IP 协议 112。是否需要以网络确认为准（附录 B.1）。

### 6.4 验证（init 前必须通过）

```bash
source /etc/k8s-deploy.env
ip -4 addr show dev ${NODE_IFACE} | grep ${VIP}      # 持有者可见
ip -4 addr show dev ${EXT_IFACE} | grep ${EXT_VIP}
ss -lntp | grep -E "${VIP_PORT}|8888"                # HAProxy 绑两个 VIP；stats 仅内网 IP

# 漂移演练：在持有节点 systemctl stop haproxy，两个 VIP 应迁移（可落不同 master）；恢复后 start
```

从授权网段测外网 VIP:16443 可连，非授权网段必须拒绝。此时后端 6443 未起、健康检查全失败属正常——先确认 VIP 漂移与监听，再 init。外网网卡异常场景（down 外网卡仅外网 VIP 迁移）在测试环境验证，不要在生产直接 down。

---

## 7. 容器运行时（所有节点）

### 7.1 安装 containerd 2.3.0

```bash
source /etc/k8s-deploy.env
mkdir -p /data/package && cd /data/package
wget ${FILE_URL}/containerd-2.3.0-linux-amd64.tar.gz{,.sha256sum}
sha256sum -c containerd-2.3.0-linux-amd64.tar.gz.sha256sum

tar xf containerd-2.3.0-linux-amd64.tar.gz
install -m 755 bin/* /usr/local/bin/          # 只装 /usr/local/bin，避免与旧拷贝双版本
which -a containerd                            # 只应有 /usr/local/bin/containerd
containerd --version

wget -O /etc/systemd/system/containerd.service ${FILE_URL}/containerd.service
grep ExecStart /etc/systemd/system/containerd.service    # 应为 /usr/local/bin/containerd

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
systemctl daemon-reload && systemctl enable --now containerd
```

### 7.2 config.toml 关键项与 Harbor 访问

```bash
source /etc/k8s-deploy.env
# ① sandbox 镜像 → Harbor（sed 按镜像字符串替换，不依赖键名；
#    2.x 的 version 3 配置里可能位于 pinned_images.sandbox，grep 确认即可）
sed -i -E "s#[a-zA-Z0-9._:/-]+/pause:[0-9.]+#${REGISTRY}/pause:3.10.2#g" /etc/containerd/config.toml
grep pause /etc/containerd/config.toml

# ② systemd cgroup 驱动
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# ③ certs.d 目录
sed -i "s#config_path = ''#config_path = '/etc/containerd/certs.d'#" /etc/containerd/config.toml
grep -n config_path /etc/containerd/config.toml

# ④ Harbor 私有 CA（hosts.toml）
mkdir -p /etc/containerd/certs.d/${HARBOR}
wget -O /etc/containerd/certs.d/${HARBOR}/ca.crt ${FILE_URL}/harbor-ca.crt
cat > /etc/containerd/certs.d/${HARBOR}/hosts.toml << EOF
server = "https://${HARBOR}"

[host."https://${HARBOR}"]
  capabilities = ["pull", "resolve"]
  ca = "/etc/containerd/certs.d/${HARBOR}/ca.crt"
EOF
```

- Harbor 走 HTTP 时把 https 改 http 并去掉 ca 行；临时测试可 `skip_verify = true`（生产禁用）。
- `${APP_REGISTRY}` 的主机域名同样建目录与 hosts.toml。
- 以上键位在 containerd 2.3.0 的实际生成配置中**待逐项验证**，以 `crictl pull` 实测为准（附录 B）。
- 私有项目认证：`${REGISTRY}` 项目设公开；业务仓库私有，用 `imagePullSecrets` / `nerdctl login`。

### 7.3 安装 runc 1.4.2

```bash
source /etc/k8s-deploy.env
cd /data/package
wget ${FILE_URL}/runc.amd64 ${FILE_URL}/runc.sha256sum
grep ' runc.amd64$' runc.sha256sum | sha256sum -c -
apt remove -y runc 2>/dev/null || true         # 若装过 apt 版
install -m 755 runc.amd64 /usr/local/sbin/runc
which -a runc && runc --version                # 1.4.2，首选 /usr/local/sbin
systemctl restart containerd                   # 使 7.1/7.2 配置生效（kubelet 未起，顺序无碍）
```

### 7.4 安装 nerdctl 2.3.0

```bash
cd /data/package
wget ${FILE_URL}/nerdctl-2.3.0-linux-amd64.tar.gz ${FILE_URL}/nerdctl-2.3.0-SHA256SUMS
grep ' nerdctl-2.3.0-linux-amd64.tar.gz$' nerdctl-2.3.0-SHA256SUMS | sha256sum -c -
tar Cxzvvf /usr/local/bin nerdctl-2.3.0-linux-amd64.tar.gz
# 本方案只部署 containerd，不装 docker；拉镜像必须指定 k8s.io 命名空间
nerdctl --namespace k8s.io pull ${REGISTRY}/pause:3.10.2   # 顺带验证 Harbor 访问
```

---

## 8. kubeadm：组件安装、初始化与节点加入

### 8.1 安装 kubelet / kubeadm / kubectl（所有节点）

签名公钥来自内网站，信任链只靠镜像站，安装前必须核对指纹（与 4.1 上传记录、官方发布页一致）：

```bash
source /etc/k8s-deploy.env
mkdir -p /etc/apt/keyrings
curl -fsSL ${FILE_URL}/Release.key -o /tmp/Release.key
sha256sum /tmp/Release.key                     # 与上传记录比对
gpg --show-keys --fingerprint /tmp/Release.key # 与官方一致，不一致立即停止
gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg /tmp/Release.key

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] ${MIRROR}/repository/aliyun-image/kubernetes-new/core/stable/v1.36/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt update
apt install -y kubelet=1.36.6-* kubeadm=1.36.6-* kubectl=1.36.6-*
systemctl enable kubelet
apt-mark hold kubelet kubeadm kubectl

# 双网卡：固定节点 IP（join/init 前执行）
echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}" > /etc/default/kubelet
cat /etc/default/kubelet
```

### 8.2 配置 crictl

cri-tools 随 kubeadm 依赖自动安装（kubeadm 预检也要求 crictl 在 PATH），但 `/etc/crictl.yaml` 不会自动生成：

```bash
command -v crictl || apt install -y cri-tools
apt-mark hold cri-tools
cat > /etc/crictl.yaml << EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF
crictl info | head    # crictl 与 nerdctl -n k8s.io 看到同一命名空间，可互相核对
```

### 8.3 确认初始化镜像

```bash
source /etc/k8s-deploy.env
kubeadm config images list --kubernetes-version v1.36.6 --image-repository ${REGISTRY}
# 每一条都必须已存在于 Harbor；pause 版本应与 7.2 一致
crictl pull ${REGISTRY}/pause:3.10.2    # 验证 7.2 Harbor 访问已生效
```

### 8.4 kubeadm 配置（v1beta4）

kubeadm YAML 不读环境变量：先写模板 `kubeadm-config.yaml.tpl`（内容即下文，本文为唯一权威版本），再 `envsubst` 生成：

```bash
cat > kubeadm-config.yaml.tpl << 'EOF'
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${NODE_IP}          # 内网 IP
nodeRegistration:
  name: ${NODE_NAME}
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.36.6
imageRepository: ${REGISTRY}
controlPlaneEndpoint: "${VIP}:${VIP_PORT}"
apiServer:
  certSANs:
  - ${VIP}
  - ${EXT_VIP}
  - ${MASTER01_IP}                      # 补全：直连 master 排障时避免证书告警
  - ${MASTER02_IP}
  - ${MASTER03_IP}
  # 如有内外 API DNS 名，一并列入
certificateValidityPeriod: 87600h       # 叶子证书 10 年（默认 8760h）
caCertificateValidityPeriod: 175200h    # CA 20 年（默认 87600h）
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SERVICE_CIDR}
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: nftables
nodePortAddresses:
- ${NODE_CIDR}                          # NodePort 只在内网监听
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
maxPods: 110
kubeReserved:    { cpu: "4", memory: 4Gi }
systemReserved:  { cpu: "2", memory: 2Gi }
enforceNodeAllocatable: [pods]
evictionHard:
  memory.available: "5%"
  nodefs.available: "10%"
  nodefs.inodesFree: "5%"
  imagefs.available: "10%"
evictionSoft:
  memory.available: "10%"
  nodefs.available: "15%"
  nodefs.inodesFree: "10%"
  imagefs.available: "15%"
evictionSoftGracePeriod:
  memory.available: 2m
  nodefs.available: 2m
  nodefs.inodesFree: 2m
  imagefs.available: 2m
evictionMaxPodGracePeriod: 30
evictionMinimumReclaim:
  memory.available: 0Mi
  nodefs.available: 500Mi
  imagefs.available: 500Mi
containerLogMaxSize: 50Mi
containerLogMaxFiles: 5
EOF
```

要点：
- 两个证书字段为 kubeadm v1beta4 原生支持（Kubernetes 1.31+；**待验证**：以 init 后 `kubeadm certs check-expiration` 实测为准）。长期有效的 CA 与证书私钥须备份并管控权限。
- `nodePortAddresses` 只约束 NodePort，不影响 LoadBalancer IP（不影响 11 章 GW_EXT_IP）。
- 设置 `evictionHard` 后默认值不一定合并，故 `nodefs.inodesFree` 显式写出；根分区单一文件系统，imagefs 与 nodefs 同盘，不单设 imagefs 的 inodesFree；soft 必须高于对应 hard。
- 生成与检查：

```bash
command -v envsubst || apt install -y gettext-base
source /etc/k8s-deploy.env
export NODE_NAME=${CLUSTER_PREFIX}-k8s-master01
envsubst '${NODE_NAME} ${NODE_IP} ${REGISTRY} ${VIP} ${EXT_VIP} ${VIP_PORT} ${POD_CIDR} ${SERVICE_CIDR} ${NODE_CIDR} ${MASTER01_IP} ${MASTER02_IP} ${MASTER03_IP}' \
  < kubeadm-config.yaml.tpl > kubeadm-config.yaml
grep -E 'advertiseAddress|name:|imageRepository|controlPlaneEndpoint|podSubnet|ValidityPeriod' kubeadm-config.yaml
grep -A1 nodePortAddresses kubeadm-config.yaml    # 无空串才继续
```

### 8.5 执行初始化（master01）

```bash
kubeadm init --config kubeadm-config.yaml --upload-certs | tee kubeadm-init.log
# 记下输出中的 --certificate-key（2 小时有效）

mkdir -p ~/.kube
cp /etc/kubernetes/admin.conf ~/.kube/config
chmod 600 ~/.kube/config
kubectl get nodes
```

### 8.6 验证 kube-proxy 与证书

```bash
kubectl -n kube-system get cm kube-proxy -o yaml | grep "mode:"            # nftables
kubectl -n kube-system get cm kube-proxy -o yaml | grep -A1 nodePortAddresses
nft list table ip kube-proxy | head
kubeadm certs check-expiration        # 叶子约 10 年、CA 约 20 年（待验证项）

kubectl get nodes -o wide             # INTERNAL-IP 应为内网 IP（非 VIP、非外网）
ss -lntp | grep -E ':(6443|2379|2380|10250)'
```

### 8.7 安装 Helm（master）

```bash
source /etc/k8s-deploy.env
cd /data/package
wget ${FILE_URL}/helm-${HELM_VERSION}-linux-amd64.tar.gz{,.sha256sum}
sha256sum -c helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum
tar xf helm-${HELM_VERSION}-linux-amd64.tar.gz
install -m 755 linux-amd64/helm /usr/local/bin/helm
helm version        # ≥3.8；master02/03 加入后同样执行
```

### 8.8 master02 / master03 加入（control-plane）

密钥管理：

```bash
# 均在 master01 执行；token 默认 24h，certificate-key 仅 2h
kubeadm init phase upload-certs --upload-certs     # 重新生成 certificate-key
kubeadm token create --print-join-command          # token + hash
# token/hash/key 均敏感，不写入文档、不入仓库
```

在 master02 / master03 分别执行（确认 8.1 的 `/etc/default/kubelet` 已写好）：

```bash
source /etc/k8s-deploy.env
export NODE_NAME=${CLUSTER_PREFIX}-k8s-master02     # master03 相应改
kubeadm join ${VIP}:${VIP_PORT} \
  --token <token> --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane --certificate-key <key> \
  --apiserver-advertise-address=${NODE_IP} --node-name=${NODE_NAME}

mkdir -p ~/.kube && cp /etc/kubernetes/admin.conf ~/.kube/config && chmod 600 ~/.kube/config
kubeadm certs check-expiration       # 同为约 10 年
```

`--apiserver-advertise-address` 必须加：双网卡下 kubeadm 可能选到外网 IP，etcd peer 会用错地址（排障见附录 C）。

### 8.9 worker 加入

```bash
# master 上（只需 token+hash，无需 certificate-key）
kubeadm token create --print-join-command

# 每台 worker（确认 5/7 章与 8.1 已完成）
source /etc/k8s-deploy.env
export NODE_NAME=${CLUSTER_PREFIX}-k8s-worker11    # 按节点改
kubeadm join ${VIP}:${VIP_PORT} \
  --token <token> --discovery-token-ca-cert-hash sha256:<hash> \
  --node-name=${NODE_NAME}
```

预拉业务镜像（`nerdctl -n k8s.io`，清单 `${IMAGE_LIST}` 每行一个，按集群实际填写；私有仓库先 `nerdctl login`）：

```bash
while read -r img; do [ -z "$img" ] && continue; nerdctl --namespace k8s.io pull "$img"; done < ${IMAGE_LIST}
```

kubelet 配置核验（kubeadm 统一下发，无需逐台手配、无需重启）：

```bash
grep -nE 'maxPods|kubeReserved|systemReserved|enforceNodeAllocatable|evictionHard|evictionSoft|inodesFree|containerLogMax' /var/lib/kubelet/config.yaml
# master 上：kubectl describe node <节点> | grep -A8 -E '^Capacity|^Allocatable'
```

---

## 9. Calico v3.32.0（官方 Helm，两件套 Chart）

不使用 latest；v3.32.0 发行 **CRD Chart + Operator Chart** 两个包，缺一不可。采用 API Server 模式（crd.projectcalico.org.v1 + Operator 启用 apiServer 提供 projectcalico.org/v3 API）；原生 v3 CRD 在 3.32 仍为技术预览，不要同时安装两套 CRD Chart；升 3.33+ 再评估迁移。

### 9.1 准备 Chart

资源准备机（或工程仓库 CI）：

```bash
helm repo add projectcalico https://docs.tigera.io/calico/charts && helm repo update
helm pull projectcalico/crd.projectcalico.org.v1 --version v3.32.0 --destination ./charts
helm pull projectcalico/tigera-operator --version v3.32.0 --destination ./charts
# 上传两个 tgz 到 ${FILE_URL}（见 4.1）
```

### 9.2 安装 CRD Chart

```bash
source /etc/k8s-deploy.env
mkdir -p /data/package/charts && cd /data/package/charts
wget ${FILE_URL}/crd.projectcalico.org.v1-v3.32.0.tgz ${FILE_URL}/tigera-operator-v3.32.0.tgz

helm template calico-crds ./crd.projectcalico.org.v1-v3.32.0.tgz \
  | kubectl apply --server-side -f -
kubectl create namespace tigera-operator --dry-run=client -o yaml | kubectl apply -f -
```

### 9.3 values 与镜像核对（强制）

```bash
source /etc/k8s-deploy.env
cat > calico-values.yaml <<EOF
installation:
  enabled: true
  registry: ${REGISTRY}/            # 带结尾斜杠
  imagePath: calico
  calicoNetwork:
    bgp: Enabled
    nodeAddressAutodetectionV4:
      interface: "^${NODE_IFACE}$"  # 必须匹配所有节点内网网卡、不匹配外网网卡
    ipPools:
      - cidr: ${POD_CIDR}
        encapsulation: IPIP         # Always（同层 CrossSubnet 评估见附录 B）
        natOutgoing: Enabled
        blockSize: 25
        nodeSelector: all()
apiServer:
  enabled: true
goldmane:
  enabled: false
whisker:
  enabled: false
tigeraOperator:
  image: tigera/operator
  version: v1.42.0                  # 待验证：以 helm show values 默认值为准
  registry: ${REGISTRY}            # 不带结尾斜杠
EOF

# 强制步骤：渲染核对全部镜像指向 ${REGISTRY}
helm template calico ./tigera-operator-v3.32.0.tgz -n tigera-operator -f calico-values.yaml | grep -E 'image:' | sort -u
```

- `installation.registry` 带斜杠、`tigeraOperator.registry` 不带（渲染结果不得出现双斜杠）。
- Calico 组件镜像是 Operator 运行后才拉的：清单以渲染结果 + 安装后 `kubectl get pods -n calico-system -o jsonpath=...` 核对，goldmane/whisker 已禁用不推。
- apiServer.enabled 等键位、operator 版本以 `helm show values` 为准（待验证）。

### 9.4 安装 Operator 与验证

```bash
helm upgrade --install calico ./tigera-operator-v3.32.0.tgz -n tigera-operator -f calico-values.yaml
kubectl -n tigera-operator rollout status deployment/tigera-operator --timeout=5m
kubectl get tigerastatus               # apiserver、calico 均 Available=True；无 goldmane/whisker
```

### 9.5 BGP full-mesh（只验证，不手动创建）

Node-to-Node Mesh 是默认值，不部署 RR，不手动创建 BGPConfiguration：

```bash
kubectl get bgpconfigurations.projectcalico.org default -o yaml 2>/dev/null || echo "使用默认（Mesh 开启）"
# 存在时 nodeToNodeMeshEnabled 不得为 false；如需修改用 projectcalico.org/v3 API，不要用 crd.projectcalico.org.v1
kubectl get ippools.projectcalico.org -o yaml    # cidr=${POD_CIDR}、blockSize 25、ipipMode Always、vxlanMode Never、natOutgoing true
```

约 51 节点全互联 ≈ 1275 对邻居：上线前实测所有节点内网 TCP 179 互通与 IPIP（IP 协议 4）可达，并评估扩容对 BGP 控制面的影响（待验证）。

### 9.6 验证

```bash
kubectl get pods -n calico-system -o wide    # 全部 Running；镜像均来自 ${REGISTRY}/calico/
kubectl get nodes -o wide                     # 节点 IP 均为内网 IP
```

---

## 10. MetalLB v0.15.3（官方 Helm，L2 模式）

### 10.1 Chart 与 values（关闭 FRR）

```bash
# 资源准备机：helm repo add metallb https://metallb.github.io/metallb && helm repo update
#   helm pull metallb/metallb --version 0.15.3 → 上传 ${FILE_URL}
cat > metallb-values.yaml << 'EOF'
frrk8s:
  enabled: false
speaker:
  frr:
    enabled: false
EOF
# 待验证：字段以 helm show values ./metallb-0.15.3.tgz 为准
```

### 10.2 安装（speaker 需特权，PSA 放行）

```bash
kubectl create namespace metallb-system --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace metallb-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged --overwrite

helm upgrade --install metallb ./metallb-0.15.3.tgz -n metallb-system -f metallb-values.yaml
helm template metallb ./metallb-0.15.3.tgz -n metallb-system -f metallb-values.yaml | grep -E 'image:' | sort -u   # 核对指向 ${REGISTRY}
kubectl -n metallb-system rollout status deployment/metallb-controller --timeout=5m
kubectl -n metallb-system rollout status daemonset/metallb-speaker --timeout=5m
```

release 名 `metallb` 时资源名为 `metallb-controller`/`metallb-speaker`；release 名不同前缀随之变化。

### 10.3 外网地址池

`autoAssign: false`：只有显式指定 pool-ext 的 Service 才用池内地址，防止误占入口 IP。`${METALLB_EXT_RANGE}` 必须在外网网卡二层段内且未被占用：

```bash
source /etc/k8s-deploy.env
cat > metallb-pool.yaml <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: pool-ext
  namespace: metallb-system
spec:
  addresses:
    - ${METALLB_EXT_RANGE}
  autoAssign: false
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-ext
  namespace: metallb-system
spec:
  ipAddressPools:
    - pool-ext
  interfaces:
    - ${EXT_IFACE}
EOF
kubectl apply -f metallb-pool.yaml     # webhook 未就绪报错则稍后重试
kubectl -n metallb-system get ipaddresspool,l2advertisement
```

nftables 模式无需 strictARP 设置；同一 Service 入口流量只落一台 leader 节点，将来需多节点分摊再加 BGP 池（与 L2 池可共存）。

---

## 11. Envoy Gateway v1.7.1（官方 OCI Helm Chart）

### 11.1 Chart、values 与镜像核对（强制）

values 只覆盖控制面镜像；数据面由 EnvoyProxy 资源指定（11.3）。键名以 `helm show values` 为准：

```bash
source /etc/k8s-deploy.env
cat > envoy-gateway-values.yaml <<EOF
global:
  images:
    envoyGateway:
      image: ${REGISTRY}/envoyproxy/gateway:v1.7.1
EOF

helm template eg ./gateway-helm-v1.7.1.tgz -n envoy-gateway-system -f envoy-gateway-values.yaml | grep -E 'image:' | sort -u
# 渲染出的每一个镜像（控制面、certgen Job、shutdown-manager 等）都必须指向 ${REGISTRY} 且已在 Harbor；
# 数据面 envoy 不会出现在此渲染中，单独确认 distroless-v1.37.1 已推送；仍有公网地址则补 values，否则不得安装
```

### 11.2 安装

```bash
helm upgrade --install eg ./gateway-helm-v1.7.1.tgz \
  --namespace envoy-gateway-system --create-namespace -f envoy-gateway-values.yaml
kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available
```

### 11.3 EnvoyProxy + GatewayClass

```bash
source /etc/k8s-deploy.env
cat > envoy-gatewayclass.yaml <<EOF
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: proxy-ext
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyDeployment:
        replicas: 2
        container:
          image: ${REGISTRY}/envoyproxy/envoy:distroless-v1.37.1
      envoyService:
        type: LoadBalancer
        externalTrafficPolicy: Cluster
        annotations:
          metallb.io/address-pool: pool-ext
          metallb.io/loadBalancerIPs: ${GW_EXT_IP}
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: proxy-ext
    namespace: envoy-gateway-system
EOF
kubectl apply -f envoy-gatewayclass.yaml && kubectl get gatewayclass eg
```

`GW_EXT_IP` 必须属于 `${METALLB_EXT_RANGE}`；保持 `externalTrafficPolicy: Cluster`，不做源 IP 保留。

### 11.4 入口 Gateway（仅 HTTP 80）

```bash
cat > envoy-gateway.yaml << 'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: gw-ext
  namespace: envoy-gateway-system
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All
EOF
kubectl apply -f envoy-gateway.yaml
kubectl get svc -n envoy-gateway-system    # Envoy Service EXTERNAL-IP = ${GW_EXT_IP}
```

---

## 12. 部署后验收清单

在任一 master 逐项检查，全部通过再交付：

| 检查项 | 命令 | 期望 |
|---|---|---|
| 节点状态 | `kubectl get nodes -o wide` | 全部 Ready；INTERNAL-IP 均为内网 IP（非 VIP） |
| 系统 Pod | `kubectl get pods -A -o wide` | 全部 Running/Completed |
| apiserver | `kubectl get --raw='/readyz?verbose' \| tail -n 3` | 以 `readyz check passed` 结尾 |
| 内核与锁定 | `uname -r; apt-mark showhold` | 6.8.0-149-generic；含内核包与元包 |
| kube-proxy | `kubectl -n kube-system get cm kube-proxy -o yaml \| grep 'mode:'` | nftables |
| NodePort 范围 | 同上 `grep -A1 nodePortAddresses` | `${NODE_CIDR}` |
| 证书 | `kubeadm certs check-expiration`（每台 master） | 叶子约 10 年、CA 约 20 年 |
| Calico | `kubectl get tigerastatus; kubectl get ippools.projectcalico.org -o yaml` | 均 Available；IPIP Always、/25、natOutgoing true；镜像来自 `${REGISTRY}/calico/` |
| VIP 高可用 | 停持有者 haproxy | 两个 VIP 均迁移（可落不同 master）；授权/非授权网段访问测试符合预期 |
| kubelet 配置 | `grep ... /var/lib/kubelet/config.yaml` | maxPods 110、预留、驱逐（含 inodesFree）、日志轮转与本文一致 |
| journald | `grep SystemMaxUse /etc/systemd/journald.conf.d/10-k8s-node.conf` | 2G |
| MetalLB/Gateway | `kubectl get svc -n envoy-gateway-system` | EXTERNAL-IP = `${GW_EXT_IP}` |
| etcd | `kubectl -n kube-system exec etcd-<节点> -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key endpoint health --cluster` | 全部 healthy |

连通性测试：

```bash
# 入口（<域名> 为测试 HTTPRoute 主机名）：外网客户端
curl -H 'Host: <域名>' http://${GW_EXT_IP}/
# 外网侧扫节点外网 IP 30000-32767：应全部不通

# DNS 与跨节点（busybox 需先推 ${REGISTRY}）
kubectl run dns-test --rm -it --restart=Never --image=${REGISTRY}/busybox:<tag> -- nslookup kubernetes.default
kubectl run net-a --image=${REGISTRY}/busybox:<tag> --overrides='{"spec":{"nodeName":"<节点A>"}}' -- sleep 3600
kubectl run net-b --image=${REGISTRY}/busybox:<tag> --overrides='{"spec":{"nodeName":"<节点B>"}}' -- sleep 3600
kubectl exec net-a -- ping -c 3 <net-b Pod IP>
kubectl delete pod net-a net-b
```

---

## 13. 附录

### A. 本次不部署的内容与责任边界

- **Lustre 客户端**：1.26.3 时期的包基于 5.15 内核，不适用于 6.8；需要时补匹配 6.8.0-149 的客户端包再恢复。
- **Kyverno**：2026-11-18 取消安装（版本矩阵、介质清单、工程仓库已同步移除；如将来启用再单独评审）。
- **mergerfs**：不采用。
- NFS/autofs 挂载与检查、StorageClass/PVC、NFS CSI、metrics-server、kube-prometheus、Volcano、GPU Operator、HTTPS/TLS、审计日志、etcd 加密、集中日志、根分区监控、fs.inotify 等内核调优：不在本版范围。
- Master 调度：保留默认污点；确需调度时手动移除。

**etcd 备份责任（本文不实施，上线前必须交付）**：

| 事项 | 责任人 | 交付时间 | 状态 |
|---|---|---|---|
| etcd 定期快照（计划任务、保留、异地） | 待填 | 上线前 | 待填 |
| etcd 恢复演练 | 待填 | 上线前 | 待填 |
| `/etc/kubernetes/pki` 备份与权限管控 | 待填 | 上线前 | 待填 |

### B. 待验证事项清单（完成前本文不等同于最终生产手册）

环境参数类：各集群登记表（2.2）、`KA_STATE`/`KA_PRIORITY`/VRID/密码、内外二层是否允许 VRRP 组播（禁则用 6.3 单播变体）、`NODE_IFACE` 正则匹配所有节点、`METALLB_EXT_RANGE` 与 `GW_EXT_IP`、`EXTRA_NETS`、`Release.key` 指纹、`harbor-ca.crt` 分发。

版本与网络实测类：
- kubeadm v1beta4 证书有效期字段在 1.36.6 的实际生效（`certs check-expiration`）。
- containerd 2.3.0 config.toml（version 3）各键位：sandbox_image/pinned_images、SystemdCgroup、config_path、certs.d hosts.toml 与私有 CA。
- Calico：CRD Chart + Operator Chart 在 1.36.6 的安装；apiServer/goldmane/whisker 键位；operator 版本 v1.42.0 与 chart 默认一致性；51 节点 BGP mesh 邻居建立、TCP 179/IPIP 连通与控制面资源；`calicoctl node status` 或等效检查；同层 CrossSubnet 对比评估。
- MetalLB 0.15.3 chart 关 FRR 的字段、镜像核对、L2 免费 ARP 是否被外网交换机拦截。
- Envoy Gateway 1.7.1 chart CRD 安装、values 键名、EnvoyProxy 配置、外网→Pod 全链路。
- HAProxy httpchk 与后端 apiserver 的兼容实测；VIP 漂移三类场景（haproxy 死亡、外网层故障、抢占恢复）。
- 版本组合（containerd 2.3.0/runc 1.4.2/nerdctl 2.3.0/Calico 3.32.0/EG 1.7.1/MetalLB 0.15.3/内核 6.8.0-149）存在性与兼容性逐一对照官方 release。

### C. 常见问题与排障（含 1.26.3 时期经验）

- **CRI 不可用 / v1 runtime API not implemented**：`containerd config default` 重新生成配置，确认 SystemdCgroup=true 后重启 containerd。
- **etcd peer 用了外网 IP**：join 未加 `--apiserver-advertise-address`。预防：8.8 必加；修复：drain → delete node → `etcdctl member remove` → reset 后重新 join。
- **join 连接拒绝**：`systemctl status haproxy keepalived`、`ip addr | grep <VIP>`、`nc -zv ${VIP} 16443`、`curl -k https://${VIP}:${VIP_PORT}/healthz`。
- **CNI 未初始化**：`ls /opt/cni/bin /etc/cni/net.d`，重启 kubelet，删 calico-node pod 重建。
- **Calico 节点 IP 选错**：检查 9.3 的 `nodeAddressAutodetectionV4.interface`。
- **主机名不统一**：所有 join 必须 `--node-name`。
- **Pod Pending（污点）**：业务配容忍或调度到 worker；不建议移除 master 污点。
- **镜像 401（Harbor 私有项目）**：`${REGISTRY}` 设公开；业务仓库用 imagePullSecrets 或 nerdctl login 后预拉。
- **证书尚未生效**：时钟不同步，检查 5.7。

**清理重来（kubeadm reset）**——仅部署失败/下线节点使用：

```bash
kubeadm reset -f
systemctl stop kubelet
rm -rf /etc/cni/net.d /var/lib/cni /var/lib/kubelet /var/lib/etcd /etc/kubernetes ~/.kube
rm -rf /var/lib/calico /var/run/calico
# reset 不清理网络设备与防火墙规则：
nft delete table ip kube-proxy 2>/dev/null; nft delete table ip6 kube-proxy 2>/dev/null
ip link delete vxlan.calico 2>/dev/null
# tunl0（IPIP 内核设备）一般删不掉：确认无占用后 modprobe -r ipip 或重启节点
# 禁止 nft flush ruleset（会清掉节点自身防火墙规则）
# 清理后从 8.1 重新开始；containerd/runc/kubeadm 不用重装；keepalived/haproxy 不受影响
```
