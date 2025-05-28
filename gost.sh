#!/bin/bash
# GOST 优化版管理脚本 - 使用轻量级流量控制
# 移除了可能导致卡顿的组件

Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Yellow_font_prefix="\033[33m"
Blue_font_prefix="\033[34m" && Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Warning="${Yellow_font_prefix}[警告]${Font_color_suffix}"
shell_version="2.2.1"
ct_new_ver="2.11.5"

gost_conf_path="/etc/gost/config.json"
raw_conf_path="/etc/gost/rawconf"
remarks_path="/etc/gost/remarks.txt"
expires_path="/etc/gost/expires.txt"
limits_path="/etc/gost/limits.txt"
traffic_path="/etc/gost/traffic_stats.txt"

check_root() {
    [[ $EUID != 0 ]] && echo -e "${Error} 请使用root权限运行此脚本" && exit 1
}

detect_environment() {
    if [[ -f /etc/redhat-release ]]; then
        release="centos"
    elif cat /etc/issue | grep -q -E -i "debian|ubuntu"; then
        release="debian" 
    fi
    
    case $(uname -m) in
        x86_64) arch="amd64" ;;
        *) arch="amd64" ;;
    esac
}

setup_traffic_control() {
    echo -e "${Info} 设置轻量级流量控制..."
    
    # 只安装必要的工具，跳过 apt-get update
    if ! command -v iptables >/dev/null 2>&1; then
        echo -e "${Info} 安装iptables..."
        if [[ $release == "centos" ]]; then
            yum install -y iptables 2>/dev/null || echo -e "${Warning} iptables安装失败，继续..."
        else
            apt-get install -y iptables 2>/dev/null || echo -e "${Warning} iptables安装失败，继续..."
        fi
    fi
    
    # 创建简化的流量监控脚本
    cat > /usr/local/bin/gost-traffic-lite.sh << 'EOF'
#!/bin/bash
LIMITS_FILE="/etc/gost/limits.txt"
TRAFFIC_FILE="/etc/gost/traffic_stats.txt"

# 初始化
init() {
    iptables -N GOST_TRAFFIC 2>/dev/null
    iptables -F GOST_TRAFFIC 2>/dev/null
    iptables -C INPUT -j GOST_TRAFFIC 2>/dev/null || iptables -I INPUT -j GOST_TRAFFIC
    [ ! -f "$TRAFFIC_FILE" ] && touch "$TRAFFIC_FILE"
}

# 添加端口监控
add_port() {
    local port=$1
    iptables -C GOST_TRAFFIC -p tcp --dport $port 2>/dev/null || \
        iptables -A GOST_TRAFFIC -p tcp --dport $port
    iptables -C GOST_TRAFFIC -p udp --dport $port 2>/dev/null || \
        iptables -A GOST_TRAFFIC -p udp --dport $port
}

# 获取流量
get_traffic() {
    local port=$1
    local bytes=$(iptables -L GOST_TRAFFIC -n -v -x 2>/dev/null | \
        grep "dpt:$port" | awk '{sum+=$2} END {print sum+0}')
    
    # 加上历史流量
    local saved=$(grep "^$port:" "$TRAFFIC_FILE" 2>/dev/null | cut -d: -f2 || echo 0)
    echo $((bytes + saved))
}

# 检查限制
check_limits() {
    [ ! -f "$LIMITS_FILE" ] && return
    
    while IFS=: read -r port limit_gb; do
        [ -z "$port" ] || [ "$limit_gb" = "无限制" ] && continue
        
        local bytes=$(get_traffic $port)
        local gb=$((bytes / 1073741824))
        
        if [ "$gb" -ge "$limit_gb" ]; then
            iptables -C INPUT -p tcp --dport $port -j DROP 2>/dev/null || \
                iptables -I INPUT -p tcp --dport $port -j DROP
            iptables -C INPUT -p udp --dport $port -j DROP 2>/dev/null || \
                iptables -I INPUT -p udp --dport $port -j DROP
        fi
    done < "$LIMITS_FILE"
}

# 重置流量
reset_port() {
    local port=$1
    iptables -D INPUT -p tcp --dport $port -j DROP 2>/dev/null
    iptables -D INPUT -p udp --dport $port -j DROP 2>/dev/null
    iptables -Z GOST_TRAFFIC 2>/dev/null
    sed -i "/^$port:/d" "$TRAFFIC_FILE"
}

case "$1" in
    init) init ;;
    add) add_port $2 ;;
    get) get_traffic $2 ;;
    check) check_limits ;;
    reset) reset_port $2 ;;
esac
EOF
    
    chmod +x /usr/local/bin/gost-traffic-lite.sh
    /usr/local/bin/gost-traffic-lite.sh init
    
    # 简单的定时任务
    echo "*/5 * * * * root /usr/local/bin/gost-traffic-lite.sh check >/dev/null 2>&1" > /etc/cron.d/gost-traffic
    
    echo -e "${Info} 流量控制设置完成"
}

install_gost() {
    echo -e "${Info} 开始安装GOST..."
    detect_environment
    
    # 最小化依赖安装
    echo -e "${Info} 检查基础工具..."
    if ! command -v wget >/dev/null 2>&1; then
        if [[ $release == "centos" ]]; then
            yum install -y wget curl 2>/dev/null
        else
            apt-get install -y wget curl 2>/dev/null
        fi
    fi
    
    cd /tmp
    echo -e "${Info} 下载GOST..."
    if ! wget -q --timeout=30 -O gost.gz "https://github.com/ginuerzh/gost/releases/download/v${ct_new_ver}/gost-linux-${arch}-${ct_new_ver}.gz"; then
        echo -e "${Info} 使用镜像源..."
        wget -q --timeout=30 -O gost.gz "https://mirror.ghproxy.com/https://github.com/ginuerzh/gost/releases/download/v${ct_new_ver}/gost-linux-${arch}-${ct_new_ver}.gz" || {
            echo -e "${Error} 下载失败"
            exit 1
        }
    fi
    
    gunzip gost.gz && chmod +x gost && mv gost /usr/bin/gost
    
    cat > /etc/systemd/system/gost.service << 'EOF'
[Unit]
Description=GOST
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/gost -C /etc/gost/config.json
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable gost
    
    # 设置流量控制（可选）
    read -p "是否启用流量控制功能？可能需要几分钟 (y/N): " enable_traffic
    if [[ $enable_traffic =~ ^[Yy]$ ]]; then
        setup_traffic_control
    else
        echo -e "${Info} 跳过流量控制设置"
    fi
    
    echo -e "${Info} GOST安装完成"
}

create_shortcut() {
    cat > /usr/local/bin/gost-manager.sh << 'EOF'
#!/bin/bash
if [ -f "/usr/local/bin/gost-local.sh" ]; then
    /usr/local/bin/gost-local.sh "$@"
else
    bash <(curl -sSL https://raw.githubusercontent.com/xmg0828-01/gost/main/gost.sh) --menu
fi
EOF
    chmod +x /usr/local/bin/gost-manager.sh
    ln -sf /usr/local/bin/gost-manager.sh /usr/bin/g
}

init_config() {
    mkdir -p /etc/gost
    touch /etc/gost/{rawconf,remarks.txt,expires.txt,limits.txt,traffic_stats.txt}
    [ ! -f "$gost_conf_path" ] && echo '{"Debug":false,"Retries":0,"ServeNodes":[]}' > "$gost_conf_path"
}

show_header() {
    clear
    echo -e "${Blue_font_prefix}======================================================${Font_color_suffix}"
    echo -e "${Green_font_prefix}            GOST 优化版管理面板 v${shell_version}${Font_color_suffix}"
    echo -e "${Blue_font_prefix}======================================================${Font_color_suffix}"
    echo
}

get_port_traffic() {
    local port=$1
    if [ -f "/usr/local/bin/gost-traffic-lite.sh" ]; then
        local bytes=$(/usr/local/bin/gost-traffic-lite.sh get $port 2>/dev/null || echo "0")
    else
        local bytes=0
    fi
    
    if [ "$bytes" -eq 0 ]; then
        echo "0 KB"
    elif [ "$bytes" -lt 1048576 ]; then
        echo "$((bytes / 1024)) KB"
    elif [ "$bytes" -lt 1073741824 ]; then
        echo "$((bytes / 1048576)) MB"
    else
        echo "$((bytes / 1073741824)) GB"
    fi
}

show_forwards_list() {
    echo -e "${Blue_font_prefix}=================== 转发规则列表 ===================${Font_color_suffix}"
    if [ ! -f "$raw_conf_path" ] || [ ! -s "$raw_conf_path" ]; then
        echo -e "${Warning} 暂无转发规则"
        echo
        return
    fi

    printf "${Green_font_prefix}%-4s %-10s %-22s %-15s %-10s${Font_color_suffix}\n" \
        "ID" "端口" "目标地址" "备注" "流量"
    echo -e "${Blue_font_prefix}-------------------------------------------------------------------${Font_color_suffix}"
    
    local id=1
    while IFS= read -r line; do
        local port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
        local target=$(echo "$line" | cut -d'#' -f2)
        local target_port=$(echo "$line" | cut -d'#' -f3)
        local remark=$(grep "^${port}:" "$remarks_path" 2>/dev/null | cut -d':' -f2- || echo "无")
        local traffic=$(get_port_traffic "$port")
        
        [ ${#remark} -gt 12 ] && remark="${remark:0:12}.."
        
        printf "%-4s %-10s %-22s %-15s %-10s\n" \
            "$id" "$port" "${target}:${target_port}" "$remark" "$traffic"
        
        ((id++))
    done < "$raw_conf_path"
    echo
}

add_forward_rule() {
    echo -e "${Info} 添加转发规则"
    read -p "本地端口: " local_port
    read -p "目标IP: " target_ip  
    read -p "目标端口: " target_port
    read -p "备注: " remark
    
    if [[ ! $local_port =~ ^[0-9]+$ ]] || [[ ! $target_port =~ ^[0-9]+$ ]]; then
        echo -e "${Error} 端口必须为数字" && sleep 2 && return
    fi
    
    if grep -q "/${local_port}#" "$raw_conf_path" 2>/dev/null; then
        echo -e "${Error} 端口已被使用" && sleep 2 && return
    fi
    
    # 流量限制（如果启用）
    if [ -f "/usr/local/bin/gost-traffic-lite.sh" ]; then
        read -p "设置流量限制(GB，0表示无限制): " limit
        if [[ $limit =~ ^[0-9]+$ ]] && [ "$limit" -gt 0 ]; then
            echo "${local_port}:${limit}" >> "$limits_path"
            /usr/local/bin/gost-traffic-lite.sh add $local_port
        else
            echo "${local_port}:无限制" >> "$limits_path"
        fi
    fi
    
    echo "nonencrypt/${local_port}#${target_ip}#${target_port}" >> "$raw_conf_path"
    [ -n "$remark" ] && echo "${local_port}:${remark}" >> "$remarks_path"
    
    rebuild_config
    echo -e "${Info} 规则添加成功" && sleep 2
}

delete_forward_rule() {
    [ ! -s "$raw_conf_path" ] && echo -e "${Warning} 无规则" && sleep 2 && return
    
    read -p "输入要删除的ID: " rule_id
    local line=$(sed -n "${rule_id}p" "$raw_conf_path")
    [ -z "$line" ] && echo -e "${Error} ID不存在" && sleep 2 && return
    
    local port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
    
    sed -i "${rule_id}d" "$raw_conf_path"
    sed -i "/^${port}:/d" "$remarks_path" "$limits_path" 2>/dev/null
    
    # 清理防火墙规则
    iptables -D INPUT -p tcp --dport $port -j DROP 2>/dev/null
    iptables -D INPUT -p udp --dport $port -j DROP 2>/dev/null
    
    rebuild_config
    echo -e "${Info} 已删除端口 ${port}" && sleep 2
}

rebuild_config() {
    if [ ! -s "$raw_conf_path" ]; then
        echo '{"Debug":false,"Retries":0,"ServeNodes":[]}' > "$gost_conf_path"
    else
        echo '{"Debug":false,"Retries":0,"ServeNodes":[' > "$gost_conf_path"
        local first=1
        while IFS= read -r line; do
            local port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
            local target=$(echo "$line" | cut -d'#' -f2)
            local target_port=$(echo "$line" | cut -d'#' -f3)
            [ "$first" -eq 0 ] && echo "," >> "$gost_conf_path"
            echo -n "\"tcp://:$port/$target:$target_port\",\"udp://:$port/$target:$target_port\"" >> "$gost_conf_path"
            first=0
        done < "$raw_conf_path"
        echo ']}' >> "$gost_conf_path"
    fi
    systemctl restart gost >/dev/null 2>&1
}

main_menu() {
    while true; do
        show_header
        show_forwards_list
        echo -e "${Green_font_prefix}1.${Font_color_suffix} 添加转发"
        echo -e "${Green_font_prefix}2.${Font_color_suffix} 删除转发"
        echo -e "${Green_font_prefix}3.${Font_color_suffix} 重启服务"
        echo -e "${Green_font_prefix}0.${Font_color_suffix} 退出"
        echo
        read -p "选择: " choice
        
        case $choice in
            1) add_forward_rule ;;
            2) delete_forward_rule ;;
            3) systemctl restart gost && echo -e "${Info} 已重启" && sleep 1 ;;
            0) exit 0 ;;
        esac
    done
}

# 主函数
check_root

if ! command -v gost >/dev/null 2>&1; then
    echo -e "${Info} 首次运行，安装GOST..."
    install_gost
    create_shortcut
    init_config
    echo -e "${Info} 安装完成，使用 'g' 命令打开面板"
    sleep 2
fi

[ ! -f "/usr/bin/g" ] && create_shortcut
init_config
main_menu
