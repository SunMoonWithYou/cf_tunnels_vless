# CF Tunnel + Xray VLESS WS 一键脚本

一个简单易用的 Bash 脚本，用于在 Linux 服务器上快速部署 **Cloudflare Tunnel + Xray (VLESS + WebSocket)**。

通过 Cloudflare Tunnel 隐藏真实服务器 IP，无需开放任何端口，适合需要稳定、隐蔽代理环境的用户。

---

## ✨ 功能特点

- ✅ 支持 **安装 / 卸载 / 查看配置**
- ✅ 手动输入 **域名、本地端口、Cloudflare Tunnel Token**
- ✅ 自动随机生成 **UUID** 和 **WebSocket Path**
- ✅ 完善的环境检测，兼容主流 Linux 发行版
- ✅ 自动识别并安装缺失依赖（curl、unzip 等）
- ✅ 使用 systemd 管理服务，支持开机自启
- ✅ 一键生成可直接导入客户端的 VLESS 链接

---

## 🖥️ 支持系统

| 系统 | 包管理器 | 状态 |
|------|----------|------|
| Ubuntu / Debian | apt | ✅ 推荐 |
| CentOS / Rocky / AlmaLinux | yum / dnf | ✅ |
| Fedora | dnf | ✅ |
| Alpine | apk | ✅ |
| Arch / Manjaro | pacman | ✅ |

> 需要支持 **systemd** 的系统。

---

## 📋 使用前准备

1. 一台 Linux 服务器（有 root 权限）
2. 一个已托管在 Cloudflare 的域名
3. 在 Cloudflare Zero Trust 中创建一个 Tunnel，并获取 **Token**

### 获取 Cloudflare Tunnel Token

1. 登录 [Cloudflare Zero Trust](https://one.dash.cloudflare.com/)
2. 进入 **Networks → Tunnels**
3. 点击 **Create a tunnel** → 选择 **Cloudflared**
4. 给隧道命名并创建
5. 复制安装命令中的 **Token**（一长串 `eyJh...`）
6. 在隧道中添加 **Public Hostname**：
   - Subdomain / Domain：你要使用的域名
   - Type：`HTTP`
   - URL：`localhost:你设置的端口`（默认 `10000`）

---

## 🚀 快速开始

### 1. 下载脚本

```bash
wget -O install.sh https://raw.githubusercontent.com/SunMoonWithYou/cf_tunnels_vless/main/install.sh
```

### 2. 赋予执行权限

```bash
chmod +x install.sh
```

### 3. 运行

```bash
sudo ./install.sh
```
