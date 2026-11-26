#!/usr/bin/env python3
"""控制机侧变量预检（阶段 00，实施方案 §6.1 步骤 2/3）。

只依赖标准库。输入经环境变量 K8S_VARS 传 JSON，任何一项失败打印清单并以非零退出。
"""
import ipaddress
import json
import os
import re
import sys

V = json.loads(os.environ["K8S_VARS"])
fails = []


def bad(msg):
    fails.append(msg)


def need(key, where="group_vars/all/main.yml"):
    v = V.get(key)
    if v is None or (isinstance(v, str) and v.strip() == "") or (isinstance(v, list) and not v):
        bad(f"缺少必填变量: {key}（{where}）")
        return None
    return v


def cidr(value, what):
    try:
        return ipaddress.ip_network(value, strict=False)
    except (ValueError, TypeError):
        bad(f"{what} 不是合法网段: {value!r}")
        return None


def ip(value, what):
    try:
        return ipaddress.ip_address(value)
    except (ValueError, TypeError):
        bad(f"{what} 不是合法 IP: {value!r}")
        return None


# --- 必填与格式（§6.1 步骤 2） ---
cp = need("cluster_prefix")
if cp is not None and not re.fullmatch(r"[a-z0-9]([a-z0-9-]*[a-z0-9])?", cp):
    bad(f"cluster_prefix 须全小写字母/数字/连字符: {cp!r}")

need("harbor")
need("mirror")
need("apt_k8s_url")
need("node_iface")
need("ext_iface")
need("ntp_servers")
need("metallb_ext_range")
need("gw_ext_ip")

node_cidr = cidr(need("node_cidr"), "node_cidr")
pod_cidr = cidr(need("pod_cidr"), "pod_cidr")
svc_cidr = cidr(need("service_cidr"), "service_cidr")
vip = ip(need("vip"), "vip")
ext_vip = ip(need("ext_vip"), "ext_vip")

# 授权网段：非空列表、每项合法、不得 0.0.0.0/0
allowed = need("ext_api_allowed_cidr")
if allowed is not None:
    for c in allowed:
        n = cidr(c, "ext_api_allowed_cidr 条目")
        if n is not None and n == ipaddress.ip_network("0.0.0.0/0"):
            bad("ext_api_allowed_cidr 不得包含 0.0.0.0/0（手册 1.3）")

# vip_port 不能是 6443（haproxy 与 apiserver 同机）
port = V.get("vip_port")
if not isinstance(port, int) or port <= 0 or port > 65535:
    bad(f"vip_port 取值非法: {port!r}")
elif port == 6443:
    bad("vip_port 不能是 6443：haproxy 与 apiserver 同机时前端端口冲突（手册 3.2）")

# vault：ka_auth_pass ≤ 8 位（未定义说明 vault.yml 未加载）
kap = V.get("ka_auth_pass")
if kap is None:
    bad("ka_auth_pass 未定义：vault.yml 未加载或未填写（须放 group_vars/all/vault.yml 并用 --vault-password-file）")
elif len(str(kap)) > 8:
    bad(f"ka_auth_pass 最长 8 位（VRRP PASS 限制），当前 {len(str(kap))} 位")
for k in ("stats_user", "stats_pass"):
    if not V.get(k):
        bad(f"vault 变量 {k} 未填写")

# 两个 VIP 不同、且分别落在各自网段
if vip is not None and ext_vip is not None and vip == ext_vip:
    bad("vip 与 ext_vip 不得相同")
if vip is not None and node_cidr is not None and vip not in node_cidr:
    bad(f"内网 vip {vip} 不在 node_cidr {node_cidr} 内（手册 1.3）")
ext_prefix = V.get("ext_vip_prefix") or 24
masters = V.get("masters") or []
for m in masters:
    eip = ip(m.get("node_ext_ip"), f"{m.get('name')} node_ext_ip")
    if eip is not None and ext_vip is not None:
        net = ipaddress.ip_network(f"{eip}/{ext_prefix}", strict=False)
        if ext_vip not in net:
            bad(f"外网 ext_vip {ext_vip} 与 {m['name']} 的外网地址 {eip} 不在 /{ext_prefix} 同网段")

# gw_ext_ip 在 metallb_ext_range 内（支持 a-b 区间与 CIDR 两种写法）
gw = ip(V.get("gw_ext_ip"), "gw_ext_ip")
rng = V.get("metallb_ext_range")
if gw is not None and rng:
    ok = False
    if "-" in str(rng):
        try:
            lo, hi = [ipaddress.ip_address(x.strip()) for x in str(rng).split("-", 1)]
            if int(lo) > int(hi):
                bad(f"metallb_ext_range 区间起点大于终点: {rng}")
            ok = lo <= gw <= hi
        except ValueError:
            bad(f"metallb_ext_range 区间格式非法: {rng!r}")
    else:
        n = cidr(rng, "metallb_ext_range")
        ok = n is not None and gw in n
    if not ok:
        bad(f"gw_ext_ip {gw} 不在 metallb_ext_range {rng} 内（手册 1.3）")

# Pod / Service 网段不重叠
if pod_cidr is not None and svc_cidr is not None and pod_cidr.overlaps(svc_cidr):
    bad(f"pod_cidr {pod_cidr} 与 service_cidr {svc_cidr} 重叠")

# --- master keepalived 取值（§6.1 步骤 3 末条） ---
expect = [("MASTER", 100), ("BACKUP", 90), ("BACKUP", 80)]
if len(masters) != 3:
    bad(f"masters 组须恰好 3 台（当前 {len(masters)}）")
for i, m in enumerate(masters):
    if i < 3:
        want = expect[i]
        got = (m.get("ka_state"), m.get("ka_priority"))
        if got[0] != want[0] or int(got[1] or -1) != want[1]:
            bad(f"{m.get('name')} 的 ka_state/ka_priority 应为 {want[0]}/{want[1]}，实际 {got[0]}/{got[1]}")

# --- 节点取值（node_ip 落在 node_cidr；全节点 node_ip/node_name 唯一） ---
nodes = V.get("nodes") or []
names, ips = [], []
for n in nodes:
    nip = ip(n.get("node_ip"), f"{n.get('name')} node_ip")
    if nip is not None and node_cidr is not None and nip not in node_cidr:
        bad(f"{n['name']} 的 node_ip {nip} 不在 node_cidr {node_cidr} 内")
    names.append(n.get("node_name"))
    ips.append(str(nip))
for label, seq in (("node_name", names), ("node_ip", ips)):
    dup = sorted({x for x in seq if x and seq.count(x) > 1})
    if dup:
        bad(f"{label} 重复: {', '.join(dup)}（克隆机最常见，会导致 join 异常）")

# --- 地址冲突：VIP / MetalLB 地址池 不得与节点地址重叠 ---
# worker 的 node_ext_ip 允许缺省（masters 段已强制），只对已填的检查
node_ext = []
for n in nodes:
    raw = n.get("node_ext_ip")
    if raw in (None, ""):
        continue
    eip = ip(raw, f"{n.get('name')} node_ext_ip")
    if eip is not None:
        node_ext.append((n.get("name"), eip))
ext_seq = [str(e) for _, e in node_ext]
dup = sorted({x for x in ext_seq if ext_seq.count(x) > 1})
if dup:
    bad(f"node_ext_ip 重复: {', '.join(dup)}")

for label, v in (("vip", vip), ("ext_vip", ext_vip)):
    if v is None:
        continue
    if str(v) in ips:
        bad(f"{label} {v} 与某节点 node_ip 相同（keepalived 与节点地址冲突）")
    if str(v) in ext_seq:
        bad(f"{label} {v} 与某节点 node_ext_ip 相同（keepalived 与节点地址冲突）")


def parse_range(rng):
    """metallb_ext_range（a-b 或 CIDR）→ (lo, hi)；格式错返回 None（原格式检查已报）"""
    try:
        if "-" in str(rng):
            lo, hi = [ipaddress.ip_address(x.strip()) for x in str(rng).split("-", 1)]
        else:
            n = ipaddress.ip_network(str(rng))
            lo, hi = n.network_address, n.broadcast_address
        return lo, hi
    except ValueError:
        return None


pr = parse_range(rng) if rng else None
if pr and int(pr[0]) <= int(pr[1]):
    lo, hi = pr
    if ext_vip is not None and lo <= ext_vip <= hi:
        bad(f"外网 ext_vip {ext_vip} 落在 metallb_ext_range {rng} 内（keepalived 与 MetalLB 抢同一地址）")
    for name, eip in node_ext:
        if lo <= eip <= hi:
            bad(f"metallb_ext_range {rng} 覆盖 {name} 的外网地址 {eip}（MetalLB 会宣告节点地址）")

if fails:
    print("变量预检未通过：")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("变量预检通过")
