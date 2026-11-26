#!/usr/bin/env python3
"""VIP 归属网段检查：内网 VIP 须在 node_cidr 内，外网 VIP 须与本机外网地址同网段。"""
import ipaddress
import json
import os
import sys

V = json.loads(os.environ["K8S_VARS"])
fails = []


def net_of(addr, prefix):
    return ipaddress.ip_network(f"{addr}/{prefix}", strict=False)


try:
    vip = ipaddress.ip_address(V["vip"])
    node_net = ipaddress.ip_network(V["node_cidr"], strict=False)
    if vip not in node_net:
        fails.append(f"内网 vip {vip} 不在 node_cidr {node_net} 内（本节点视角）")
except (ValueError, KeyError) as e:
    fails.append(f"vip/node_cidr 解析失败: {e}")

try:
    ext_vip = ipaddress.ip_address(V["ext_vip"])
    ext_net = net_of(V["node_ext_ip"], V["ext_vip_prefix"])
    if ext_vip not in ext_net:
        fails.append(f"外网 ext_vip {ext_vip} 与本机外网地址 {V['node_ext_ip']}/{V['ext_vip_prefix']} 不同网段")
except (ValueError, KeyError) as e:
    fails.append(f"ext_vip/node_ext_ip 解析失败: {e}")

if fails:
    print("VIP 网段检查未通过：")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("VIP 网段检查通过")
