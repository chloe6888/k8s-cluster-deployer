# kubeadm 配置模板（对应部署文档 8.4；master01 init 用）
# kubeadm YAML 不读环境变量：本模板经 envsubst 生成 kubeadm-config.yaml
#
# 生成命令（先 source /etc/k8s-deploy.env、export NODE_NAME）：
#   envsubst '${NODE_NAME} ${NODE_IP} ${REGISTRY} ${VIP} ${EXT_VIP} ${VIP_PORT} \
#             ${POD_CIDR} ${SERVICE_CIDR} ${NODE_CIDR} \
#             ${MASTER01_IP} ${MASTER02_IP} ${MASTER03_IP}' \
#     < kubeadm-config.yaml.tpl > kubeadm-config.yaml
#   grep -E 'advertiseAddress|name:|imageRepository|controlPlaneEndpoint|podSubnet|ValidityPeriod' kubeadm-config.yaml
#   grep -A1 nodePortAddresses kubeadm-config.yaml     # 无空串才继续
#
# 证书字段为 kubeadm v1beta4 原生支持（Kubernetes 1.31+）：
#   certificateValidityPeriod  87600h  = 10 年（默认 8760h/1 年）
#   caCertificateValidityPeriod 175200h = 20 年（默认 87600h/10 年）
#   以 init 后 kubeadm certs check-expiration 实测为准
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${NODE_IP}          # master01 内网 IP
  bindPort: 6443
nodeRegistration:
  name: ${NODE_NAME}
  kubeletExtraArgs:
    node-ip: ${NODE_IP}                 # 双网卡：与 /etc/default/kubelet 一致，内网 IP
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
    - ${MASTER01_IP}                    # 补全：直连 master 排障时避免证书告警
    - ${MASTER02_IP}
    - ${MASTER03_IP}
    # 如有内外 API DNS 名，一并列入
  timeoutForControlPlane: 4m0s
controllerManager:
  extraArgs:
    bind-address: 0.0.0.0               # 如需只内网监听可改 ${NODE_IP}
scheduler:
  extraArgs:
    bind-address: 0.0.0.0
certificateValidityPeriod: 87600h       # 叶子证书 10 年
caCertificateValidityPeriod: 175200h    # CA 20 年
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SERVICE_CIDR}
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: nftables
nodePortAddresses:
  - ${NODE_CIDR}                        # NodePort 只在内网监听
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd                   # 与 containerd SystemdCgroup=true 一致
maxPods: 110
kubeReserved:
  cpu: "4"
  memory: 4Gi
systemReserved:
  cpu: "2"
  memory: 2Gi
enforceNodeAllocatable:
  - pods
evictionHard:                           # 设置后默认值不一定合并，故全量显式写出
  memory.available: "5%"
  nodefs.available: "10%"
  nodefs.inodesFree: "5%"
  imagefs.available: "10%"
evictionSoft:                           # soft 必须高于对应 hard
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
