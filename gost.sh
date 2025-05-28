#!/bin/bash
# GOST 增强版管理脚本 v2.2.0 - 完整版
# 一键安装: bash <(curl -sSL https://raw.githubusercontent.com/xmg0828-01/gost/main/gost.sh)
# 快捷使用: g

Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Yellow_font_prefix="\033[33m"
Blue_font_prefix="\033[34m" && Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Warning="${Yellow_font_prefix}[警告]${Font_color_suffix}"
shell_version="2.2.0"
ct_new_ver="2.11.5"

gost_conf_path="/etc/gost/config.json"
raw_conf_path="/etc/gost/rawconf"
remarks_path="/etc/gost/remarks.txt"
expires_path="/etc/gost/expires.txt"
limits_path="/etc/gost/limits.txt"
traffic_path="/etc/gost/traffic_stats.db"

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

is_oneclick_install() {
    [[ "$0" =~ /dev/fd/ ]] || [[ "$0" == "bash" ]] || [[ "$0" =~ /proc/self/fd/ ]]
}

setup_traffic_control() {
    echo -e "${Info} 设置流量控制系统..."
    
    if [[ $release == "centos" ]]; then
        yum install -y iptables iptables-services conntrack-tools bc >/dev/null 2>&1
        systemctl enable iptables >/dev/null 2>&1
    else
        apt-get install -y iptables iptables-persistent conntrack bc >/dev/null 2>&1
    fi
    
    # 创建精确的流量监控脚本
    cat > /usr/local/bin/gost-traffic-monitor.sh << 'EOF'
#!/bin/bash

LIMITS_FILE="/etc/gost/limits.txt"
TRAFFIC_DB="/etc/gost/traffic_stats.db"
LOG_FILE="/var/log/gost-traffic.log"

# 初始化流量统计数据库
init_db() {
    [ ! -f "$TRAFFIC_DB" ] && echo "# port:total_bytes:reset_date" > "$TRAFFIC_DB"
}

# 获取端口的实际流量（使用conntrack）
get_port_real_traffic() {
    local port=$1
    local bytes=0
    
    # 方法1: 使用conntrack统计实时连接流量
    if command -v conntrack >/dev/null 2>&1; then
        # TCP流量
        local tcp_bytes=$(conntrack -L -p tcp --dport $port 2>/dev/null | \
            awk '{for(i=1;i<=NF;i++) if($i~/bytes=/) {gsub(/bytes=/,"",$i); sum+=$i}} END {print sum+0}')
        # UDP流量
        local udp_bytes=$(conntrack -L -p udp --dport $port 2>/dev/null | \
            awk '{for(i=1;i<=NF;i++) if($i~/bytes=/) {gsub(/bytes=/,"",$i); sum+=$i}} END {print sum+0}')
        bytes=$((tcp_bytes + udp_bytes))
    fi
    
    # 方法2: 使用iptables统计（作为备份）
    if [ "$bytes" -eq 0 ]; then
        # 确保规则存在
        iptables -n -L GOST_TRAFFIC -v -x 2>/dev/null | grep -q ":$port" || add_iptables_rules $port
        
        local iptables_bytes=$(iptables -n -L GOST_TRAFFIC -v -x 2>/dev/null | \
            grep -E ":(tcp|udp) dpt:$port" | awk '{sum+=$2} END {print sum+0}')
        bytes=$iptables_bytes
    fi
    
    echo $bytes
}

# 添加iptables监控规则
add_iptables_rules() {
    local port=$1
    
    # 创建GOST_TRAFFIC链
    iptables -t filter -N GOST_TRAFFIC 2>/dev/null
    
    # 确保链被引用
    iptables -C INPUT -j GOST_TRAFFIC 2>/dev/null || iptables -I INPUT -j GOST_TRAFFIC
    iptables -C FORWARD -j GOST_TRAFFIC 2>/dev/null || iptables -I FORWARD -j GOST_TRAFFIC
    iptables -C OUTPUT -j GOST_TRAFFIC 2>/dev/null || iptables -I OUTPUT -j GOST_TRAFFIC
    
    # 添加端口监控规则（避免重复）
    iptables -C GOST_TRAFFIC -p tcp --dport $port 2>/dev/null || \
        iptables -A GOST_TRAFFIC -p tcp --dport $port
    iptables -C GOST_TRAFFIC -p udp --dport $port 2>/dev/null || \
        iptables -A GOST_TRAFFIC -p udp --dport $port
}

# 更新流量统计
update_traffic_stats() {
    local port=$1
    local current_bytes=$(get_port_real_traffic $port)
    local today=$(date +%Y-%m-%d)
    
    # 读取历史数据
    local saved_data=$(grep "^$port:" "$TRAFFIC_DB" 2>/dev/null | tail -1)
    local saved_bytes=0
    local reset_date=""
    
    if [ -n "$saved_data" ]; then
        saved_bytes=$(echo "$saved_data" | cut -d: -f2)
        reset_date=$(echo "$saved_data" | cut -d: -f3)
    else
        reset_date=$today
    fi
    
    # 如果是新的一天，重置流量
    if [ "$reset_date" != "$today" ]; then
        saved_bytes=0
        reset_date=$today
        # 重置iptables计数
        iptables -Z GOST_TRAFFIC 2>/dev/null
    fi
    
    # 计算总流量
    local total_bytes=$((saved_bytes + current_bytes))
    
    # 更新数据库
    grep -v "^$port:" "$TRAFFIC_DB" > "${TRAFFIC_DB}.tmp" 2>/dev/null
    echo "$port:$total_bytes:$reset_date" >> "${TRAFFIC_DB}.tmp"
    mv "${TRAFFIC_DB}.tmp" "$TRAFFIC_DB"
    
    echo $total_bytes
}

# 检查流量限制
check_traffic_limit() {
    [ ! -f "$LIMITS_FILE" ] && return
    
    while IFS=: read -r port limit_gb; do
        [ -z "$port" ] && continue
        
        if [ "$limit_gb" != "无限制" ] && [ "$limit_gb" -gt 0 ]; then
            # 更新并获取流量
            local total_bytes=$(update_traffic_stats $port)
            local total_gb=$(echo "scale=2; $total_bytes / 1073741824" | bc)
            
            # 检查是否超限
            if (( $(echo "$total_gb >= $limit_gb" | bc -l) )); then
                # 阻止端口
                iptables -C INPUT -p tcp --dport $port -j DROP 2>/dev/null || \
                    iptables -I INPUT -p tcp --dport $port -j DROP
                iptables -C INPUT -p udp --dport $port -j DROP 2>/dev/null || \
                    iptables -I INPUT -p udp --dport $port -j DROP
                    
                echo "[$(date)] Port $port blocked - Traffic: ${total_gb}GB / Limit: ${limit_gb}GB" >> "$LOG_FILE"
            else
                # 确保端口未被阻止
                iptables -D INPUT -p tcp --dport $port -j DROP 2>/dev/null
                iptables -D INPUT -p udp --dport $port -j DROP 2>/dev/null
            fi
        fi
    done < "$LIMITS_FILE"
}

# 获取端口流量（供显示用）
get_traffic() {
    local port=$1
    local data=$(grep "^$port:" "$TRAFFIC_DB" 2>/dev/null | tail -1)
    
    if [ -n "$data" ]; then
        local bytes=$(echo "$data" | cut -d: -f2)
        echo $bytes
    else
        echo 0
    fi
}

# 重置端口流量
reset_port() {
    local port=$1
    
    # 清除iptables规则
    iptables -D INPUT -p tcp --dport $port -j DROP 2>/dev/null
    iptables -D INPUT -p udp --dport $port -j DROP 2>/dev/null
    
    # 重置iptables计数
    iptables -Z GOST_TRAFFIC 2>/dev/null
    
    # 清除流量记录
    grep -v "^$port:" "$TRAFFIC_DB" > "${TRAFFIC_DB}.tmp" 2>/dev/null
    mv "${TRAFFIC_DB}.tmp" "$TRAFFIC_DB"
    
    # 清除conntrack记录
    conntrack -D -p tcp --dport $port 2>/dev/null
    conntrack -D -p udp --dport $port 2>/dev/null
    
    echo "[$(date)] Port $port traffic reset" >> "$LOG_FILE"
}

# 主函数
case "$1" in
    init)
        init_db
        iptables -t filter -N GOST_TRAFFIC 2>/dev/null
        ;;
    add)
        add_iptables_rules $2
        ;;
    check)
        init_db
        check_traffic_limit
        ;;
    get)
        get_traffic $2
        ;;
    reset)
        reset_port $2
        ;;
    *)
        echo "Usage: $0 {init|add|check|get|reset} [port]"
        ;;
esac
EOF
    
    chmod +x /usr/local/bin/gost-traffic-monitor.sh
    
    # 初始化
    /usr/local/bin/gost-traffic-monitor.sh init
    
    # 设置定时任务（每分钟检查）
    cat > /etc/cron.d/gost-traffic << 'EOF'
# 每分钟检查流量限制
* * * * * root /usr/local/bin/gost-traffic-monitor.sh check >/dev/null 2>&1
EOF
    
    systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null
    
    echo -e "${Info} 流量控制系统设置完成"
}

install_gost() {
    echo -e "${Info} 开始安装GOST..."
    detect_environment
    
    if [[ $release == "centos" ]]; then
        yum install -y wget curl bc >/dev/null 2>&1
    else
        apt-get update >/dev/null 2>&1
        apt-get install -y wget curl bc >/dev/null 2>&1
    fi
    
    cd /tmp
    if ! wget -q --timeout=10 -O gost.gz "https://github.com/ginuerzh/gost/releases/download/v${ct_new_ver}/gost-linux-${arch}-${ct_new_ver}.gz"; then
        echo -e "${Info} 使用镜像源下载..."
        if ! wget -q --timeout=10 -O gost.gz "https://mirror.ghproxy.com/https://github.com/ginuerzh/gost/releases/download/v${ct_new_ver}/gost-linux-${arch}-${ct_new_ver}.gz"; then
            echo -e "${Error} GOST下载失败"
            exit 1
        fi
    fi
    
    gunzip gost.gz
    chmod +x gost
    mv gost /usr/bin/gost
    
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
    setup_traffic_control
    echo -e "${Info} GOST安装完成"
}

create_shortcut() {
    echo -e "${Info} 创建快捷命令..."
    
    if is_oneclick_install; then
        # 在线安装模式：下载脚本到本地
        if wget -q -O /usr/local/bin/gost-manager.sh "https://raw.githubusercontent.com/xmg0828-01/gost/main/gost.sh"; then
            chmod +x /usr/local/bin/gost-manager.sh
        else
            # 备用方案：创建调用在线脚本的包装器
            cat > /usr/local/bin/gost-manager.sh << 'EOF'
#!/bin/bash
# 检查本地脚本是否存在
if [ -f "/usr/local/bin/gost-local.sh" ]; then
    /usr/local/bin/gost-local.sh "$@"
else
    # 调用在线脚本
    bash <(curl -sSL https://raw.githubusercontent.com/xmg0828-01/gost/main/gost.sh) --menu
fi
EOF
            chmod +x /usr/local/bin/gost-manager.sh
        fi
    else
        # 本地安装模式：直接复制
        cp "$0" /usr/local/bin/gost-manager.sh
        chmod +x /usr/local/bin/gost-manager.sh
    fi
    
    # 创建软链接
    ln -sf /usr/local/bin/gost-manager.sh /usr/bin/g
    echo -e "${Info} 快捷命令 'g' 创建成功"
}

init_config() {
    mkdir -p /etc/gost
    touch /etc/gost/{rawconf,remarks.txt,expires.txt,limits.txt}
    [ ! -f "$traffic_path" ] && echo "# port:total_bytes:reset_date" > "$traffic_path"
    
    if [ ! -f "$gost_conf_path" ]; then
        cat > "$gost_conf_path" << 'EOF'
{
    "Debug": false,
    "Retries": 0,
    "ServeNodes": []
}
EOF
    fi
}

show_header() {
    clear
    echo -e "${Blue_font_prefix}======================================================${Font_color_suffix}"
    echo -e "${Green_font_prefix}            GOST 增强版管理面板 v${shell_version}${Font_color_suffix}"
    echo -e "${Blue_font_prefix}======================================================${Font_color_suffix}"
    echo -e "${Yellow_font_prefix}功能: 到期管理 | 流量限制 | 转发备注${Font_color_suffix}"
    echo -e "${Blue_font_prefix}======================================================${Font_color_suffix}"
    echo
}

check_expired_rules() {
    local expired_count=0
    local current_date=$(date +%s)
    
    if [ -f "$expires_path" ]; then
        while IFS=: read -r port expire_date; do
            if [ "$expire_date" != "永久" ] && [ "$expire_date" -lt "$current_date" ]; then
                ((expired_count++))
            fi
        done < "$expires_path"
    fi
    
    echo "$expired_count"
}

format_expire_date() {
    local expire_timestamp=$1
    if [ "$expire_timestamp" = "永久" ]; then
        echo "永久"
    else
        local current=$(date +%s)
        local days_left=$(( (expire_timestamp - current) / 86400 ))
        if [ "$days_left" -lt 0 ]; then
            echo "已过期"
        elif [ "$days_left" -eq 0 ]; then
            echo "今天到期"
        else
            echo "${days_left}天后"
        fi
    fi
}

get_port_traffic() {
    local port=$1
    local bytes=$(/usr/local/bin/gost-traffic-monitor.sh get $port 2>/dev/null || echo "0")
    
    if [ "$bytes" -eq 0 ]; then
        echo "0 KB"
    elif [ "$bytes" -lt 1048576 ]; then
        echo "$((bytes / 1024)) KB"
    elif [ "$bytes" -lt 1073741824 ]; then
        echo "$(echo "scale=1; $bytes / 1048576" | bc) MB"
    else
        echo "$(echo "scale=2; $bytes / 1073741824" | bc) GB"
    fi
}

check_port_blocked() {
    local port=$1
    if iptables -L INPUT -n | grep -q "tcp dpt:$port.*DROP"; then
        echo "已限制"
    else
        echo "正常"
    fi
}

get_system_info() {
    if command -v gost >/dev/null 2>&1; then
        gost_status=$(systemctl is-active gost 2>/dev/null || echo "未运行")
        gost_version=$(gost -V 2>/dev/null | awk '{print $2}' || echo "未知")
    else
        gost_status="未安装"
        gost_version="未安装"
    fi
    
    active_rules=$(wc -l < "$raw_conf_path" 2>/dev/null || echo "0")
    expired_rules=$(check_expired_rules)
    
    echo -e "${Info} 服务状态: ${gost_status} | 版本: ${gost_version}"
    echo -e "${Info} 活跃规则: ${active_rules} | 过期规则: ${expired_rules}"
    echo
}

show_forwards_list() {
    echo -e "${Blue_font_prefix}================================ 转发规则列表 ================================${Font_color_suffix}"
    if [ ! -f "$raw_conf_path" ] || [ ! -s "$raw_conf_path" ]; then
        echo -e "${Warning} 暂无转发规则"
        echo
        return
    fi

    # 使用printf格式化表格，确保对齐
    printf "${Green_font_prefix}%-4s %-8s %-20s %-12s %-10s %-10s %-10s %-8s${Font_color_suffix}\n" \
        "ID" "端口" "目标地址" "备注" "到期" "限制" "已用" "状态"
    echo -e "${Blue_font_prefix}------------------------------------------------------------------------------${Font_color_suffix}"
    
    local id=1
    while IFS= read -r line; do
        local port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
        local target=$(echo "$line" | cut -d'#' -f2)
        local target_port=$(echo "$line" | cut -d'#' -f3)
        local remark=$(grep "^${port}:" "$remarks_path" 2>/dev/null | cut -d':' -f2- || echo "无")
        local expire_info=$(grep "^${port}:" "$expires_path" 2>/dev/null | cut -d':' -f2- || echo "永久")
        local expire_display=$(format_expire_date "$expire_info")
        local limit_info=$(grep "^${port}:" "$limits_path" 2>/dev/null | cut -d':' -f2- || echo "无限制")
        local traffic_used=$(get_port_traffic "$port")
        local port_status=$(check_port_blocked "$port")
        
        # 格式化限制信息
        if [ "$limit_info" != "无限制" ]; then
            limit_display="${limit_info}GB"
        else
            limit_display="$limit_info"
        fi
        
        # 截断过长的内容
        [ ${#remark} -gt 10 ] && remark="${remark:0:10}.."
        [ ${#target} -gt 15 ] && target_display="${target:0:12}..." || target_display="$target"
        
        # 根据状态设置颜色
        if [ "$port_status" = "已限制" ]; then
            status_color="${Red_font_prefix}"
        else
            status_color="${Green_font_prefix}"
        fi
        
        printf "%-4s %-8s %-20s %-12s %-10s %-10s %-10s ${status_color}%-8s${Font_color_suffix}\n" \
            "$id" "$port" "${target_display}:${target_port}" "$remark" "$expire_display" \
            "$limit_display" "$traffic_used" "$port_status"
        
        ((id++))
    done < "$raw_conf_path"
    echo
}

add_forward_rule() {
    echo -e "${Info} 添加TCP+UDP转发规则"
    read -p "本地监听端口: " local_port
    read -p "目标IP地址: " target_ip  
    read -p "目标端口: " target_port
    read -p "备注信息 (可选): " remark
    
    echo -e "${Info} 设置到期时间:"
    echo "1) 永久有效"
    echo "2) 自定义天数"
    read -p "请选择 [1-2]: " expire_choice
    
    local expire_timestamp="永久"
    if [ "$expire_choice" = "2" ]; then
        read -p "请输入有效天数: " days
        if [[ $days =~ ^[0-9]+$ ]] && [ "$days" -gt 0 ]; then
            expire_timestamp=$(date -d "+${days} days" +%s)
            echo -e "${Info} 规则将在 ${days} 天后到期"
        else
            echo -e "${Warning} 天数格式错误，设置为永久有效"
            expire_timestamp="永久"
        fi
    fi
    
    echo -e "${Info} 设置每日流量限制:"
    echo "1) 无限制"
    echo "2) 自定义限制 (GB/天)"
    read -p "请选择 [1-2]: " limit_choice
    
    local traffic_limit="无限制"
    if [ "$limit_choice" = "2" ]; then
        read -p "请输入每日流量限制 (GB): " limit_gb
        if [[ $limit_gb =~ ^[0-9]+$ ]] && [ "$limit_gb" -gt 0 ]; then
            traffic_limit="$limit_gb"
            echo -e "${Info} 每日流量限制设置为 ${limit_gb} GB"
        else
            echo -e "${Warning} 流量限制格式错误，设置为无限制"
            traffic_limit="无限制"
        fi
    fi
    
    if [[ ! $local_port =~ ^[0-9]+$ ]] || [[ ! $target_port =~ ^[0-9]+$ ]]; then
        echo -e "${Error} 端口必须为数字"
        sleep 3
        return
    fi
    
    if grep -q "/${local_port}#" "$raw_conf_path" 2>/dev/null; then
        echo -e "${Error} 端口 $local_port 已被使用"
        sleep 3
        return
    fi
    
    echo "nonencrypt/${local_port}#${target_ip}#${target_port}" >> "$raw_conf_path"
    [ -n "$remark" ] && echo "${local_port}:${remark}" >> "$remarks_path"
    echo "${local_port}:${expire_timestamp}" >> "$expires_path"
    echo "${local_port}:${traffic_limit}" >> "$limits_path"
    
    # 添加流量监控
    /usr/local/bin/gost-traffic-monitor.sh add $local_port
    
    rebuild_config
    echo -e "${Info} 转发规则已添加"
    echo -e "${Info} 端口: ${local_port} -> ${target_ip}:${target_port}"
    echo -e "${Info} 备注: ${remark:-无}"
    echo -e "${Info} 到期: $(format_expire_date "$expire_timestamp")"
    echo -e "${Info} 限制: ${traffic_limit}$([ "$traffic_limit" != "无限制" ] && echo "GB/天")"
    sleep 3
}

delete_forward_rule() {
    if [ ! -f "$raw_conf_path" ] || [ ! -s "$raw_conf_path" ]; then
        echo -e "${Warning} 暂无转发规则"
        sleep 2
        return
    fi
    
    read -p "请输入要删除的规则ID: " rule_id
    
    if ! [[ $rule_id =~ ^[0-9]+$ ]] || [ "$rule_id" -lt 1 ]; then
        echo -e "${Error} 无效的规则ID"
        sleep 2
        return
    fi
    
    local line=$(sed -n "${rule_id}p" "$raw_conf_path")
    if [ -z "$line" ]; then
        echo -e "${Error} 规则ID不存在"
        sleep 2
        return
    fi
    
    local port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
    
    # 清理iptables规则
    iptables -D GOST_TRAFFIC -p tcp --dport $port 2>/dev/null
    iptables -D GOST_TRAFFIC -p udp --dport $port 2>/dev/null
    iptables -D INPUT -p tcp --dport $port -j DROP 2>/dev/null
    iptables -D INPUT -p udp --dport $port -j DROP 2>/dev/null
    
    sed -i "${rule_id}d" "$raw_conf_path"
    sed -i "/^${port}:/d" "$remarks_path" 2>/dev/null
    sed -i "/^${port}:/d" "$expires_path" 2>/dev/null
    sed -i "/^${port}:/d" "$limits_path" 2>/dev/null
    sed -i "/^${port}:/d" "$traffic_path" 2>/dev/null
    
    rebuild_config
    echo -e "${Info} 规则已删除 (端口: ${port})"
    sleep 2
}

reset_port_traffic() {
    if [ ! -f "$raw_conf_path" ] || [ ! -s "$raw_conf_path" ]; then
        echo -e "${Warning} 暂无转发规则"
        sleep 2
        return
    fi
    
    read -p "请输入要重置流量的规则ID: " rule_id
    
    local line=$(sed -n "${rule_id}p" "$raw_conf_path")
    if [ -z "$line" ]; then
        echo -e "${Error} 规则ID不存在"
        sleep 2
        return
    fi
    
    local port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
    
    /usr/local/bin/gost-traffic-monitor.sh reset "$port"
    
    echo -e "${Info} 端口 ${port} 今日流量已重置，限制已解除"
    sleep 2
}

rebuild_config() {
    if [ ! -f "$raw_conf_path" ] || [ ! -s "$raw_conf_path" ]; then
        cat > "$gost_conf_path" << 'EOF'
{
    "Debug": false,
    "Retries": 0,
    "ServeNodes": []
}
EOF
        systemctl restart gost >/dev/null 2>&1
        return
    fi
    
    cat > "$gost_conf_path" << 'EOF'
{
    "Debug": false,
    "Retries": 0,
    "ServeNodes": [
EOF
    
    local count_line=$(wc -l < "$raw_conf_path")
    local i=1
    
    while IFS= read -r line; do
        local port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
        local target=$(echo "$line" | cut -d'#' -f2)
        local target_port=$(echo "$line" | cut -d'#' -f3)
        
        echo -n "        \"tcp://:$port/$target:$target_port\",\"udp://:$port/$target:$target_port\"" >> "$gost_conf_path"
        
        if [ "$i" -lt "$count_line" ]; then
            echo "," >> "$gost_conf_path"
        else
            echo "" >> "$gost_conf_path"
        fi
        ((i++))
    done < "$raw_conf_path"
    
    echo "    ]" >> "$gost_conf_path"
    echo "}" >> "$gost_conf_path"
    
    systemctl restart gost >/dev/null 2>&1
}

manage_forwards() {
    while true; do
        show_header
        show_forwards_list
        echo -e "${Green_font_prefix}=================== 转发管理 ===================${Font_color_suffix}"
        echo -e "${Green_font_prefix}1.${Font_color_suffix} 新增转发规则"
        echo -e "${Green_font_prefix}2.${Font_color_suffix} 删除转发规则"
        echo -e "${Green_font_prefix}3.${Font_color_suffix} 重置端口流量"
        echo -e "${Green_font_prefix}4.${Font_color_suffix} 重启GOST服务"
        echo -e "${Green_font_prefix}0.${Font_color_suffix} 返回主菜单"
        echo
        read -p "请选择操作: " choice
        
        case $choice in
            1) add_forward_rule ;;
            2) delete_forward_rule ;;
            3) reset_port_traffic ;;
            4) systemctl restart gost && echo -e "${Info} 服务已重启" && sleep 2 ;;
            0) break ;;
            *) echo -e "${Error} 无效选择" && sleep 2 ;;
        esac
    done
}

system_management() {
    while true; do
        show_header
        echo -e "${Green_font_prefix}=================== 系统管理 ===================${Font_color_suffix}"
        echo -e "${Green_font_prefix}1.${Font_color_suffix} 查看服务状态"
        echo -e "${Green_font_prefix}2.${Font_color_suffix} 启动GOST服务"
        echo -e "${Green_font_prefix}3.${Font_color_suffix} 停止GOST服务"
        echo -e "${Green_font_prefix}4.${Font_color_suffix} 重启GOST服务"
        echo -e "${Green_font_prefix}5.${Font_color_suffix} 查看流量日志"
        echo -e "${Green_font_prefix}6.${Font_color_suffix} 卸载GOST"
        echo -e "${Green_font_prefix}0.${Font_color_suffix} 返回主菜单"
        echo
        read -p "请选择操作: " choice
        
        case $choice in
            1) 
                echo -e "${Info} 服务状态: $(systemctl is-active gost 2>/dev/null || echo '未运行')"
                echo -e "${Info} 开机自启: $(systemctl is-enabled gost 2>/dev/null || echo '未设置')"
                echo -e "${Info} 流量控制: $([ -f /usr/local/bin/gost-traffic-monitor.sh ] && echo '已启用(每分钟检查)' || echo '未启用')"
                echo -e "${Info} 防火墙链: $(iptables -L GOST_TRAFFIC >/dev/null 2>&1 && echo '正常' || echo '未创建')"
                read -p "按Enter继续..."
                ;;
            2) systemctl start gost && echo -e "${Info} 服务已启动" && sleep 2 ;;
            3) systemctl stop gost && echo -e "${Info} 服务已停止" && sleep 2 ;;
            4) systemctl restart gost && echo -e "${Info} 服务已重启" && sleep 2 ;;
            5)
                echo -e "${Info} 流量监控日志 (最近20条):"
                echo -e "${Blue_font_prefix}=================================================${Font_color_suffix}"
                if [ -f /var/log/gost-traffic.log ]; then
                    tail -20 /var/log/gost-traffic.log
                else
                    echo "暂无日志记录"
                fi
                echo -e "${Blue_font_prefix}=================================================${Font_color_suffix}"
                read -p "按Enter继续..."
                ;;
            6)
                read -p "确认卸载GOST？(y/N): " confirm
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    systemctl stop gost 2>/dev/null
                    systemctl disable gost 2>/dev/null
                    iptables -F GOST_TRAFFIC 2>/dev/null
                    iptables -X GOST_TRAFFIC 2>/dev/null
                    rm -f /usr/bin/gost /etc/systemd/system/gost.service /usr/bin/g
                    rm -rf /etc/gost /usr/local/bin/gost-manager.sh /usr/local/bin/gost-traffic-monitor.sh
                    rm -f /etc/cron.d/gost-traffic
                    echo -e "${Info} 卸载完成"
                    exit 0
                fi
                ;;
            0) break ;;
            *) echo -e "${Error} 无效选择" && sleep 2 ;;
        esac
    done
}

main_menu() {
    while true; do
        show_header
        get_system_info
        echo -e "${Green_font_prefix}==================== 主菜单 ====================${Font_color_suffix}"
        echo -e "${Green_font_prefix}1.${Font_color_suffix} 转发管理 (规则/到期/流量限制)"
        echo -e "${Green_font_prefix}2.${Font_color_suffix} 系统管理 (服务/状态/日志)"
        echo -e "${Green_font_prefix}0.${Font_color_suffix} 退出程序"
        echo -e "${Blue_font_prefix}=================================================${Font_color_suffix}"
        echo -e "${Yellow_font_prefix}提示: 使用命令 'g' 可快速打开此面板${Font_color_suffix}"
        echo
        read -p "请选择操作 [0-2]: " choice
        
        case $choice in
            1) manage_forwards ;;
            2) system_management ;;
            0) echo -e "${Info} 感谢使用!" && exit 0 ;;
            *) echo -e "${Error} 无效选择" && sleep 2 ;;
        esac
    done
}

main() {
    check_root
    
    case "${1:-}" in
        --menu)
            init_config
            main_menu
            ;;
        *)
            if ! command -v gost >/dev/null 2>&1; then
                echo -e "${Info} 检测到GOST未安装，开始安装..."
                install_gost
                create_shortcut
                init_config
                echo -e "${Info} 安装完成！现在可以使用 'g' 命令打开管理面板"
                echo -e "${Info} 正在打开管理面板..."
                sleep 2
                main_menu
            else
                if [ ! -f "/usr/bin/g" ]; then
                    create_shortcut
                fi
                init_config
                main_menu
            fi
            ;;
    esac
}

# 执行主函数
main "$@"
