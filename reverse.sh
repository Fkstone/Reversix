#!/bin/bash

set -u

NGINX_CONF="/etc/nginx/nginx.conf"
HTTP_DIR="/etc/nginx/http-conf.d"
STREAM_DIR="/etc/nginx/stream-conf.d"
WS_MAP="$HTTP_DIR/00-websocket-map.conf"

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

pause() {
    echo
    read -rp "按 Enter 继续..."
}

# ============================================================
# 基础检查
# ============================================================

if [[ $EUID -ne 0 ]]; then
    die "请使用 root 权限运行，例如：sudo bash $0"
fi

validate_port() {
    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 ))
}

ask_port() {
    local prompt="$1"
    local port

    while true; do
        read -rp "$prompt" port

        if validate_port "$port"; then
            echo "$port"
            return
        fi

        red "端口必须为 1-65535。" >&2
    done
}

# ============================================================
# 安装 Nginx
# ============================================================

install_nginx() {

    blue "检查 Nginx..."

    if ! command -v nginx >/dev/null 2>&1; then

        blue "正在安装 Nginx..."

        apt update || die "apt update 失败"

        apt install -y nginx libnginx-mod-stream \
            || die "Nginx 安装失败"

    else
        green "Nginx 已安装。"

        if ! find /usr/lib/nginx/modules \
            -name 'ngx_stream_module.so' \
            -print -quit 2>/dev/null | grep -q .; then

            blue "正在安装 Nginx Stream 模块..."

            apt update

            apt install -y libnginx-mod-stream \
                || die "Stream 模块安装失败"
        fi
    fi
}

# ============================================================
# 初始化 Nginx
# ============================================================

init_config() {

    blue "初始化 Nginx 配置..."

    mkdir -p "$HTTP_DIR"
    mkdir -p "$STREAM_DIR"

    # --------------------------------------------------------
    # 动态模块
    # --------------------------------------------------------

    if ! grep -qF \
        'include /etc/nginx/modules-enabled/*.conf;' \
        "$NGINX_CONF"; then

        sed -i \
            '1i include /etc/nginx/modules-enabled/*.conf;' \
            "$NGINX_CONF"
    fi

    # --------------------------------------------------------
    # HTTP include
    # --------------------------------------------------------

    if ! grep -qF \
        'include /etc/nginx/http-conf.d/*.conf;' \
        "$NGINX_CONF"; then

        blue "加入 HTTP 配置目录..."

        sed -i \
            '/^[[:space:]]*http[[:space:]]*{/a\
    include /etc/nginx/http-conf.d/*.conf;' \
            "$NGINX_CONF"
    fi

    # --------------------------------------------------------
    # Stream include
    # --------------------------------------------------------

    if ! grep -qF \
        'include /etc/nginx/stream-conf.d/*.conf;' \
        "$NGINX_CONF"; then

        blue "加入 Stream 配置目录..."

        cat >> "$NGINX_CONF" <<'EOF'

stream {
    include /etc/nginx/stream-conf.d/*.conf;
}
EOF
    fi

    # --------------------------------------------------------
    # WebSocket map
    # --------------------------------------------------------

    if [[ ! -f "$WS_MAP" ]]; then

        blue "创建 WebSocket map..."

        cat > "$WS_MAP" <<'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
    fi

    # --------------------------------------------------------
    # 测试
    # --------------------------------------------------------

    if ! nginx -t; then
        die "Nginx 主配置初始化失败，请检查 $NGINX_CONF"
    fi

    systemctl enable nginx >/dev/null 2>&1
    systemctl restart nginx

    green "Nginx 初始化完成。"
}

# ============================================================
# 配置文件安全写入
# ============================================================

prepare_file() {

    local file="$1"

    if [[ -e "$file" ]]; then

        yellow "配置已经存在："
        echo "  $file"
        echo

        read -rp "是否覆盖？[y/N]: " answer

        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            return 1
        fi

        cp -a "$file" "${file}.backup"
    fi

    return 0
}

rollback_file() {

    local file="$1"

    red "Nginx 配置测试失败，正在回滚..."

    if [[ -f "${file}.backup" ]]; then

        mv -f "${file}.backup" "$file"

    else

        rm -f "$file"

    fi

    nginx -t
}

finish_file() {

    local file="$1"

    if nginx -t; then

        rm -f "${file}.backup"

        systemctl reload nginx

        green "配置已生效。"

        return 0

    else

        rollback_file "$file"

        return 1
    fi
}

# ============================================================
# HTTP
# ============================================================

add_http() {

    echo
    blue "========== HTTP 反向代理 =========="
    echo

    local listen_port
    local backend_port
    local file

    listen_port=$(ask_port "VPS 对外 TCP 端口: ")
    backend_port=$(ask_port "家庭服务器 HTTP 端口: ")

    file="$HTTP_DIR/http-${listen_port}.conf"

    prepare_file "$file" || return

    cat > "$file" <<EOF
server {
    listen ${listen_port};
    listen [::]:${listen_port};

    location / {
        proxy_pass http://[${BACKEND_IPV6}]:${backend_port};

        proxy_http_version 1.1;

        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }
}
EOF

    if finish_file "$file"; then

        echo
        green "HTTP 反向代理："

        echo
        echo "  VPS TCP ${listen_port}"
        echo "       ↓"
        echo "  [${BACKEND_IPV6}]:${backend_port}"
    fi
}

# ============================================================
# TCP
# ============================================================

add_tcp() {

    echo
    blue "========== TCP 转发 =========="
    echo

    local listen_port
    local backend_port
    local file

    listen_port=$(ask_port "VPS TCP 监听端口: ")
    backend_port=$(ask_port "家庭服务器 TCP 端口: ")

    file="$STREAM_DIR/tcp-${listen_port}.conf"

    prepare_file "$file" || return

    cat > "$file" <<EOF
server {
    listen ${listen_port};
    listen [::]:${listen_port} ipv6only=on;

    proxy_pass [${BACKEND_IPV6}]:${backend_port};
}
EOF

    if finish_file "$file"; then

        echo
        green "TCP 转发："
        echo
        echo "  VPS:${listen_port}/TCP"
        echo "       ↓"
        echo "  [${BACKEND_IPV6}]:${backend_port}/TCP"
    fi
}

# ============================================================
# UDP
# ============================================================

add_udp() {

    echo
    blue "========== UDP 转发 =========="
    echo

    local listen_port
    local backend_port
    local file

    listen_port=$(ask_port "VPS UDP 监听端口: ")
    backend_port=$(ask_port "家庭服务器 UDP 端口: ")

    file="$STREAM_DIR/udp-${listen_port}.conf"

    prepare_file "$file" || return

    cat > "$file" <<EOF
server {
    listen ${listen_port} udp;
    listen [::]:${listen_port} udp ipv6only=on;

    proxy_pass [${BACKEND_IPV6}]:${backend_port};
}
EOF

    if finish_file "$file"; then

        echo
        green "UDP 转发："
        echo
        echo "  VPS:${listen_port}/UDP"
        echo "       ↓"
        echo "  [${BACKEND_IPV6}]:${backend_port}/UDP"
    fi
}

# ============================================================
# TCP + UDP
# ============================================================

add_tcp_udp() {

    echo
    blue "========== TCP + UDP 转发 =========="
    echo

    local listen_port
    local backend_port
    local file

    listen_port=$(ask_port "VPS 对外监听端口: ")
    backend_port=$(ask_port "家庭服务器端口: ")

    file="$STREAM_DIR/tcp-udp-${listen_port}.conf"

    prepare_file "$file" || return

    cat > "$file" <<EOF
# TCP
server {
    listen ${listen_port};
    listen [::]:${listen_port} ipv6only=on;

    proxy_pass [${BACKEND_IPV6}]:${backend_port};
}

# UDP
server {
    listen ${listen_port} udp;
    listen [::]:${listen_port} udp ipv6only=on;

    proxy_pass [${BACKEND_IPV6}]:${backend_port};
}
EOF

    if finish_file "$file"; then

        echo
        green "TCP + UDP 转发："
        echo
        echo "  VPS:${listen_port}/TCP ──┐"
        echo "                          ├──> [${BACKEND_IPV6}]:${backend_port}"
        echo "  VPS:${listen_port}/UDP ──┘"
    fi
}

# ============================================================
# 查看配置
# ============================================================

show_config() {

    echo
    blue "========== HTTP =========="
    echo

    if compgen -G "$HTTP_DIR/http-*.conf" >/dev/null; then

        grep -H \
            -E 'listen |proxy_pass ' \
            "$HTTP_DIR"/http-*.conf

    else
        echo "没有脚本创建的 HTTP 反代。"
    fi

    echo
    blue "========== TCP / UDP =========="
    echo

    if compgen -G "$STREAM_DIR/*.conf" >/dev/null; then

        grep -H \
            -E 'listen |proxy_pass ' \
            "$STREAM_DIR"/*.conf

    else
        echo "没有脚本创建的 Stream 转发。"
    fi

    echo
    blue "========== Nginx 当前监听 =========="
    echo

    ss -lntup 2>/dev/null | grep nginx || true
}

# ============================================================
# 删除配置
# ============================================================

delete_config() {

    echo
    blue "========== 删除代理 =========="
    echo

    local files=()

    while IFS= read -r file; do
        files+=("$file")
    done < <(
        find "$HTTP_DIR" "$STREAM_DIR" \
            -maxdepth 1 \
            -type f \
            \( \
                -name 'http-*.conf' \
                -o -name 'tcp-*.conf' \
                -o -name 'udp-*.conf' \
                -o -name 'tcp-udp-*.conf' \
            \) \
            | sort
    )

    if (( ${#files[@]} == 0 )); then

        yellow "没有找到脚本创建的代理配置。"
        return
    fi

    local i

    for i in "${!files[@]}"; do
        printf "%3d) %s\n" "$((i + 1))" "${files[$i]}"
    done

    echo
    echo "  0) 取消"
    echo

    local choice

    read -rp "请选择要删除的配置: " choice

    if [[ "$choice" == "0" ]]; then
        return
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] ||
       (( choice < 1 || choice > ${#files[@]} )); then

        red "无效选择。"
        return
    fi

    local target="${files[$((choice - 1))]}"

    echo
    yellow "即将删除："
    echo "$target"
    echo

    read -rp "确认删除？[y/N]: " answer

    [[ "$answer" =~ ^[Yy]$ ]] || return

    mv "$target" "${target}.delete-backup"

    if nginx -t; then

        rm -f "${target}.delete-backup"

        systemctl reload nginx

        green "代理已删除。"

    else

        red "删除后 Nginx 配置异常，正在恢复。"

        mv "${target}.delete-backup" "$target"

        nginx -t
    fi
}

# ============================================================
# 修改家庭服务器 IPv6
# ============================================================

change_ipv6() {

    echo

    read -rp "新的家庭服务器公网 IPv6: " new_ipv6

    if [[ -z "$new_ipv6" ]]; then
        red "IPv6 地址不能为空。"
        return
    fi

    BACKEND_IPV6="$new_ipv6"

    green "当前家庭服务器 IPv6 已修改为："
    echo "$BACKEND_IPV6"

    yellow "注意：这只影响之后新创建的代理，不修改已有配置。"
}

# ============================================================
# 主程序
# ============================================================

clear

echo "================================================"
echo "       Nginx IPv4 / IPv6 反向代理工具"
echo "================================================"
echo

install_nginx
init_config

echo

while true; do

    read -rp "请输入家庭服务器公网 IPv6 地址: " BACKEND_IPV6

    if [[ -n "$BACKEND_IPV6" ]]; then
        break
    fi

    red "IPv6 地址不能为空。"

done

while true; do

    echo
    echo "================================================"
    echo " 家庭服务器 IPv6:"
    echo " $BACKEND_IPV6"
    echo "================================================"
    echo
    echo "  1) 添加 HTTP 反向代理"
    echo "  2) 添加 TCP 转发"
    echo "  3) 添加 UDP 转发"
    echo "  4) 添加 TCP + UDP 转发"
    echo
    echo "  5) 查看当前代理"
    echo "  6) 删除代理"
    echo "  7) 修改家庭服务器 IPv6"
    echo
    echo "  0) 退出"
    echo

    read -rp "请选择 [0-7]: " choice

    case "$choice" in

        1)
            add_http
            ;;

        2)
            add_tcp
            ;;

        3)
            add_udp
            ;;

        4)
            add_tcp_udp
            ;;

        5)
            show_config
            pause
            ;;

        6)
            delete_config
            pause
            ;;

        7)
            change_ipv6
            ;;

        0)
            echo
            green "完成。"
            exit 0
            ;;

        *)
            red "无效选项。"
            ;;

    esac
done