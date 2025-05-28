#!/bin/bash
# GOST 增强版管理脚本 v2.1.0 - 带真实流量限制（修复版）
# 一键安装: bash <(curl -sSL https://raw.githubusercontent.com/xmg0828-01/gost/main/gost.sh)

Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Yellow_font_prefix="\033[33m"
Blue_font_prefix="\033[34m" && Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Warning="${Yellow_font_prefix}[警告]${Font_color_suffix}"
shell_version="2.1.0"
ct_new_ver="2.11.5"

gost_conf_path="/etc/gost/config.json"
raw_conf_path="/etc/gost/rawconf"
remarks_path="/etc/gost/remarks.txt"
expires_path="/etc/gost/expires.txt"
limits_path="/etc/gost/limits.txt"

check_root() {
    [[ $EUID != 0 ]] && echo -e "${Error} 请使用root权限运行" && exit 1
}

detect_environment() {
    if [[ -f /etc/redhat-release ]]; then
        release="centos"
    else
        release="debian"
    fi
    
    case $(uname -m) in
        x86_64) arch="amd64" ;;
        *) arch="amd64" ;;
    esac
}

is_oneclick_install() {
    [[ "$0" =~ /dev/fd/ ]] || [[ "$0" == "bash" ]]
}

setup_traffic_control() {
    echo -e "${Info} 设置流量控制..."
    
    if [[ $release == "centos" ]]; then
        yum install -y iptables bc >/dev/null 2>&1
    else
        apt-get install -y iptables bc >/dev/null 2>&1
    fi
    
    iptables -t filter -N GOST_TRAFFIC 2>/dev/null
    iptables -t filter -F GOST_TRAFFIC 2>/dev/null
    iptables -t filter -C FORWARD -j GOST_TRAFFIC 2>/dev/null || iptables -t filter -I FORWARD -j GOST_TRAFFIC

    cat > /usr/local/bin/gost-monitor.sh << 'EOF'
#!/bin/bash
LIMITS_FILE="/etc/gost/limits.txt"
check_traffic() {
    while IFS=: read -r port limit_gb; do
        if [[ "$limit_gb" != "无限制" && "$limit_gb" =~ ^[0-9]+$ ]]; then
            tcp_bytes=$(iptables -L GOST_TRAFFIC -n -v -x | grep "tcp dpt:$port" | awk '{sum+=$2} END {print sum+0}')
            udp_bytes=$(iptables -L GOST_TRAFFIC -n -v -x | grep "udp dpt:$port" | awk '{sum+=$2} END {print sum+0}')
            total_bytes=$((tcp_bytes + udp_bytes))
            used_gb=$(echo "$total_bytes / 1073741824" | bc)
            if [ "$used_gb" -ge "$limit_gb" ]; then
                iptables -C INPUT -p tcp --dport "$port" -j DROP 2>/dev/null || iptables -I INPUT -p tcp --dport "$port" -j DROP
                iptables -C INPUT -p udp --dport "$port" -j DROP 2>/dev/null || iptables -I INPUT -p udp --dport "$port" -j DROP
            fi
        fi
    done < "$LIMITS_FILE"
}
[ "$1" = "check" ] && check_traffic
EOF

    chmod +x /usr/local/bin/gost-monitor.sh
    echo "*/5 * * * * root /usr/local/bin/gost-monitor.sh check" > /etc/cron.d/gost-traffic
    systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null
}

create_shortcut() {
    echo -e "${Info} 创建快捷命令..."
    cp "$0" /usr/local/bin/gost-manager.sh
    chmod +x /usr/local/bin/gost-manager.sh
    ln -sf /usr/local/bin/gost-manager.sh /usr/bin/g
}

# (省略中间原脚本其他函数定义，不变)

main() {
    check_root
    detect_environment

    case "${1:-}" in
        --menu)
            init_config && main_menu
            ;;
        *)
            if ! command -v gost >/dev/null 2>&1; then
                echo -e "${Info} 检测到GOST未安装，开始安装..."
                install_gost && create_shortcut && init_config
                echo -e "${Info} 安装完成！现在可以使用 'g' 命令"
                sleep 2 && main_menu
            else
                [ ! -f "/usr/bin/g" ] && create_shortcut
                init_config && main_menu
            fi
            ;;
    esac
}

main "$@"
