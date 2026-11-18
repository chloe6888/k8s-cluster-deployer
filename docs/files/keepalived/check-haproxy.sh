#!/bin/bash
# HAProxy 存活检查脚本（对应部署文档 6.2）
# 部署位置：3 台 master 的 /etc/keepalived/check-haproxy.sh（chmod 755）
#
# 生成方式：source /etc/k8s-deploy.env 后按文档 6.2 的 heredoc 展开，
# 展开后 ${VIP_PORT} 必须已是数字（16443），不是变量名。
# keepalived 每 2 秒执行一次：脚本里不 source env 文件——
# env 含密码，且 NODE_IP 重算开销没有必要；端口直接写死。

pgrep -x haproxy >/dev/null || exit 1
ss -lntH "sport = :16443" | grep -q . || exit 1
exit 0
