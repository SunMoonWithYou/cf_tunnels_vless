#!/bin/bash
#===============================================================================
#  Cloudflare Tunnel + Xray VLESS WebSocket 一键管理脚本
#  功能：安装 / 卸载 / 查看配置
#  支持：Ubuntu / Debian / CentOS / Rocky / Alma / Fedora / Alpine / Arch
#  说明：手动输入域名、本地端口、Cloudflare Tunnel Token，自动随机生成 Path 和 UUID
#===============================================================================

# 强制把常用路径加入 PATH，避免极简环境找不到基础命令
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# ---------------- 颜色定义 ----------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'   # 恢复默认颜色

# 打印函数
print_info()  { echo -e "${BLUE}[信息]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[成功]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[警告]${NC} $1"; }
print_error() { echo -e "${RED}[错误]${NC} $1"; }

#===============================================================================
#  路径与服务名定义（方便统一修改）
#===============================================================================
XRAY_DIR="/usr/local/xray"                 # Xray 安装目录
CF_DIR="/usr/local/cloudflared"            # cloudflared 安装目录
CONFIG_DIR="/etc/xray-cf"                  # 配置文件目录
SERVICE_DIR="/etc/systemd/system"          # systemd 服务文件目录
XRAY_SERVICE="xray-cf.service"             # Xray 服务名
CF_SERVICE="cloudflared-cf.service"        # cloudflared 服务名

#===============================================================================
#  环境检测相关函数
#===============================================================================

# 检查是否以 root 运行
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "请使用 root 权限运行 (sudo ./cf-xray.sh)"
        exit 1
    fi
}

# 识别操作系统和包管理器
detect_os() {
    OS=""
    PKG_MANAGER=""
    INSTALL_CMD=""
    UPDATE_CMD=""

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|linuxmint|pop)
                OS="debian"
                PKG_MANAGER="apt"
                INSTALL_CMD="apt-get install -y"
                UPDATE_CMD="apt-get update -y"
                ;;
            centos|rhel|rocky|almalinux|ol)
                OS="rhel"
                if command -v dnf >/dev/null 2>&1; then
                    PKG_MANAGER="dnf"
                    INSTALL_CMD="dnf install -y"
                    UPDATE_CMD="dnf makecache"
                else
                    PKG_MANAGER="yum"
                    INSTALL_CMD="yum install -y"
                    UPDATE_CMD="yum makecache"
                fi
                ;;
            fedora)
                OS="fedora"
                PKG_MANAGER="dnf"
                INSTALL_CMD="dnf install -y"
                UPDATE_CMD="dnf makecache"
                ;;
            alpine)
                OS="alpine"
                PKG_MANAGER="apk"
                INSTALL_CMD="apk add --no-cache"
                UPDATE_CMD="apk update"
                ;;
            arch|manjaro|endeavouros)
                OS="arch"
                PKG_MANAGER="pacman"
                INSTALL_CMD="pacman -S --noconfirm"
                UPDATE_CMD="pacman -Sy"
                ;;
            *)
                OS="unknown"
                ;;
        esac
    elif [ -f /etc/redhat-release ]; then
        OS="rhel"
        if command -v dnf >/dev/null 2>&1; then
            PKG_MANAGER="dnf"
            INSTALL_CMD="dnf install -y"
        else
            PKG_MANAGER="yum"
            INSTALL_CMD="yum install -y"
        fi
    elif [ -f /etc/debian_version ]; then
        OS="debian"
        PKG_MANAGER="apt"
        INSTALL_CMD="apt-get install -y"
        UPDATE_CMD="apt-get update -y"
    fi

    print_info "系统识别: ${ID:-unknown} (${OS:-unknown})  包管理器: ${PKG_MANAGER:-无}"
}

# 判断某个命令是否存在
check_command() {
    command -v "$1" >/dev/null 2>&1
}

# 检查并安装缺失依赖
install_deps() {
    print_info "开始检查并安装必要依赖..."

    local MISSING_PKGS=""

    # 检查核心命令
    if ! check_command curl; then
        MISSING_PKGS="$MISSING_PKGS curl"
    fi
    if ! check_command unzip; then
        MISSING_PKGS="$MISSING_PKGS unzip"
    fi
    if ! check_command systemctl; then
        print_error "当前系统没有 systemd (systemctl)，本脚本不支持"
        print_error "请使用支持 systemd 的系统（Ubuntu/Debian/CentOS 等）"
        exit 1
    fi

    # 检查基础工具是否齐全（极简环境可能缺）
    if ! check_command mkdir || ! check_command chmod || ! check_command ln || \
       ! check_command rm || ! check_command cat || ! check_command grep; then
        case $OS in
            debian|rhel|fedora|alpine|arch)
                MISSING_PKGS="$MISSING_PKGS coreutils"
                ;;
        esac
    fi

    # 去重并清理空格
    MISSING_PKGS=$(echo "$MISSING_PKGS" | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs)

    if [ -z "$MISSING_PKGS" ]; then
        print_ok "所有依赖已满足，无需安装"
        return 0
    fi

    print_warn "发现缺失依赖: $MISSING_PKGS"
    echo ""

    # 无法识别包管理器时给出手动安装提示
    if [ -z "$PKG_MANAGER" ] || [ "$OS" = "unknown" ]; then
        print_error "无法自动识别包管理器，请手动安装以下软件后重试："
        echo "  curl unzip"
        echo ""
        echo "常见命令："
        echo "  Ubuntu/Debian : apt update && apt install -y curl unzip"
        echo "  CentOS/RHEL   : yum install -y curl unzip"
        echo "  Alpine        : apk add curl unzip"
        exit 1
    fi

    read -p "是否自动安装缺失依赖？(y/n，推荐 y): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        print_error "已取消，请手动安装依赖后重试"
        exit 1
    fi

    echo ""
    print_info "正在更新软件源（可能需要一点时间）..."
    if [ -n "$UPDATE_CMD" ]; then
        $UPDATE_CMD || print_warn "软件源更新失败，继续尝试安装..."
    fi

    echo ""
    print_info "正在安装: $MISSING_PKGS"
    echo "执行命令: $INSTALL_CMD $MISSING_PKGS"
    echo "----------------------------------------"

    # 显示完整安装过程，方便观察是否卡住
    if $INSTALL_CMD $MISSING_PKGS; then
        echo "----------------------------------------"
        print_ok "依赖安装完成"
    else
        echo "----------------------------------------"
        print_error "依赖安装失败"
        print_error "请手动执行以下命令后重试："
        echo "  $INSTALL_CMD $MISSING_PKGS"
        exit 1
    fi

    # 最终确认关键命令是否可用
    local still_missing=""
    for cmd in curl unzip systemctl; do
        if ! check_command "$cmd"; then
            still_missing="$still_missing $cmd"
        fi
    done

    if [ -n "$still_missing" ]; then
        print_error "以下命令仍然不可用:$still_missing"
        print_error "请检查系统后重试"
        exit 1
    fi

    print_ok "环境检测通过"
    echo ""
}

# 识别 CPU 架构，用于下载对应二进制文件
get_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)            XRAY_ARCH="64";        CF_ARCH="amd64" ;;
        aarch64|arm64)     XRAY_ARCH="arm64-v8a"; CF_ARCH="arm64" ;;
        armv7l|armhf)      XRAY_ARCH="arm32-v7a"; CF_ARCH="arm" ;;
        *) print_error "不支持的架构: $ARCH"; exit 1 ;;
    esac
    print_info "系统架构: $ARCH → Xray:$XRAY_ARCH  cloudflared:$CF_ARCH"
}

#===============================================================================
#  工具函数：生成随机 UUID 和 Path（纯 bash，不依赖外部命令）
#===============================================================================

# 生成标准 UUID（版本 4）
generate_uuid() {
    local bytes="" i
    for i in $(seq 1 16); do
        printf -v bytes "%s%02x" "$bytes" $((RANDOM % 256))
    done
    # 格式：xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
    echo "${bytes:0:8}-${bytes:8:4}-4${bytes:13:3}-${bytes:16:4}-${bytes:20:12}"
}

# 生成随机 WebSocket Path（例如 /a7k9m2x4p1q8）
random_path() {
    local chars="abcdefghijklmnopqrstuvwxyz0123456789"
    local path="/" i
    for i in $(seq 1 12); do
        path="${path}${chars:$((RANDOM % 36)):1}"
    done
    echo "$path"
}

#===============================================================================
#  安装核心功能
#===============================================================================

# 下载并安装 Xray
install_xray() {
    print_info "正在安装 Xray..."
    mkdir -p "$XRAY_DIR"

    # 获取最新版本号，失败则使用备用版本
    XRAY_VERSION=$(curl -sL --connect-timeout 15 \
        https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null \
        | grep -o '"tag_name": "[^"]*"' | head -1 | cut -d'"' -f4)
    [ -z "$XRAY_VERSION" ] && XRAY_VERSION="v25.3.6"

    print_info "下载 Xray ${XRAY_VERSION} ..."
    if ! curl -L --connect-timeout 30 --progress-bar -o /tmp/xray.zip \
        "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"; then
        print_error "Xray 下载失败，请检查网络或 GitHub 访问"
        exit 1
    fi

    unzip -o /tmp/xray.zip -d "$XRAY_DIR" >/dev/null
    chmod +x "$XRAY_DIR/xray"
    ln -sf "$XRAY_DIR/xray" /usr/local/bin/xray
    rm -f /tmp/xray.zip
    print_ok "Xray 安装完成"
}

# 下载并安装 cloudflared
install_cloudflared() {
    print_info "正在安装 cloudflared..."
    mkdir -p "$CF_DIR"

    print_info "下载 cloudflared ..."
    if ! curl -L --connect-timeout 30 --progress-bar -o "$CF_DIR/cloudflared" \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"; then
        print_error "cloudflared 下载失败，请检查网络"
        exit 1
    fi

    chmod +x "$CF_DIR/cloudflared"
    ln -sf "$CF_DIR/cloudflared" /usr/local/bin/cloudflared
    print_ok "cloudflared 安装完成"
}

# 生成 Xray 配置文件（VLESS + WS，无 TLS，由 Cloudflare 处理加密）
create_config() {
    local UUID="$1"
    local PORT="$2"
    local WSPATH="$3"

    mkdir -p "$CONFIG_DIR"

    cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${WSPATH}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
    print_ok "Xray 配置已生成"
}

# 创建并启用 systemd 服务
create_services() {
    local PORT="$1"
    local TOKEN="$2"

    # Xray 服务
    cat > "$SERVICE_DIR/$XRAY_SERVICE" <<EOF
[Unit]
Description=Xray VLESS WS (CF Tunnel)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -c $CONFIG_DIR/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    # cloudflared 服务（使用 Token 方式运行 Named Tunnel）
    cat > "$SERVICE_DIR/$CF_SERVICE" <<EOF
[Unit]
Description=Cloudflare Tunnel for Xray
After=network.target $XRAY_SERVICE
Requires=$XRAY_SERVICE

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token ${TOKEN}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$XRAY_SERVICE" "$CF_SERVICE" >/dev/null 2>&1
    print_ok "systemd 服务已创建并设置开机自启"
}

# 保存安装信息，方便后续查看
save_info() {
    local DOMAIN="$1"
    local UUID="$2"
    local PORT="$3"
    local WSPATH="$4"
    local TOKEN="$5"

    cat > "$CONFIG_DIR/info.txt" <<EOF
DOMAIN=${DOMAIN}
UUID=${UUID}
PORT=${PORT}
PATH=${WSPATH}
TOKEN=${TOKEN}
INSTALL_TIME=$(date '+%Y-%m-%d %H:%M:%S')
EOF
}

# 安装完成后显示结果和链接
show_result() {
    local DOMAIN="$1"
    local UUID="$2"
    local WSPATH="$3"

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}           安装成功！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "协议:          ${CYAN}VLESS${NC}"
    echo -e "传输:          ${CYAN}WebSocket${NC}"
    echo -e "域名:          ${CYAN}${DOMAIN}${NC}"
    echo -e "端口:          ${CYAN}443${NC}"
    echo -e "UUID:          ${CYAN}${UUID}${NC}"
    echo -e "Path:          ${CYAN}${WSPATH}${NC}"
    echo -e "TLS:           ${CYAN}开启（Cloudflare）${NC}"
    echo ""
    echo -e "${YELLOW}VLESS 链接：${NC}"
    echo "vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=${WSPATH}&fp=chrome#CF-VLESS-WS"
    echo ""
    echo -e "${YELLOW}常用命令：${NC}"
    echo "  systemctl status xray-cf cloudflared-cf"
    echo "  journalctl -u xray-cf -f"
    echo "  journalctl -u cloudflared-cf -f"
    echo "  systemctl restart xray-cf cloudflared-cf"
    echo ""
}

#===============================================================================
#  主功能：安装 / 卸载 / 查看信息
#===============================================================================

# 安装流程
do_install() {
    check_root
    detect_os
    install_deps
    get_arch

    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}   开始配置 Cloudflare Tunnel + Xray${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    # 手动输入必要参数
    read -p "请输入域名 (例如: vless.example.com): " DOMAIN
    [ -z "$DOMAIN" ] && { print_error "域名不能为空"; exit 1; }

    read -p "请输入本地监听端口 (默认 10000): " PORT
    PORT=${PORT:-10000}

    read -p "请输入 Cloudflare Tunnel Token: " TOKEN
    [ -z "$TOKEN" ] && { print_error "Token 不能为空"; exit 1; }

    # 自动生成 Path 和 UUID
    WSPATH=$(random_path)
    UUID=$(generate_uuid)

    print_info "随机 Path : $WSPATH"
    print_info "生成 UUID : $UUID"
    echo ""

    # 依次执行安装步骤
    install_xray
    install_cloudflared
    create_config "$UUID" "$PORT" "$WSPATH"
    create_services "$PORT" "$TOKEN"
    save_info "$DOMAIN" "$UUID" "$PORT" "$WSPATH" "$TOKEN"

    # 启动服务
    print_info "正在启动服务..."
    systemctl restart "$XRAY_SERVICE"
    systemctl restart "$CF_SERVICE"
    sleep 4

    if systemctl is-active --quiet "$XRAY_SERVICE" && systemctl is-active --quiet "$CF_SERVICE"; then
        print_ok "服务启动成功"
    else
        print_warn "服务启动异常，请查看日志："
        echo "  journalctl -u xray-cf -n 20 --no-pager"
        echo "  journalctl -u cloudflared-cf -n 20 --no-pager"
    fi

    show_result "$DOMAIN" "$UUID" "$WSPATH"
}

# 卸载流程
do_uninstall() {
    check_root
    print_info "开始卸载..."

    # 停止并禁用服务
    systemctl stop "$XRAY_SERVICE" 2>/dev/null || true
    systemctl stop "$CF_SERVICE" 2>/dev/null || true
    systemctl disable "$XRAY_SERVICE" "$CF_SERVICE" 2>/dev/null || true

    # 删除服务文件
    rm -f "$SERVICE_DIR/$XRAY_SERVICE" "$SERVICE_DIR/$CF_SERVICE"
    systemctl daemon-reload 2>/dev/null || true

    # 删除程序和配置
    rm -rf "$XRAY_DIR" "$CF_DIR" "$CONFIG_DIR"
    rm -f /usr/local/bin/xray /usr/local/bin/cloudflared

    print_ok "卸载完成"
}

# 查看当前配置和链接
do_info() {
    if [ ! -f "$CONFIG_DIR/info.txt" ]; then
        print_error "未找到安装信息，请先安装"
        exit 1
    fi

    # 从 info.txt 读取信息
    DOMAIN=$(grep '^DOMAIN=' "$CONFIG_DIR/info.txt" | cut -d= -f2-)
    UUID=$(grep '^UUID=' "$CONFIG_DIR/info.txt" | cut -d= -f2-)
    PORT=$(grep '^PORT=' "$CONFIG_DIR/info.txt" | cut -d= -f2-)
    WSPATH=$(grep '^PATH=' "$CONFIG_DIR/info.txt" | cut -d= -f2-)
    INSTALL_TIME=$(grep '^INSTALL_TIME=' "$CONFIG_DIR/info.txt" | cut -d= -f2-)

    echo ""
    echo -e "${GREEN}========== 当前配置 ==========${NC}"
    echo -e "域名:     ${CYAN}$DOMAIN${NC}"
    echo -e "UUID:     ${CYAN}$UUID${NC}"
    echo -e "本地端口: ${CYAN}$PORT${NC}"
    echo -e "Path:     ${CYAN}$WSPATH${NC}"
    echo -e "安装时间: ${CYAN}$INSTALL_TIME${NC}"
    echo ""
    echo -e "${YELLOW}VLESS 链接：${NC}"
    echo "vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=${WSPATH}&fp=chrome#CF-VLESS-WS"
    echo ""
}

#===============================================================================
#  菜单与入口
#===============================================================================

show_menu() {
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  CF Tunnel + Xray VLESS WS 管理脚本${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo "  1. 安装"
    echo "  2. 卸载"
    echo "  3. 查看当前配置 / 链接"
    echo "  0. 退出"
    echo ""
    read -p "请选择 [0-3]: " choice
    case $choice in
        1) do_install ;;
        2) do_uninstall ;;
        3) do_info ;;
        0) exit 0 ;;
        *) print_error "无效选项"; sleep 1; show_menu ;;
    esac
}

# 脚本入口：支持直接传参数或进入菜单
case "$1" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    info)      do_info ;;
    *)         show_menu ;;
esac
