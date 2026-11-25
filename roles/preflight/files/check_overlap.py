#!/usr/bin/env python3
"""网段冲突检查（手册 1.4，阶段 00 步骤 7）。

只依赖标准库 ipaddress。输入经环境变量 K8S_VARS 传 JSON：
pod_cidr / service_cidr / node_cidr / extra_nets，路由表从 `ip -4 route show` 现场读取。
必须在尚未安装 Calico 的节点上执行（有 tunl0 时任务层会跳过，避免 Pod 路由误报）。
"""
import ipaddress
import json
import os
import subprocess
import sys

V = json.loads(os.environ["K8S_VARS"])
fails = []


def nets(items):
    out = []
    for s in items:
        try:
            out.append(ipaddress.ip_network(s, strict=False))
        except (ValueError, TypeError):
            pass
    return out


pod = ipaddress.ip_network(V["pod_cidr"], strict=False)
svc = ipaddress.ip_network(V["service_cidr"], strict=False)
routes = subprocess.run(["ip", "-4", "route", "show"], capture_output=True, text=True).stdout.split("\n")
others = nets([line.split()[0] for line in routes if line.split()])
others += nets(V.get("extra_nets") or [])
others += nets([V.get("node_cidr") or ""])

if pod.overlaps(svc):
    fails.append(f"冲突: pod_cidr {pod} 与 service_cidr {svc} 重叠")
for name, c in (("pod_cidr", pod), ("service_cidr", svc)):
    for o in others:
        if o.prefixlen > 0 and c.overlaps(o):
            fails.append(f"冲突: {name} {c} 与 {o} 重叠")

if fails:
    print("网段冲突检查未通过：")
    for f in fails:
        print(f"  - {f}")
    print("必须调整网段后再继续")
    sys.exit(1)
print("无冲突")
