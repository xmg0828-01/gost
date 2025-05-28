#!/bin/bash
# GOST 增强版管理脚本 v2.0.0
# 一键安装: bash <(curl -sSL https://raw.githubusercontent.com/xmg0828-01/gost/main/gost.sh)
# 快捷使用: g

Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Yellow_font_prefix="\033[33m"
Blue_font_prefix="\033[34m" && Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Warning="${Yellow_font_prefix}[警告]${Font_color_suffix}"
shell_version="2.0.0"
ct_new_ver="2.11.5"

# 配置文件路径
gost_conf_path="/etc/gost/config.json"
raw_conf_path="/etc/gost/rawconf"
traffic_log_path="/etc/gost/traffic.log"
remarks_path="/etc/gost/remarks.txt"

# 检查root权限
check_root() {
    [[ $EUID != 0 ]] && echo -e "${Error} 请使用root权限运行此脚本" && exit 1
}

# 检测系统和架构
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

# 一键安装GOST
one_click_install() {
    echo -e "${Info} 开始一键安装GOST..."
    
    detect_environment
    
    # 安装依赖
    if [[ $release == "centos" ]]; then
        yum install -y wget curl >/dev/null 2>&1
    else
        apt-get update >/dev/null 2>&1
        apt-get install -y wget curl >/dev/null 2>&1
    fi
    
    # 下载GOST
    cd /tmp
    if ! wget -q -O gost.gz "https://github.com/ginuerzh/gost/releases/download/v${ct_new_ver}/gost-linux-${arch}-${ct_new_ver}.gz"; then
        wget -q -O gost.gz "https://mirror.ghproxy.com/https://github.com/ginuerzh/gost/releases/download/v${ct_new_ver}/gost-linux-${arch}-${ct_new_ver}.gz"
    fi
    
    gunzip gost.gz
    chmod +x gost
    mv gost /usr/bin/gost
    
    # 创建服务
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
    
    # 初始化配置
    mkdir -p /etc/gost
    touch /etc/gost/{rawconf,traffic.log,remarks.txt}
    
    cat > /etc/gost/config.json << 'EOF'
{
    "Debug": false,
    "Retries": 0,
    "ServeNodes": []
}
EOF
    
    # 创建快捷命令
    cp "$0" /usr/local/bin/gost-manager.sh 2>/dev/null || {
        cat > /usr/local/bin/gost-manager.sh << 'SCRIPT_END'
#!/bin/bash
bash <(curl -sSL https://raw.githubusercontent.com/xmg0828-01/gost/main/gost.sh) --local
SCRIPT_END
    }
    
    chmod +x /usr/local/bin/gost-manager.sh
    ln -sf /usr/local/bin/gost-manager.sh /usr/bin/g
    
    echo -e "${Info} GOST安装完成！使用 'g' 命令打开管理面板"
    sleep 2
}

# 显示标题
show_header() {
    clear
    echo -e "${Blue_font_prefix}======================================================${Font_color_suffix}"
    echo -e "${Green_font_prefix}            GOST 增强版管理面板 v${shell_version}${Font_color_suffix}"
    echo -e "${Blue_font_prefix}======================================================${Font_color_suffix}"
    echo -e "${Yellow_font_prefix}功能: 流量监控 | 转发备注 | 系统管理${Font_color_suffix}"
    echo -e "${Blue_font_prefix}======================================================${Font_color_suffix}"
    echo
}

# 获取系统信息
get_system_info() {
    if command -v gost >/dev/null 2>&1; then
        gost_status=$(systemctl is-active gost 2>/dev/null || echo "未运行")
        gost_version=$(gost -V 2>/dev/null | awk '{print $2}' || echo "未知")
    else
        gost_status="未安装"
        gost_version="未安装"
    fi
    
    active_rules=$(wc -l < "$raw_conf_path" 2>/dev/null || echo "0")
    total_traffic=$(get_total_traffic)
    
    echo -e "${Info} 服务状态: ${gost_status} | 版本: ${gost_version}"
    echo -e "${Info} 活跃规则: ${active_rules} | 总流量: ${total_traffic}"
    echo
}

# 获取总流量
get_total_traffic() {
    if [ -f "$traffic_log_path" ] && [ -s "$traffic_log_path" ]; then
        total_bytes=$(awk '{sum+=$3} END {print sum+0}' "$traffic_log_path")
        if [ "$total_bytes" -gt 1073741824 ]; then
            echo "$(( total_bytes / 1073741824 )) GB"
        elif [ "$total_bytes" -gt 1048576 ]; then
            echo "$(( total_bytes / 1048576 )) MB"
        else
            echo "$(( total_bytes / 1024 )) KB"
        fi
    else
        echo "0 KB"
    fi
}

# 显示转发规则
show_forwards_list() {
    echo -e "${Blue_font_prefix}=================== 转发规则 ===================${Font_color_suffix}"
    if [ ! -f "$raw_conf_path" ] || [ ! -s "$raw_conf_path" ]; then
        echo -e "${Warning} 暂无转发规则"
        echo
        return
    fi

    echo -e "${Green_font_prefix}ID\t类型\t\t本地端口\t目标地址\t\t备注${Font_color_suffix}"
    echo "----------------------------------------------------------------"
    
    local id=1
    while IFS= read -r line; do
        local type=$(echo "$line" | cut -d'/' -f1)
        local port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
        local target=$(echo "$line" | cut -d'#' -f2)
        local target_port=$(echo "$line" | cut -d'#' -f3)
        local remark=$(grep "^${port}:" "$remarks_path" 2>/dev/null | cut -d':' -f2- || echo "无备注")
        
        case $type in
            "nonencrypt") type_display="TCP+UDP" ;;
            *) type_display="$type" ;;
        esac
        
        printf "%d\t%s\t\t%s\t\t%s:%s\t\t%s\n" "$id" "$type_display" "$port" "$target" "$target_port" "$remark"
        ((id++))
    done < "$raw_conf_path"
    echo
}

# 显示流量统计
show_traffic_stats() {
    echo -e "${Blue_font_prefix}==================== 流量统计 ====================${Font_color_suffix}"
    if [ ! -f "$traffic_log_path" ] || [ ! -s "$traffic_log_path" ]; then
        echo -e "${Warning} 暂无流量数据"
        echo
        return
    fi

    echo -e "${Green_font_prefix}端口\t今日流量\t总流量\t\t备注${Font_color_suffix}"
    echo "------------------------------------------------"
    
    # 统计各端口流量
    for port in $(awk '{print $2}' "$traffic_log_path" | sort -n | uniq); do
        local total_mb=$(awk -v p="$port" '$2==p {sum+=$3} END {print int(sum/1048576)}' "$traffic_log_path")
        local today_mb=$(awk -v p="$port" -v today="$(date +%Y-%m-%d)" '$1==today && $2==p {sum+=$3} END {print int(sum/1048576)}' "$traffic_log_path")
        local remark=$(grep "^${port}:" "$remarks_path" 2>/dev/null | cut -d':' -f2- || echo "无备注")
        
        printf "%s\t%dMB\t\t%dMB\t\t%s\n" "$port" "$today_mb" "$total_mb" "$remark"
    done
    echo
}

# 添加转发规则
add_forward_rule() {
    echo -e "${Info} 添加TCP+UDP转发规则"
    read -p "本地监听端口: " local_port
    read -p "目标IP地址: " target_ip  
    read -p "目标端口: " target_port
    read -p "备注信息 (可选): " remark
    
    if [[ ! $local_port =~ ^[0-9]+$ ]] || [[ ! $target_port =~ ^[0-9]+$ ]]; then
        echo -e "${Error} 端口必须为数字"
        sleep 2
        return
    fi
    
    if grep -q "/${local_port}#" "$raw_conf_path" 2>/dev/null; then
        echo -e "${Error} 端口 $local_port 已被使用"
        sleep 2
        return
    fi
    
    echo "nonencrypt/${local_port}#${target_ip}#${target_port}" >> "$raw_conf_path"
    [ -n "$remark" ] && echo "${local_port}:${remark}" >> "$remarks_path"
    
    rebuild_config
    echo -e "${Info} 转发规则已添加"
    sleep 2
}

# 删除转发规则
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
    sed -i "${rule_id}d" "$raw_conf_path"
    sed -i "/^${port}:/d" "$remarks_path" 2>/dev/null
    
    rebuild_config
    echo -e "${Info} 规则已删除"
    sleep 2
}

# 编辑备注
edit_remark() {
    if [ ! -f "$raw_conf_path" ] || [ ! -s "$raw_conf_path" ]; then
        echo -e "${Warning} 暂无转发规则"
        sleep 2
        return
    fi
    
    read -p "请输入要编辑备注的规则ID: " rule_id
    
    local line=$(sed -n "${rule_id}p" "$raw_conf_path")
    if [ -z "$line" ]; then
        echo -e "${Error} 规则ID不存在"
        sleep 2
        return
    fi
    
    local port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
    local current_remark=$(grep "^${port}:" "$remarks_path" 2>/dev/null | cut -d':' -f2- || echo "")
    
    echo -e "${Info} 当前备注: ${current_remark:-无}"
    read -p "请输入新的备注信息: " new_remark
    
    sed -i "/^${port}:/d" "$remarks_path" 2>/dev/null
    [ -n "$new_remark" ] && echo "${port}:${new_remark}" >> "$remarks_path"
    
    echo -e "${Info} 备注已更新"
    sleep 2
}

# 重建配置
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

# 转发管理
manage_forwards() {
    while true; do
        show_header
        show_forwards_list
        echo -e "${Green_font_prefix}=================== 转发管理 ===================${Font_color_suffix}"
        echo -e "${Green_font_prefix}1.${Font_color_suffix} 新增转发规则"
        echo -e "${Green_font_prefix}2.${Font_color_suffix} 删除转发规则"
        echo -e "${Green_font_prefix}3.${Font_color_suffix} 编辑转发备注"
        echo -e "${Green_font_prefix}4.${Font_color_suffix} 查看流量统计"
        echo -e "${Green_font_prefix}5.${Font_color_suffix} 重启GOST服务"
        echo -e "${Green_font_prefix}0.${Font_color_suffix} 返回主菜单"
        echo
        read -p "请选择操作: " choice
        
        case $choice in
            1) add_forward_rule ;;
            2) delete_forward_rule ;;
            3) edit_remark ;;
            4) show_traffic_stats && read -p "按Enter继续..." ;;
            5) systemctl restart gost && echo -e "${Info} 服务已重启" && sleep 2 ;;
            0) break ;;
            *) echo -e "${Error} 无效选择" && sleep 2 ;;
        esac
    done
}

# 系统管理
system_management() {
    while true; do
        show_header
        echo -e "${Green_font_prefix}=================== 系统管理 ===================${Font_color_suffix}"
        echo -e "${Green_font_prefix}1.${Font_color_suffix} 查看服务状态"
        echo -e "${Green_font_prefix}2.${Font_color_suffix} 启动GOST服务"
        echo -e "${Green_font_prefix}3.${Font_color_suffix} 停止GOST服务"
        echo -e "${Green_font_prefix}4.${Font_color_suffix} 重启GOST服务"
        echo -e "${Green_font_prefix}5.${Font_color_suffix} 查看服务日志"
        echo -e "${Green_font_prefix}6.${Font_color_suffix} 卸载GOST"
        echo -e "${Green_font_prefix}0.${Font_color_suffix} 返回主菜单"
        echo
        read -p "请选择操作: " choice
        
        case $choice in
            1) 
                echo -e "${Info} 服务状态: $(systemctl is-active gost 2>/dev/null || echo '未运行')"
                echo -e "${Info} 开机自启: $(systemctl is-enabled gost 2>/dev/null || echo '未设置')"
                read -p "按Enter继续..."
                ;;
            2) systemctl start gost && echo -e "${Info} 服务已启动" && sleep 2 ;;
            3) systemctl stop gost && echo -e "${Info} 服务已停止" && sleep 2 ;;
            4) systemctl restart gost && echo -e "${Info} 服务已重启" && sleep 2 ;;
            5) 
                echo -e "${Info} 最近10条日志:"
                journalctl -u gost -n 10 --no-pager 2>/dev/null || echo "无法获取日志"
                read -p "按Enter继续..."
                ;;
            6)
                read -p "确认卸载GOST？(y/N): " confirm
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    systemctl stop gost 2>/dev/null
                    systemctl disable gost 2>/dev/null
                    rm -f /usr/bin/gost /etc/systemd/system/gost.service /usr/bin/g
                    rm -rf /etc/gost /usr/local/bin/gost-manager.sh
                    echo -e "${Info} 卸载完成"
                    exit 0
                fi
                ;;
            0) break ;;
            *) echo -e "${Error} 无效选择" && sleep 2 ;;
        esac
    done
}

# 主菜单
main_menu() {
    while true; do
        show_header
        get_system_info
        echo -e "${Green_font_prefix}==================== 主菜单 ====================${Font_color_suffix}"
        echo -e "${Green_font_prefix}1.${Font_color_suffix} 转发管理 (规则/流量/备注)"
        echo -e "${Green_font_prefix}2.${Font_color_suffix} 流量统计 (实时监控)"
        echo -e "${Green_font_prefix}3.${Font_color_suffix} 系统管理 (服务/状态/日志)"
        echo -e "${Green_font_prefix}0.${Font_color_suffix} 退出程序"
        echo -e "${Blue_font_prefix}=================================================${Font_color_suffix}"
        echo -e "${Yellow_font_prefix}提示: 使用命令 'g' 可快速打开此面板${Font_color_suffix}"
        echo
        read -p "请选择操作 [0-3]: " choice
        
        case $choice in
            1) manage_forwards ;;
            2) show_traffic_stats && read -p "按Enter继续..." ;;
            3) system_management ;;
            0) echo -e "${Info} 感谢使用!" && exit 0 ;;
            *) echo -e "${Error} 无效选择" && sleep 2 ;;
        esac
    done
}

# 主程序
main() {
    check_root
    
    # 检测是否为一键安装
    if [[ "$0" =~ /dev/fd/ ]] || [[ "$0" == "bash" ]] || [[ ! -f "/usr/bin/gost" && "$1" != "--local" ]]; then
        one_click_install
    fi
    
    # 确保目录存在
    mkdir -p /etc/gost
    touch /etc/gost/{rawconf,traffic.log,remarks.txt}
    
    main_menu
}

# 运行主程序
main "$@"
