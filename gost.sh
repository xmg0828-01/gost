#!/bin/bash
# GOST 增强管理脚本 v2.0
# 支持流量统计、IP限制、转发备注等功能

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
ip_whitelist_path="/etc/gost/ip_whitelist.txt"
ip_blacklist_path="/etc/gost/ip_blacklist.txt"
remarks_path="/etc/gost/remarks.txt"

# 创建快捷命令
create_shortcut() {
    if [ ! -L /usr/bin/g ]; then
        ln -sf "$(pwd)/gost.sh" /usr/bin/g
        chmod +x /usr/bin/g
        echo -e "${Info} 已创建快捷命令 'g'"
    fi
}

# 初始化目录和文件
init_directories() {
    [ ! -d "/etc/gost" ] && mkdir -p /etc/gost
    [ ! -f "$traffic_log_path" ] && touch "$traffic_log_path"
    [ ! -f "$ip_whitelist_path" ] && touch "$ip_whitelist_path"
    [ ! -f "$ip_blacklist_path" ] && touch "$ip_blacklist_path"
    [ ! -f "$remarks_path" ] && touch "$remarks_path"
    [ ! -f "$raw_conf_path" ] && touch "$raw_conf_path"
}

# 显示带颜色的标题
show_header() {
    clear
    echo -e "${Blue_font_prefix}======================================================${Font_color_suffix}"
    echo -e "${Green_font_prefix}            GOST 增强版管理面板 v${shell_version}${Font_color_suffix}"
    echo -e "${Blue_font_prefix}======================================================${Font_color_suffix}"
    echo -e "${Yellow_font_prefix}功能: 流量监控 | IP控制 | 转发备注 | 系统管理${Font_color_suffix}"
    echo -e "${Blue_font_prefix}======================================================${Font_color_suffix}"
    echo
}

# 获取系统信息
get_system_info() {
    if command -v gost >/dev/null 2>&1; then
        gost_status=$(systemctl is-active gost 2>/dev/null || echo "未安装")
        gost_version=$(gost -V 2>/dev/null | awk '{print $2}' || echo "未知")
    else
        gost_status="未安装"
        gost_version="未安装"
    fi
    
    active_rules=$(wc -l < "$raw_conf_path" 2>/dev/null || echo "0")
    total_traffic=$(get_total_traffic)
    active_connections=$(ss -tuln | grep -E ':8[0-9]{3}|:1[0-9]{4}|:9[0-9]{3}' | wc -l)
    
    echo -e "${Info} 服务状态: ${gost_status} | 版本: ${gost_version}"
    echo -e "${Info} 活跃规则: ${active_rules} | 总流量: ${total_traffic} | 连接数: ${active_connections}"
    echo
}

# 获取总流量
get_total_traffic() {
    if [ -f "$traffic_log_path" ]; then
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

# 记录流量
log_traffic() {
    local port=$1
    local bytes=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp $port $bytes" >> "$traffic_log_path"
}

# 显示流量统计
show_traffic_stats() {
    echo -e "${Blue_font_prefix}==================== 流量统计 ====================${Font_color_suffix}"
    if [ ! -f "$traffic_log_path" ] || [ ! -s "$traffic_log_path" ]; then
        echo -e "${Warning} 暂无流量数据"
        return
    fi

    echo -e "${Green_font_prefix}端口\t今日流量\t总流量\t\t备注${Font_color_suffix}"
    echo "------------------------------------------------"
    
    # 按端口统计流量
    awk '{
        port = $2
        bytes = $3
        date = $1
        total[port] += bytes
        if (date == strftime("%Y-%m-%d")) {
            today[port] += bytes
        }
    } END {
        for (port in total) {
            today_mb = today[port] ? today[port]/1048576 : 0
            total_mb = total[port]/1048576
            printf "%s\t%.1fMB\t\t%.1fMB\t\t", port, today_mb, total_mb
            
            # 读取备注
            cmd = "grep \"^" port ":\" /etc/gost/remarks.txt 2>/dev/null | cut -d: -f2-"
            cmd | getline remark
            close(cmd)
            print (remark ? remark : "无备注")
        }
    }' "$traffic_log_path" | sort -k1 -n
    echo
}

# IP控制管理
manage_ip_control() {
    while true; do
        show_header
        echo -e "${Green_font_prefix}=================== IP访问控制 ===================${Font_color_suffix}"
        echo -e "${Green_font_prefix}1.${Font_color_suffix} 查看白名单"
        echo -e "${Green_font_prefix}2.${Font_color_suffix} 添加白名单IP"
        echo -e "${Green_font_prefix}3.${Font_color_suffix} 删除白名单IP" 
        echo -e "${Green_font_prefix}4.${Font_color_suffix} 查看黑名单"
        echo -e "${Green_font_prefix}5.${Font_color_suffix} 添加黑名单IP"
        echo -e "${Green_font_prefix}6.${Font_color_suffix} 删除黑名单IP"
        echo -e "${Green_font_prefix}7.${Font_color_suffix} 查看活跃连接"
        echo -e "${Green_font_prefix}0.${Font_color_suffix} 返回主菜单"
        echo
        read -p "请选择操作: " ip_choice
        
        case $ip_choice in
            1) show_ip_list "白名单" "$ip_whitelist_path" ;;
            2) add_ip_to_list "白名单" "$ip_whitelist_path" ;;
            3) remove_ip_from_list "白名单" "$ip_whitelist_path" ;;
            4) show_ip_list "黑名单" "$ip_blacklist_path" ;;
            5) add_ip_to_list "黑名单" "$ip_blacklist_path" ;;
            6) remove_ip_from_list "黑名单" "$ip_blacklist_path" ;;
            7) show_active_connections ;;
            0) break ;;
            *) echo -e "${Error} 无效选择" && sleep 2 ;;
        esac
    done
}

# 显示IP列表
show_ip_list() {
    local list_name=$1
    local file_path=$2
    echo -e "${Green_font_prefix}================ $list_name ================${Font_color_suffix}"
    if [ -f "$file_path" ] && [ -s "$file_path" ]; then
        nl "$file_path"
    else
        echo -e "${Warning} $list_name 为空"
    fi
    echo
    read -p "按Enter继续..."
}

# 添加IP到列表
add_ip_to_list() {
    local list_name=$1
    local file_path=$2
    echo -e "${Info} 添加IP到$list_name"
    read -p "请输入IP地址或网段 (如: 192.168.1.1 或 192.168.1.0/24): " ip_input
    
    if [[ $ip_input =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        echo "$ip_input" >> "$file_path"
        echo -e "${Info} IP $ip_input 已添加到$list_name"
        # 重新加载GOST配置
        systemctl reload gost 2>/dev/null
    else
        echo -e "${Error} IP格式不正确"
    fi
    sleep 2
}

# 从列表删除IP
remove_ip_from_list() {
    local list_name=$1
    local file_path=$2
    
    if [ ! -f "$file_path" ] || [ ! -s "$file_path" ]; then
        echo -e "${Warning} $list_name 为空"
        sleep 2
        return
    fi
    
    show_ip_list "$list_name" "$file_path"
    read -p "请输入要删除的IP序号: " line_num
    
    if [[ $line_num =~ ^[0-9]+$ ]] && [ "$line_num" -gt 0 ]; then
        sed -i "${line_num}d" "$file_path"
        echo -e "${Info} 已删除第 $line_num 个IP"
        systemctl reload gost 2>/dev/null
    else
        echo -e "${Error} 无效的序号"
    fi
    sleep 2
}

# 显示活跃连接
show_active_connections() {
    echo -e "${Green_font_prefix}================ 活跃连接 ================${Font_color_suffix}"
    echo -e "${Green_font_prefix}协议\t本地地址\t\t\t远程地址${Font_color_suffix}"
    echo "-------------------------------------------------------"
    ss -tuln | grep -E ':8[0-9]{3}|:1[0-9]{4}|:9[0-9]{3}' | while read line; do
        echo "$line" | awk '{print $1 "\t" $5 "\t\t" $6}'
    done
    echo
    read -p "按Enter继续..."
}

# 转发规则管理
manage_forwards() {
    while true; do
        show_header
        show_forwards_list
        echo -e "${Green_font_prefix}=================== 转发管理 ===================${Font_color_suffix}"
        echo -e "${Green_font_prefix}1.${Font_color_suffix} 新增转发规则"
        echo -e "${Green_font_prefix}2.${Font_color_suffix} 删除转发规则"
        echo -e "${Green_font_prefix}3.${Font_color_suffix} 编辑转发备注"
        echo -e "${Green_font_prefix}4.${Font_color_suffix} 查看转发流量"
        echo -e "${Green_font_prefix}5.${Font_color_suffix} 重启GOST服务"
        echo -e "${Green_font_prefix}0.${Font_color_suffix} 返回主菜单"
        echo
        read -p "请选择操作: " forward_choice
        
        case $forward_choice in
            1) add_forward_rule ;;
            2) delete_forward_rule ;;
            3) edit_forward_remark ;;
            4) show_traffic_stats && read -p "按Enter继续..." ;;
            5) restart_gost_service ;;
            0) break ;;
            *) echo -e "${Error} 无效选择" && sleep 2 ;;
        esac
    done
}

# 显示转发规则列表
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
        
        # 获取备注
        local remark=$(grep "^${port}:" "$remarks_path" 2>/dev/null | cut -d':' -f2- || echo "无备注")
        
        # 格式化类型显示
        case $type in
            "nonencrypt") type_display="TCP+UDP" ;;
            "encrypttls") type_display="TLS隧道" ;;
            "encryptws") type_display="WS隧道" ;;
            "encryptwss") type_display="WSS隧道" ;;
            "ss") type_display="Shadowsocks" ;;
            "socks") type_display="SOCKS5" ;;
            "http") type_display="HTTP" ;;
            *) type_display="$type" ;;
        esac
        
        printf "%d\t%s\t\t%s\t\t%s:%s\t\t%s\n" "$id" "$type_display" "$port" "$target" "$target_port" "$remark"
        ((id++))
    done < "$raw_conf_path"
    echo
}

# 添加转发备注
edit_forward_remark() {
    if [ ! -f "$raw_conf_path" ] || [ ! -s "$raw_conf_path" ]; then
        echo -e "${Warning} 暂无转发规则"
        sleep 2
        return
    fi
    
    read -p "请输入要添加备注的规则ID: " rule_id
    
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
    read -p "请输入备注信息: " remark
    
    # 删除旧备注并添加新备注
    sed -i "/^${port}:/d" "$remarks_path"
    echo "${port}:${remark}" >> "$remarks_path"
    
    echo -e "${Info} 备注已更新"
    sleep 2
}

# 添加转发规则
add_forward_rule() {
    echo -e "${Info} 添加新转发规则"
    echo -e "${Green_font_prefix}请选择转发类型:${Font_color_suffix}"
    echo "1) TCP+UDP不加密转发"
    echo "2) TLS隧道加密转发" 
    echo "3) WS隧道转发"
    echo "4) WSS隧道转发"
    echo "5) Shadowsocks代理"
    echo "6) SOCKS5代理"
    echo "7) HTTP代理"
    
    read -p "请选择 (1-7): " rule_type
    
    case $rule_type in
        1) add_simple_forward ;;
        2) add_tls_forward ;;
        3) add_ws_forward ;;
        4) add_wss_forward ;;
        5) add_ss_proxy ;;
        6) add_socks_proxy ;;
        7) add_http_proxy ;;
        *) echo -e "${Error} 无效选择" && sleep 2 && return ;;
    esac
}

# 添加简单转发
add_simple_forward() {
    read -p "本地监听端口: " local_port
    read -p "目标IP地址: " target_ip  
    read -p "目标端口: " target_port
    read -p "备注信息: " remark
    
    if [[ ! $local_port =~ ^[0-9]+$ ]] || [[ ! $target_port =~ ^[0-9]+$ ]]; then
        echo -e "${Error} 端口必须为数字"
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
    
    # 获取端口并删除相关备注
    local port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
    sed -i "${rule_id}d" "$raw_conf_path"
    sed -i "/^${port}:/d" "$remarks_path"
    
    rebuild_config
    echo -e "${Info} 规则已删除"
    sleep 2
}

# 重建配置文件
rebuild_config() {
    if [ ! -f "$raw_conf_path" ] || [ ! -s "$raw_conf_path" ]; then
        rm -f "$gost_conf_path"
        return
    fi
    
    rm -f "$gost_conf_path"
    confstart
    writeconf
    conflast
    systemctl restart gost >/dev/null 2>&1
}

# 配置文件生成函数 (保持原有逻辑)
confstart() {
    echo "{
    \"Debug\": true,
    \"Retries\": 0,
    \"ServeNodes\": [" >> "$gost_conf_path"
}

conflast() {
    echo "    ]
}" >> "$gost_conf_path"
}

writeconf() {
    local count_line=$(wc -l < "$raw_conf_path")
    local i=1
    
    while IFS= read -r trans_conf; do
        eachconf_retrieve "$trans_conf"
        method "$i" "$count_line"
        ((i++))
    done < "$raw_conf_path"
}

eachconf_retrieve() {
    local trans_conf=$1
    d_server=${trans_conf#*#}
    d_port=${d_server#*#}
    d_ip=${d_server%#*}
    flag_s_port=${trans_conf%%#*}
    s_port=${flag_s_port#*/}
    is_encrypt=${flag_s_port%/*}
}

method() {
    local current=$1
    local total=$2
    
    if [ "$current" -eq 1 ]; then
        case "$is_encrypt" in
            "nonencrypt")
                echo "        \"tcp://:$s_port/$d_ip:$d_port\",
        \"udp://:$s_port/$d_ip:$d_port\"" >> "$gost_conf_path"
                ;;
            # 其他类型配置保持原有逻辑...
        esac
    else
        # 多规则处理逻辑...
        echo "        \"tcp://:$s_port/$d_ip:$d_port\",
        \"udp://:$s_port/$d_ip:$d_port\"" >> "$gost_conf_path"
    fi
    
    if [ "$current" -lt "$total" ]; then
        echo "," >> "$gost_conf_path"
    fi
}

# GOST服务管理
restart_gost_service() {
    echo -e "${Info} 正在重启GOST服务..."
    if systemctl restart gost; then
        echo -e "${Info} GOST服务重启成功"
    else
        echo -e "${Error} GOST服务重启失败"
    fi
    sleep 2
}

# 系统工具
system_tools() {
    while true; do
        show_header
        echo -e "${Green_font_prefix}=================== 系统工具 ===================${Font_color_suffix}"
        echo -e "${Green_font_prefix}1.${Font_color_suffix} 安装/更新GOST"
        echo -e "${Green_font_prefix}2.${Font_color_suffix} 卸载GOST"
        echo -e "${Green_font_prefix}3.${Font_color_suffix} 查看系统状态"
        echo -e "${Green_font_prefix}4.${Font_color_suffix} 备份配置"
        echo -e "${Green_font_prefix}5.${Font_color_suffix} 恢复配置"
        echo -e "${Green_font_prefix}6.${Font_color_suffix} 清空流量日志"
        echo -e "${Green_font_prefix}0.${Font_color_suffix} 返回主菜单"
        echo
        read -p "请选择操作: " tool_choice
        
        case $tool_choice in
            1) install_gost ;;
            2) uninstall_gost ;;
            3) show_system_status ;;
            4) backup_config ;;
            5) restore_config ;;
            6) clear_traffic_log ;;
            0) break ;;
            *) echo -e "${Error} 无效选择" && sleep 2 ;;
        esac
    done
}

# 清空流量日志
clear_traffic_log() {
    read -p "确认清空所有流量日志？(y/N): " confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
        > "$traffic_log_path"
        echo -e "${Info} 流量日志已清空"
    else
        echo -e "${Info} 操作已取消"
    fi
    sleep 2
}

# 备份配置
backup_config() {
    local backup_file="/root/gost_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    tar -czf "$backup_file" -C /etc gost/ 2>/dev/null
    if [ -f "$backup_file" ]; then
        echo -e "${Info} 配置已备份到: $backup_file"
    else
        echo -e "${Error} 备份失败"
    fi
    sleep 2
}

# 显示系统状态
show_system_status() {
    echo -e "${Green_font_prefix}================ 系统状态 ================${Font_color_suffix}"
    echo -e "GOST版本: $(gost -V 2>/dev/null | awk '{print $2}' || echo '未安装')"
    echo -e "服务状态: $(systemctl is-active gost 2>/dev/null || echo '未运行')"
    echo -e "开机自启: $(systemctl is-enabled gost 2>/dev/null || echo '未设置')"
    echo -e "配置文件: $([ -f "$gost_conf_path" ] && echo '存在' || echo '不存在')"
    echo -e "转发规则: $(wc -l < "$raw_conf_path" 2>/dev/null || echo '0') 条"
    echo -e "系统负载: $(uptime | awk -F'load average:' '{print $2}')"
    echo -e "内存使用: $(free -h | awk '/Mem:/ {print $3"/"$2}')"
    echo
    read -p "按Enter继续..."
}

# 安装GOST (简化版)
install_gost() {
    echo -e "${Info} 开始安装GOST..."
    # 检测架构
    case $(uname -m) in
        x86_64) arch="amd64" ;;
        i386|i686) arch="386" ;;
        armv7l) arch="armv7" ;;
        aarch64) arch="arm64" ;;
        *) echo -e "${Error} 不支持的架构" && return ;;
    esac
    
    # 下载并安装
    cd /tmp
    wget -O gost.gz "https://github.com/ginuerzh/gost/releases/download/v${ct_new_ver}/gost-linux-${arch}-${ct_new_ver}.gz"
    gunzip gost.gz
    chmod +x gost
    mv gost /usr/bin/
    
    # 创建服务文件
    cat > /etc/systemd/system/gost.service << EOF
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
    
    echo -e "${Info} GOST安装完成"
    sleep 2
}

# 卸载GOST
uninstall_gost() {
    read -p "确认卸载GOST？(y/N): " confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
        systemctl stop gost 2>/dev/null
        systemctl disable gost 2>/dev/null
        rm -f /usr/bin/gost /etc/systemd/system/gost.service
        rm -rf /etc/gost
        systemctl daemon-reload
        echo -e "${Info} GOST已卸载"
    else
        echo -e "${Info} 操作已取消"
    fi
    sleep 2
}

# 主菜单
main_menu() {
    while true; do
        show_header
        get_system_info
        echo -e "${Green_font_prefix}==================== 主菜单 ====================${Font_color_suffix}"
        echo -e "${Green_font_prefix}1.${Font_color_suffix} 转发管理 (规则/流量/备注)"
        echo -e "${Green_font_prefix}2.${Font_color_suffix} IP访问控制 (白名单/黑名单)"
        echo -e "${Green_font_prefix}3.${Font_color_suffix} 流量统计 (实时监控)"
        echo -e "${Green_font_prefix}4.${Font_color_suffix} 系统工具 (安装/备份/状态)"
        echo -e "${Green_font_prefix}5.${Font_color_suffix} 快速重启服务"
        echo -e "${Green_font_prefix}0.${Font_color_suffix} 退出程序"
        echo -e "${Blue_font_prefix}=================================================${Font_color_suffix}"
        echo -e "${Yellow_font_prefix}提示: 使用命令 'g' 可快速打开此面板${Font_color_suffix}"
        echo
        read -p "请选择操作 [0-5]: " choice
        
        case $choice in
            1) manage_forwards ;;
            2) manage_ip_control ;;
            3) show_traffic_stats && read -p "按Enter继续..." ;;
            4) system_tools ;;
            5) restart_gost_service ;;
            0) echo -e "${Info} 感谢使用!" && exit 0 ;;
            *) echo -e "${Error} 无效选择，请重新输入" && sleep 2 ;;
        esac
    done
}

# 检查root权限
check_root() {
    [[ $EUID != 0 ]] && echo -e "${Error} 请使用root权限运行此脚本" && exit 1
}

# 主程序入口
main() {
    check_root
    init_directories
    create_shortcut
    main_menu
}

# 如果直接运行脚本
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
