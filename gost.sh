#!/bin/bash
# GOST 增强版管理脚本 v2.1.0 - 带真实流量限制
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
        if [ "$limit_gb" != "无限制" ] && [ "$limit_gb" -gt 0 ]; then
            local bytes=$(iptables -L GOST_TRAFFIC -n -v -x | grep ":$port " | awk '{sum+=$2} END {print sum+0}')
            local gb=$((bytes / 1073741824))
            if [ "$gb" -ge "$limit_gb" ]; then
                iptables -I INPUT -p tcp --dport $port -j DROP 2>/dev/null
                iptables -I INPUT -p udp --dport $port -j DROP 2>/dev/null
            fi
        fi
    done < $LIMITS_FILE 2>/dev/null
}
[ "$1" = "check" ] && check_traffic
EOF
    
    chmod +x /usr/local/bin/gost-monitor.sh
    echo "0 * * * * root /usr/local/bin/gost-monitor.sh check" > /etc/cron.d/gost-traffic
    systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null
}

install_gost() {
    echo -e "${Info} 开始安装GOST..."
    detect_environment
    
    if [[ $release == "centos" ]]; then
        yum install -y wget curl >/dev/null 2>&1
    else
        apt-get update >/dev/null 2>&1
        apt-get install -y wget curl >/dev/null 2>&1
    fi
    
    cd /tmp
    if ! wget -q -O gost.gz "https://github.com/ginuerzh/gost/releases/download/v${ct_new_ver}/gost-linux-${arch}-${ct_new_ver}.gz"; then
        wget -q -O gost.gz "https://mirror.ghproxy.com/https://github.com/ginuerzh/gost/releases/download/v${ct_new_ver}/gost-linux-${arch}-${ct_new_ver}.gz"
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
    
    systemctl daemon-reload && systemctl enable gost
    setup_traffic_control
    echo -e "${Info} GOST安装完成"
}

create_shortcut() {
    echo -e "${Info} 创建快捷命令..."
    if is_oneclick_install; then
        cat > /usr/local/bin/gost-manager.sh << 'EOF'
#!/bin/bash
bash <(curl -sSL https://raw.githubusercontent.com/xmg0828-01/gost/main/gost.sh) --menu
EOF
    else
        cp "$0" /usr/local/bin/gost-manager.sh
    fi
    chmod +x /usr/local/bin/gost-manager.sh
    ln -sf /usr/local/bin/gost-manager.sh /usr/bin/g
}

init_config() {
    mkdir -p /etc/gost
    touch /etc/gost/{rawconf,remarks.txt,expires.txt,limits.txt}
    [ ! -f "$gost_conf_path" ] && echo '{"Debug":false,"Retries":0,"ServeNodes":[]}' > "$gost_conf_path"
}

show_header() {
    clear
    echo -e "${Blue_font_prefix}======================================================${Font_color_suffix}"
    echo -e "${Green_font_prefix}            GOST 增强版管理面板 v${shell_version}${Font_color_suffix}"
    echo -e "${Blue_font_prefix}======================================================${Font_color_suffix}"
    echo -e "${Yellow_font_prefix}功能: 到期管理 | 真实流量限制 | 转发备注${Font_color_suffix}"
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
    local bytes=$(iptables -L GOST_TRAFFIC -n -v -x 2>/dev/null | grep ":$port " | awk '{sum+=$2} END {print sum+0}')
    if [ "$bytes" -gt 1073741824 ]; then
        echo "$(( bytes / 1073741824 )) GB"
    elif [ "$bytes" -gt 1048576 ]; then
        echo "$(( bytes / 1048576 )) MB"
    else
        echo "$(( bytes / 1024 )) KB"
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
    echo -e "${Blue_font_prefix}=================== 转发规则 ===================${Font_color_suffix}"
    if [ ! -f "$raw_conf_path" ] || [ ! -s "$raw_conf_path" ]; then
        echo -e "${Warning} 暂无转发规则"
        echo
        return
    fi

    echo -e "${Green_font_prefix}ID\t端口\t目标地址\t\t备注\t\t到期\t\t限制\t\t已用\t\t状态${Font_color_suffix}"
    echo "---------------------------------------------------------------------------------------------"
    
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
        
        printf "%d\t%s\t%s:%s\t\t%s\t\t%s\t%s\t\t%s\t\t%s\n" "$id" "$port" "$target" "$target_port" "$remark" "$expire_display" "$limit_info" "$traffic_used" "$port_status"
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
        else
            expire_timestamp="永久"
        fi
    fi
    
    echo -e "${Info} 设置流量限制:"
    echo "1) 无限制"
    echo "2) 自定义限制 (GB)"
    read -p "请选择 [1-2]: " limit_choice
    
    local traffic_limit="无限制"
    if [ "$limit_choice" = "2" ]; then
        read -p "请输入流量限制 (GB): " limit_gb
        if [[ $limit_gb =~ ^[0-9]+$ ]] && [ "$limit_gb" -gt 0 ]; then
            traffic_limit="$limit_gb"
        else
            traffic_limit="无限制"
        fi
    fi
    
    if [[ ! $local_port =~ ^[0-9]+$ ]] || [[ ! $target_port =~ ^[0-9]+$ ]]; then
        echo -e "${Error} 端口必须为数字" && sleep 2 && return
    fi
    
    if grep -q "/${local_port}#" "$raw_conf_path" 2>/dev/null; then
        echo -e "${Error} 端口 $local_port 已被使用" && sleep 2 && return
    fi
    
    echo "nonencrypt/${local_port}#${target_ip}#${target_port}" >> "$raw_conf_path"
    [ -n "$remark" ] && echo "${local_port}:${remark}" >> "$remarks_path"
    echo "${local_port}:${expire_timestamp}" >> "$expires_path"
    echo "${local_port}:${traffic_limit}" >> "$limits_path"
    
    if [ "$traffic_limit" != "无限制" ]; then
        iptables -A GOST_TRAFFIC -p tcp --dport $local_port
        iptables -A GOST_TRAFFIC -p udp --dport $local_port
    fi
    
    rebuild_config
    echo -e "${Info} 转发规则已添加"
    sleep 2
}

delete_forward_rule() {
    [ ! -f "$raw_conf_path" ] || [ ! -s "$raw_conf_path" ] && echo -e "${Warning} 暂无转发规则" && sleep 2 && return
    
    read -p "请输入要删除的规则ID: " rule_id
    [[ ! $rule_id =~ ^[0-9]+$ ]] && echo -e "${Error} 无效ID" && sleep 2 && return
    
    local line=$(sed -n "${rule_id}p" "$raw_conf_path")
    [ -z "$line" ] && echo -e "${Error} 规则不存在" && sleep 2 && return
    
    local port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
    
    iptables -D GOST_TRAFFIC -p tcp --dport $port 2>/dev/null
    iptables -D GOST_TRAFFIC -p udp --dport $port 2>/dev/null
    iptables -D INPUT -p tcp --dport $port -j DROP 2>/dev/null
    iptables -D INPUT -p udp --dport $port -j DROP 2>/dev/null
    
    sed -i "${rule_id}d" "$raw_conf_path"
    sed -i "/^${port}:/d" "$remarks_path" "$expires_path" "$limits_path" 2>/dev/null
    
    rebuild_config
    echo -e "${Info} 规则已删除 (端口: ${port})" && sleep 2
}

reset_port_traffic() {
    [ ! -f "$raw_conf_path" ] || [ ! -s "$raw_conf_path" ] && echo -e "${Warning} 暂无转发规则" && sleep 2 && return
    
    read -p "请输入要重置流量的规则ID: " rule_id
    local line=$(sed -n "${rule_id}p" "$raw_conf_path")
    [ -z "$line" ] && echo -e "${Error} 规则不存在" && sleep 2 && return
    
    local port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
    iptables -D INPUT -p tcp --dport $port -j DROP 2>/dev/null
    iptables -D INPUT -p udp --dport $port -j DROP 2>/dev/null
    iptables -Z GOST_TRAFFIC 2>/dev/null
    
    echo -e "${Info} 端口 ${port} 流量已重置" && sleep 2
}

rebuild_config() {
    if [ ! -f "$raw_conf_path" ] || [ ! -s "$raw_conf_path" ]; then
        echo '{"Debug":false,"Retries":0,"ServeNodes":[]}' > "$gost_conf_path"
    else
        echo '{"Debug":false,"Retries":0,"ServeNodes":[' > "$gost_conf_path"
        local count_line=$(wc -l < "$raw_conf_path")
        local i=1
        while IFS= read -r line; do
            local port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
            local target=$(echo "$line" | cut -d'#' -f2)
            local target_port=$(echo "$line" | cut -d'#' -f3)
            echo -n "\"tcp://:$port/$target:$target_port\",\"udp://:$port/$target:$target_port\"" >> "$gost_conf_path"
            [ "$i" -lt "$count_line" ] && echo "," >> "$gost_conf_path" || echo "" >> "$gost_conf_path"
            ((i++))
        done < "$raw_conf_path"
        echo ']}' >> "$gost_conf_path"
    fi
    systemctl restart gost >/dev/null 2>&1
}

manage_forwards() {
    while true; do
        show_header && show_forwards_list
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
            *) echo -e "${Error} 无效选择" && sleep 1 ;;
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
        echo -e "${Green_font_prefix}5.${Font_color_suffix} 卸载GOST"
        echo -e "${Green_font_prefix}0.${Font_color_suffix} 返回主菜单"
        echo
        read -p "请选择操作: " choice
        
        case $choice in
            1) 
                echo -e "${Info} 服务状态: $(systemctl is-active gost 2>/dev/null || echo '未运行')"
                echo -e "${Info} 开机自启: $(systemctl is-enabled gost 2>/dev/null || echo '未设置')"
                echo -e "${Info} 流量控制: $(iptables -L GOST_TRAFFIC >/dev/null 2>&1 && echo '已启用' || echo '未启用')"
                read -p "按Enter继续..."
                ;;
            2) systemctl start gost && echo -e "${Info} 服务已启动" && sleep 2 ;;
            3) systemctl stop gost && echo -e "${Info} 服务已停止" && sleep 2 ;;
            4) systemctl restart gost && echo -e "${Info} 服务已重启" && sleep 2 ;;
            5)
                read -p "确认卸载GOST？(y/N): " confirm
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    systemctl stop gost 2>/dev/null
                    systemctl disable gost 2>/dev/null
                    iptables -F GOST_TRAFFIC 2>/dev/null
                    iptables -X GOST_TRAFFIC 2>/dev/null
                    rm -f /usr/bin/gost /etc/systemd/system/gost.service /usr/bin/g
                    rm -rf /etc/gost /usr/local/bin/gost-manager.sh /usr/local/bin/gost-monitor.sh
                    rm -f /etc/cron.d/gost-traffic
                    echo -e "${Info} 卸载完成" && exit 0
                fi
                ;;
            0) break ;;
            *) echo -e "${Error} 无效选择" && sleep 1 ;;
        esac
    done
}

main_menu() {
    while true; do
        show_header && get_system_info
        echo -e "${Green_font_prefix}==================== 主菜单 ====================${Font_color_suffix}"
        echo -e "${Green_font_prefix}1.${Font_color_suffix} 转发管理 (规则/到期/流量限制)"
        echo -e "${Green_font_prefix}2.${Font_color_suffix} 系统管理 (服务/状态/卸载)"
        echo -e "${Green_font_prefix}0.${Font_color_suffix} 退出程序"
        echo -e "${Blue_font_prefix}=================================================${Font_color_suffix}"
        echo -e "${Yellow_font_prefix}提示: 使用命令 'g' 可快速打开此面板${Font_color_suffix}"
        echo
        read -p "请选择操作 [0-2]: " choice
        
        case $choice in
            1) manage_forwards ;;
            2) system_management ;;
            0) echo -e "${Info} 感谢使用!" && exit 0 ;;
            *) echo -e "${Error} 无效选择" && sleep 1 ;;
        esac
    done
}

main() {
    check_root
    
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
