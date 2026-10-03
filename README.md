# Nginx IPv4/IPv6 Reverse Proxy Manager

一个面向 Debian/Ubuntu 双栈 VPS 的 Nginx 反向代理管理脚本，用于将公网 IPv4/IPv6 流量转发到仅有公网 IPv6 的家庭服务器。

适用于家庭 NAS、Minecraft、Web 服务以及其他 TCP/UDP 服务。

## 功能

脚本可自动完成以下操作：

- 安装 Nginx
- 安装 `libnginx-mod-stream`
- 自动配置 Nginx `http` 与 `stream` 模块
- 自动创建独立配置目录
- 支持 HTTP 反向代理
- 支持 TCP 转发
- 支持 UDP 转发
- 支持 TCP + UDP 同端口转发
- 同时监听 VPS 的 IPv4 和 IPv6
- HTTP 自动配置 WebSocket 支持
- 自动执行 `nginx -t`
- 配置失败时自动回滚
- 查看当前代理配置
- 删除已有代理配置
- 修改后端家庭服务器 IPv6 地址
- 提供配套的一键彻底卸载脚本

## 使用场景

典型网络结构：

```text
IPv4 / IPv6 Client
        │
        ▼
   Dual-stack VPS
        │
        │ Nginx
        ▼
Home Server with Public IPv6
```

例如家庭网络只有公网 IPv6，但希望没有 IPv6 网络的客户端也能访问家庭服务器：

```text
IPv4 Client
     │
     ▼
VPS IPv4
     │
     │ IPv6
     ▼
Home Server
```

## 支持的代理类型

### HTTP

例如将 VPS 的 `5666` 转发到家庭服务器的 `5666`：

```text
VPS:5666
   ↓ HTTP
[Home IPv6]:5666
```

适合：

- 飞牛 NAS
- Web 管理界面
- Web API
- WebSocket 服务
- 普通网站

HTTP 代理会自动加入常用反向代理 Header，并支持 WebSocket：

```nginx
proxy_http_version 1.1;

proxy_set_header Host $http_host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;

proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
```

脚本会自动创建：

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
```

### TCP

例如：

```text
VPS:25565/TCP
      ↓
[Home IPv6]:25565/TCP
```

适合：

- Minecraft Java
- SSH
- 数据库
- 自定义 TCP 服务

### UDP

例如：

```text
VPS:8001/UDP
      ↓
[Home IPv6]:8001/UDP
```

适合：

- WireGuard
- 游戏服务器
- 自定义 UDP 服务

UDP 配置不会添加：

```nginx
proxy_responses 0;
```

这是为了保持更好的 QUIC/TUIC 兼容性。

### TCP + UDP

适合需要同时开放 TCP 和 UDP 的服务：

```text
VPS:25565/TCP ─┐
               ├──> [Home IPv6]:25565
VPS:25565/UDP ─┘
```

## 系统要求

推荐：

- Debian 11 / 12 / 13
- Ubuntu 22.04 / 24.04 或更新版本
- VPS 同时拥有公网 IPv4 和 IPv6
- 家庭服务器拥有可从 VPS 访问的公网 IPv6
- root 或 sudo 权限

## 安装与运行

下载或保存脚本后：

```bash
chmod +x nginx-ipv6-proxy.sh
sudo ./nginx-ipv6-proxy.sh
```

首次运行时会自动：

1. 检查并安装 Nginx
2. 安装 Stream 模块
3. 创建配置目录
4. 修改 Nginx 主配置
5. 创建 WebSocket `map`
6. 检查配置并启动 Nginx

然后输入家庭服务器的公网 IPv6 地址。

主菜单：

```text
1) 添加 HTTP 反向代理
2) 添加 TCP 转发
3) 添加 UDP 转发
4) 添加 TCP + UDP 转发

5) 查看当前代理
6) 删除代理
7) 修改家庭服务器 IPv6

0) 退出
```

## 配置文件结构

脚本会使用：

```text
/etc/nginx/
├── nginx.conf
├── http-conf.d/
│   ├── 00-websocket-map.conf
│   ├── http-5666.conf
│   └── ...
└── stream-conf.d/
    ├── tcp-25565.conf
    ├── udp-8001.conf
    ├── tcp-udp-25565.conf
    └── ...
```

### HTTP 配置

例如：

```nginx
server {
    listen 5666;
    listen [::]:5666;

    location / {
        proxy_pass http://[2001:db8::1234]:5666;

        proxy_http_version 1.1;

        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }
}
```

### UDP 配置

例如：

```nginx
server {
    listen 8001 udp;
    listen [::]:8001 udp ipv6only=on;

    proxy_pass [2001:db8::1234]:8001;
}
```

### TCP 配置

例如：

```nginx
server {
    listen 25565;
    listen [::]:25565 ipv6only=on;

    proxy_pass [2001:db8::1234]:25565;
}
```

## 示例

### 飞牛 NAS

选择：

```text
1) 添加 HTTP 反向代理
```

输入：

```text
VPS 对外 TCP 端口: 5666
家庭服务器 HTTP 端口: 5666
```

访问：

```text
http://VPS_IP:5666
```

即可通过 VPS 访问家庭服务器上的飞牛 NAS。

### UDP

选择：

```text
3) 添加 UDP 转发
```

输入：

```text
VPS UDP 监听端口: 8001
家庭服务器 UDP 端口: 8001
```

最终：

```text
Client
   ↓ UDP 8001
VPS
   ↓ IPv6 UDP
Home TUIC Server:8001
```

### Minecraft

如果服务器需要 TCP 和 UDP：

```text
4) 添加 TCP + UDP 转发
```

输入：

```text
VPS 对外监听端口: 25565
家庭服务器端口: 25565
```

## 防火墙

脚本不会自动修改：

- UFW
- iptables
- nftables
- 云厂商安全组

这样可以避免意外影响 SSH 或服务器已有防火墙规则。

请自行确保 VPS 放行对应端口。

例如：

```bash
sudo ufw allow 5666/tcp
sudo ufw allow 8001/udp
sudo ufw allow 25565/tcp
sudo ufw allow 25565/udp
```

如果 VPS 使用云厂商安全组，也需要在控制台中开放对应端口。

## IPv6 防火墙

家庭服务器有公网 IPv6 时，建议只允许 VPS 的 IPv6 地址访问相关端口。

例如：

```text
TCP 5666 ← VPS IPv6 only
UDP 8001 ← VPS IPv6 only
```

这样可以避免客户端绕过 VPS 直接访问家庭服务器。

## 测试

检查 Nginx：

```bash
sudo nginx -t
```

查看运行状态：

```bash
systemctl status nginx
```

查看 TCP 监听：

```bash
sudo ss -lntp
```

查看 UDP 监听：

```bash
sudo ss -lunp
```

查看指定端口：

```bash
sudo ss -lntup | grep -E ':5666|:8001|:25565'
```

测试 VPS 到家庭服务器 IPv6：

```bash
ping -6 HOME_IPV6
```

HTTP：

```bash
curl -v 'http://[HOME_IPV6]:5666/'
```

## 一键卸载

配套卸载脚本：

```bash
chmod +x uninstall-nginx-proxy.sh
sudo ./uninstall-nginx-proxy.sh
```

卸载脚本会：

- 停止 Nginx
- 禁用 Nginx 服务
- Purge Nginx 软件包
- 删除 `libnginx-mod-*`
- 删除 `/etc/nginx`
- 删除日志
- 删除缓存
- 删除运行残留
- 清理不再需要的软件包依赖

注意：

> 卸载脚本会删除服务器上的全部 Nginx 配置，而不仅仅是本工具创建的配置。

如果服务器上的 Nginx 还承载其他网站或服务，请勿直接使用彻底卸载模式。

## 注意事项

家庭服务器的 IPv6 必须能从 VPS 直接访问。

如果：

```bash
ping -6 HOME_IPV6
```

或者：

```bash
curl 'http://[HOME_IPV6]:PORT/'
```

本身就无法连接，那么 Nginx 代理也无法工作。

如果家庭宽带公网 IPv6 会变化，建议配合 DDNS 使用。当前脚本使用固定 IPv6 地址生成配置，因此 IPv6 变化后需要更新对应代理配置。
