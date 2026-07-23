#!/bin/bash
# outway-manager.sh - 交互式管理 Outway，支持配置保存与查看
# 用法：sudo ./outway-manager.sh

set -e

# ==================== 颜色定义 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==================== 全局变量 ====================
CONFIG_DIR="/etc/outway"
CONFIG_FILE="$CONFIG_DIR/outway.conf"
OUTWAY_BIN="/usr/local/bin/outway"
SYSTEMD_SERVICE="/etc/systemd/system/outway.service"

# 默认配置（将在安装时设置）
INTERFACE=""
IPV6_ADDR=""
CIDR=""
USERNAME=""
PASSWORD=""
BIND_IP="0.0.0.0"
PORT="1080"
SYSCTL_SET="false"
ROUTE_SET="false"
ROUTE_PERSIST="false"

# ==================== 检测操作系统 ====================
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="$ID"
        case "$ID" in
            ubuntu|debian) PKG_MANAGER="apt" ;;
            centos|rhel|fedora) PKG_MANAGER="yum"; [ "$ID" = "fedora" ] && PKG_MANAGER="dnf" ;;
            *) PKG_MANAGER="apt" ;;
        esac
    else
        PKG_MANAGER="apt"
    fi
    echo -e "${GREEN}检测到操作系统: $OS，包管理器: $PKG_MANAGER${NC}"
}

# ==================== 工具函数 ====================
check_root() {
    [ "$EUID" -eq 0 ] || { echo -e "${RED}请以 root 权限运行${NC}"; exit 1; }
}

confirm_step() {
    local msg="$1"
    read -p "$msg (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]]
}

generate_password() {
    openssl rand -base64 12 2>/dev/null | tr -d '\n' || tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12
}

# ==================== 网卡检测 ====================
detect_interfaces() {
    echo -e "${BLUE}检测可用网卡...${NC}"
    local ifaces=$(ip -6 addr show scope global | grep -E '^[0-9]+:' | awk -F ': ' '{print $2}')
    if [ -z "$ifaces" ]; then
        echo -e "${RED}未找到任何拥有全局 IPv6 地址的网卡。${NC}"
        exit 1
    fi
    echo -e "${GREEN}找到以下网卡：${NC}"
    local i=1
    for iface in $ifaces; do
        local addr=$(ip -6 addr show dev "$iface" scope global | grep inet6 | awk '{print $2}' | head -n1)
        echo "  $i) $iface  (IP: $addr)"
        ((i++))
    done
    read -p "请选择网卡编号 [1-$(($i-1))]: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt $(($i-1)) ]; then
        echo -e "${RED}无效选择${NC}"
        exit 1
    fi
    INTERFACE=$(echo "$ifaces" | sed -n "${choice}p")
    IPV6_ADDR=$(ip -6 addr show dev "$INTERFACE" scope global | grep inet6 | awk '{print $2}' | head -n1)
    echo -e "${GREEN}已选择: $INTERFACE, IPv6: $IPV6_ADDR${NC}"
}

# ==================== 推导 CIDR ====================
derive_cidr() {
    local base="${IPV6_ADDR%/*}"
    local prefix_len="${IPV6_ADDR#*/}"
    echo -e "${BLUE}当前网卡的 IPv6 前缀长度为 /$prefix_len${NC}"
    echo "请选择你希望 outway 使用的 CIDR 块："
    echo "  1) 使用当前网卡的 /$prefix_len (直接使用现有段)"
    echo "  2) 使用 /56 (如果你的上游分配了 /56 子网)"
    echo "  3) 手动输入 CIDR"
    read -p "请选择 [1-3]: " cidr_choice
    case $cidr_choice in
        1) CIDR="$IPV6_ADDR" ;;
        2)
            local segments=(${base//:/ })
            if [ ${#segments[@]} -ge 4 ]; then
                local seg3="${segments[3]}"
                local seg3_prefix="${seg3:0:2}"
                CIDR="${segments[0]}:${segments[1]}:${segments[2]}:${seg3_prefix}00::/56"
            else
                echo -e "${RED}无法自动截取 /56，请手动输入。${NC}"
                read -p "请输入 CIDR: " CIDR
            fi
            ;;
        3) read -p "请输入 CIDR: " CIDR ;;
        *) echo -e "${RED}无效选择${NC}"; exit 1 ;;
    esac
    echo -e "${GREEN}将使用的 CIDR: $CIDR${NC}"
}

# ==================== 设置认证 ====================
set_credentials() {
    read -p "请输入代理用户名 [默认: admin]: " USERNAME
    USERNAME=${USERNAME:-admin}
    local default_pass=$(generate_password)
    read -s -p "请输入代理密码 [默认随机生成: $default_pass]: " PASSWORD
    echo
    if [ -z "$PASSWORD" ]; then
        PASSWORD="$default_pass"
        echo -e "${GREEN}使用随机密码: $PASSWORD${NC}"
    fi
}

# ==================== 配置 sysctl ====================
configure_sysctl() {
    if confirm_step "${YELLOW}是否配置内核参数 net.ipv6.ip_nonlocal_bind=1？${NC}"; then
        local sysctl_file="/etc/sysctl.conf"
        local line="net.ipv6.ip_nonlocal_bind=1"
        if ! grep -q "^$line$" "$sysctl_file"; then
            echo "$line" >> "$sysctl_file"
            sysctl -p
            echo -e "${GREEN}sysctl 已配置。${NC}"
            SYSCTL_SET="true"
        else
            echo -e "${GREEN}sysctl 已存在，跳过。${NC}"
            SYSCTL_SET="true"
        fi
    else
        echo "跳过 sysctl 配置。"
    fi
}

# ==================== 配置路由 ====================
configure_route() {
    if confirm_step "${YELLOW}是否添加本地路由 (ip -6 route add local $CIDR dev lo)？${NC}"; then
        if ip -6 route show | grep -q "$CIDR"; then
            echo -e "${GREEN}路由已存在，跳过添加。${NC}"
        else
            ip -6 route add local "$CIDR" dev lo
            echo -e "${GREEN}路由添加成功。${NC}"
        fi
        ROUTE_SET="true"
        if confirm_step "${YELLOW}是否将路由持久化到 /etc/network/interfaces？${NC}"; then
            if [ -f /etc/network/interfaces ]; then
                if grep -q "post-up ip -6 route add local $CIDR" /etc/network/interfaces; then
                    echo -e "${GREEN}持久化已存在，跳过。${NC}"
                else
                    if grep -q "iface $INTERFACE inet6" /etc/network/interfaces; then
                        sed -i "/iface $INTERFACE inet6/a \    post-up ip -6 route add local $CIDR dev lo || true" /etc/network/interfaces
                        echo -e "${GREEN}持久化写入成功。${NC}"
                        ROUTE_PERSIST="true"
                    else
                        echo -e "${RED}未找到网卡 $INTERFACE 的 IPv6 配置段，无法自动持久化。${NC}"
                        echo "请手动添加：ip -6 route add local $CIDR dev lo"
                    fi
                fi
            else
                echo -e "${RED}/etc/network/interfaces 不存在，请手动持久化。${NC}"
            fi
        else
            echo "跳过持久化。"
        fi
    else
        echo "跳过路由配置。"
    fi
}

# ==================== 安装 outway ====================
install_outway() {
    echo -e "${BLUE}请选择安装方式：${NC}"
    echo "  1) 下载预编译二进制（推荐）"
    echo "  2) 使用 go install 编译安装"
    read -p "请选择 [1-2]: " method
    if [ "$method" != "2" ]; then method="1"; fi

    if [ "$method" = "1" ]; then
        echo -e "${BLUE}从 GitHub 下载预编译二进制...${NC}"
        local arch=$(uname -m)
        case "$arch" in
            x86_64) arch="amd64" ;;
            aarch64) arch="arm64" ;;
            armv7l) arch="arm" ;;
            *) echo -e "${RED}不支持的架构: $arch${NC}"; exit 1 ;;
        esac
        local latest_url="https://api.github.com/repos/xiaozhou26/outway/releases/latest"
        local tag=$(curl -s "$latest_url" | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
        if [ -z "$tag" ]; then
            echo -e "${RED}获取最新版本失败，请检查网络。${NC}"
            exit 1
        fi
        local download_url="https://github.com/xiaozhou26/outway/releases/download/$tag/outway_${tag#v}_linux_$arch.tar.gz"
        local tmp_dir=$(mktemp -d)
        cd "$tmp_dir"
        wget -q --show-progress "$download_url" -O outway.tar.gz
        tar xzf outway.tar.gz
        if [ -f "outway" ]; then
            cp outway "$OUTWAY_BIN"
            chmod +x "$OUTWAY_BIN"
            echo -e "${GREEN}outway 已安装到 $OUTWAY_BIN${NC}"
        else
            echo -e "${RED}解压失败${NC}"; exit 1
        fi
        cd - >/dev/null
        rm -rf "$tmp_dir"
    else
        echo -e "${BLUE}通过 go install 编译安装...${NC}"
        if ! command -v go &> /dev/null; then
            echo "安装 Go 和 Git..."
            case "$PKG_MANAGER" in
                apt) apt update && apt install -y golang-go git ;;
                yum) yum install -y golang git ;;
                dnf) dnf install -y golang git ;;
                *) echo -e "${RED}请手动安装 Go。${NC}"; exit 1 ;;
            esac
        fi
        go install github.com/xiaozhou26/outway@latest
        local found=""
        [ -f "$HOME/go/bin/outway" ] && found="$HOME/go/bin/outway"
        [ -f "/root/go/bin/outway" ] && found="/root/go/bin/outway"
        if [ -z "$found" ]; then
            echo -e "${RED}未找到 outway 二进制${NC}"; exit 1
        fi
        cp "$found" "$OUTWAY_BIN"
        chmod +x "$OUTWAY_BIN"
        echo -e "${GREEN}outway 已安装到 $OUTWAY_BIN${NC}"
    fi
}

# ==================== 创建 systemd 服务 ====================
create_systemd() {
    if confirm_step "${YELLOW}是否创建 systemd 服务并启动 outway？${NC}"; then
        [ -f "$OUTWAY_BIN" ] || { echo -e "${RED}outway 未安装${NC}"; return 1; }
        cat > "$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Outway Proxy Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=$OUTWAY_BIN run auto -i $CIDR -b $BIND_IP:$PORT -u $USERNAME -p $PASSWORD
Restart=always
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable outway
        systemctl start outway
        echo -e "${GREEN}systemd 服务已创建并启动。${NC}"
        systemctl status outway --no-pager
    else
        echo "跳过 systemd 服务创建。"
    fi
}

# ==================== 保存配置 ====================
save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
# Outway 配置文件
INTERFACE="$INTERFACE"
IPV6_ADDR="$IPV6_ADDR"
CIDR="$CIDR"
USERNAME="$USERNAME"
PASSWORD="$PASSWORD"
BIND_IP="$BIND_IP"
PORT="$PORT"
SYSCTL_SET="$SYSCTL_SET"
ROUTE_SET="$ROUTE_SET"
ROUTE_PERSIST="$ROUTE_PERSIST"
EOF
    echo -e "${GREEN}配置已保存到 $CONFIG_FILE${NC}"
}

# ==================== 加载配置 ====================
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo -e "${GREEN}已加载配置文件 $CONFIG_FILE${NC}"
        return 0
    else
        echo -e "${YELLOW}配置文件不存在。${NC}"
        return 1
    fi
}

# ==================== 查看配置 ====================
show_config() {
    if load_config; then
        echo -e "${BLUE}=== 当前配置 ===${NC}"
        echo "网卡: $INTERFACE"
        echo "IPv6 地址: $IPV6_ADDR"
        echo "CIDR: $CIDR"
        echo "用户名: $USERNAME"
        echo "密码: $PASSWORD"
        echo "监听地址: $BIND_IP:$PORT"
        echo "sysctl 已设置: $SYSCTL_SET"
        echo "路由已设置: $ROUTE_SET"
        echo "路由持久化: $ROUTE_PERSIST"
    else
        echo -e "${RED}未找到配置文件，请先安装。${NC}"
    fi
}

# ==================== 卸载（彻底清理） ====================
uninstall_outway() {
    check_root
    echo -e "${RED}=== Outway 卸载（彻底清理） ===${NC}"
    if ! load_config; then
        echo -e "${YELLOW}未找到配置文件，将跳过部分清理（但会尝试删除服务、二进制等）。${NC}"
        # 手动询问 CIDR 用于删除路由
        read -p "请输入之前使用的 CIDR（如不清楚可留空，跳过路由删除）: " CIDR
    fi

    # 删除 systemd 服务
    if confirm_step "${YELLOW}是否停止并删除 systemd 服务？${NC}"; then
        systemctl stop outway 2>/dev/null || true
        systemctl disable outway 2>/dev/null || true
        rm -f "$SYSTEMD_SERVICE"
        systemctl daemon-reload
        echo "systemd 服务已删除。"
    fi

    # 删除二进制
    if confirm_step "${YELLOW}是否删除 outway 二进制 ($OUTWAY_BIN)？${NC}"; then
        rm -f "$OUTWAY_BIN"
        echo "二进制已删除。"
    fi

    # 删除路由持久化
    if confirm_step "${YELLOW}是否删除路由持久化配置 (从 /etc/network/interfaces)？${NC}"; then
        if [ -f /etc/network/interfaces ] && [ -n "$CIDR" ]; then
            sed -i "/post-up ip -6 route add local $CIDR/d" /etc/network/interfaces
            echo "持久化配置已删除。"
        else
            echo "未找到持久化配置或 CIDR 为空，跳过。"
        fi
    fi

    # 删除当前路由
    if confirm_step "${YELLOW}是否删除当前路由 (ip -6 route del local $CIDR)？${NC}"; then
        if [ -n "$CIDR" ]; then
            ip -6 route del local "$CIDR" dev lo 2>/dev/null && echo "路由已删除" || echo "路由不存在或删除失败"
        else
            echo "CIDR 为空，跳过。"
        fi
    fi

    # 删除 sysctl 设置（精确匹配）
    if [ "$SYSCTL_SET" = "true" ] || confirm_step "${YELLOW}是否从 /etc/sysctl.conf 中删除 net.ipv6.ip_nonlocal_bind=1？${NC}"; then
        if [ -f /etc/sysctl.conf ]; then
            # 精确删除匹配行（整行）
            sed -i '/^net\.ipv6\.ip_nonlocal_bind=1$/d' /etc/sysctl.conf
            sysctl -p
            echo "sysctl 配置已删除。"
        fi
    fi

    # 删除配置文件
    if confirm_step "${YELLOW}是否删除配置文件 ($CONFIG_FILE)？${NC}"; then
        rm -f "$CONFIG_FILE"
        rmdir "$CONFIG_DIR" 2>/dev/null || true
        echo "配置文件已删除。"
    fi

    echo -e "${GREEN}✅ 卸载完成！${NC}"
}

# ==================== 主安装流程 ====================
interactive_install() {
    check_root
    detect_os
    echo -e "${BLUE}=== Outway 交互式安装向导 ===${NC}"
    detect_interfaces
    derive_cidr
    set_credentials
    configure_sysctl
    configure_route
    install_outway
    create_systemd
    save_config
    echo -e "${GREEN}✅ 安装流程完成！${NC}"
    echo "代理地址：$BIND_IP:$PORT"
    echo "用户名：$USERNAME，密码：$PASSWORD"
    echo "配置文件：$CONFIG_FILE"
}

# ==================== 主菜单 ====================
main_menu() {
    echo -e "${BLUE}=== Outway 管理工具 ===${NC}"
    echo "1) 安装 Outway (交互式)"
    echo "2) 卸载 Outway (彻底清理)"
    echo "3) 查看当前配置"
    echo "4) 退出"
    read -p "请选择 [1-4]: " choice
    case $choice in
        1) interactive_install ;;
        2) uninstall_outway ;;
        3) show_config ;;
        4) exit 0 ;;
        *) echo "无效选择" ;;
    esac
}

main_menu
