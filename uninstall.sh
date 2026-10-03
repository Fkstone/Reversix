#!/bin/bash

set -u

# ============================================================
# 输出
# ============================================================

red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
blue()   { echo -e "\033[36m$*\033[0m"; }

die() {
    red "错误: $*"
    exit 1
}

# ============================================================
# Root 检查
# ============================================================

if [[ $EUID -ne 0 ]]; then
    die "请使用 root 权限运行，例如：sudo bash $0"
fi

clear

echo "================================================"
echo "          Nginx 完全卸载 / 清理工具"
echo "================================================"
echo
red "警告：该操作将彻底删除 Nginx。"
echo
echo "将删除："
echo
echo "  • nginx"
echo "  • nginx-common / nginx-core 等相关软件包"
echo "  • libnginx-mod-stream"
echo "  • /etc/nginx"
echo "  • /var/log/nginx"
echo "  • /var/cache/nginx"
echo "  • /var/lib/nginx"
echo "  • Nginx systemd 残留"
echo "  • 前面脚本创建的所有 HTTP/TCP/UDP 配置"
echo
yellow "如果服务器上还有其他 Nginx 网站/配置，它们也会被删除。"
echo

read -rp "确认彻底卸载 Nginx？请输入 YES 继续: " confirm

if [[ "$confirm" != "YES" ]]; then
    echo
    yellow "操作已取消。"
    exit 0
fi

echo

# ============================================================
# 停止 Nginx
# ============================================================

blue "[1/8] 停止 Nginx..."

systemctl stop nginx 2>/dev/null || true
systemctl disable nginx 2>/dev/null || true

green "完成。"

# ============================================================
# 查找已安装 Nginx 软件包
# ============================================================

blue "[2/8] 检查已安装的 Nginx 软件包..."

mapfile -t NGINX_PACKAGES < <(
    dpkg-query -W -f='${binary:Package}\n' 2>/dev/null |
    grep -E '^(nginx|nginx-.*|libnginx-mod-.*)(:.*)?$' || true
)

if (( ${#NGINX_PACKAGES[@]} > 0 )); then

    echo
    echo "发现："

    printf '  %s\n' "${NGINX_PACKAGES[@]}"

else

    yellow "没有发现 dpkg 管理的 Nginx 软件包。"

fi

# ============================================================
# Purge
# ============================================================

blue "[3/8] 卸载 Nginx 及相关模块..."

if (( ${#NGINX_PACKAGES[@]} > 0 )); then

    DEBIAN_FRONTEND=noninteractive \
        apt-get purge -y "${NGINX_PACKAGES[@]}" || true

fi

green "软件包卸载完成。"

# ============================================================
# 自动清理依赖
# ============================================================

blue "[4/8] 清理不再需要的依赖..."

DEBIAN_FRONTEND=noninteractive \
    apt-get autoremove --purge -y || true

green "依赖清理完成。"

# ============================================================
# 删除配置
# ============================================================

blue "[5/8] 删除 Nginx 配置..."

rm -rf /etc/nginx

green "/etc/nginx 已删除。"

# ============================================================
# 删除运行及缓存文件
# ============================================================

blue "[6/8] 删除日志、缓存和运行残留..."

rm -rf /var/log/nginx
rm -rf /var/cache/nginx
rm -rf /var/lib/nginx

rm -f /run/nginx.pid
rm -f /var/run/nginx.pid

green "运行残留已清理。"

# ============================================================
# systemd
# ============================================================

blue "[7/8] 清理 systemd 状态..."

systemctl daemon-reload
systemctl reset-failed nginx 2>/dev/null || true

green "systemd 已刷新。"

# ============================================================
# 检查
# ============================================================

blue "[8/8] 检查卸载结果..."

echo

if command -v nginx >/dev/null 2>&1; then

    red "仍然发现 nginx 命令："
    command -v nginx

    echo
    yellow "它可能不是通过 APT 安装的，例如手动编译或第三方安装。"

else

    green "✓ nginx 命令已不存在。"

fi

if [[ ! -e /etc/nginx ]]; then
    green "✓ /etc/nginx 已删除。"
else
    red "✗ /etc/nginx 仍然存在。"
fi

if ! dpkg-query -W 2>/dev/null |
    grep -qE '^(nginx|nginx-|libnginx-mod-)'; then

    green "✓ 未发现已安装的 Nginx Debian 软件包。"

else

    yellow "仍然发现 Nginx 相关软件包："

    dpkg-query -W 2>/dev/null |
        grep -E '^(nginx|nginx-|libnginx-mod-)' || true
fi

echo
echo "================================================"
green "              Nginx 清理完成"
echo "================================================"
echo
echo "此前脚本创建的："
echo
echo "  /etc/nginx/http-conf.d/"
echo "  /etc/nginx/stream-conf.d/"
echo "  WebSocket map"
echo "  HTTP 反向代理"
echo "  TCP 转发"
echo "  UDP 转发"
echo
echo "均随 /etc/nginx 一并删除。"
echo