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

# 检查是否为一键安装模式
is_oneclick_install() {
    [[ "$0" =~ /dev/fd/ ]] || [[ "$0" == "bash" ]] || [[ "$0" =~ /proc/self/fd/ ]]
}

# 一键安装GOST
install_gost() {
    echo -e "${Info} 开始安装GOST..."
    
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
    
    echo -e "${Info} GOST安装完成"
}

# 创建快捷命令
create_shortcut() {
    echo -e "${Info} 创建快捷命令..."
    
    # 将当前脚本保存到系统路径
    if is_oneclick_install; then
        # 如果是一键安装，需要重新下载脚本
        if wget -q -O /usr/local/bin/gost-manager.sh "https://raw.githubusercontent.com/xmg0828-01/gost/main/gost.sh"; then
            chmod +x /usr/local/bin/gost-manager.sh
        else
            # 下载失败，创建一个调用远程脚本的本地脚本
            cat > /usr/local/bin/gost-manager.sh << 'EOF'
#!/bin/bash
bash <(curl -sSL https://raw.githubusercontent.com/xmg0828-01/gost/main/gost.sh) --menu
EOF
            chmod +x /usr/local/bin/gost-manager.sh
        fi
    else
        # 如果是本地脚本，直接复制
        cp "$0" /usr/local/bin/gost-manager.sh
        chmod +x /usr/local/bin/gost-manager.sh
    fi
    
    # 创建快捷命令
    ln -sf /usr/local/bin/gost-manager.sh /usr/bin/g
    
    echo -e "${Info} 快捷命令 'g' 创建成功"
}

# 初始化配置目录
init_config() {
    mkdir -p /etc/gost
    touch /etc/gost/{rawconf,traffic.log,remarks.txt}
    
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

# 获取总流量 - 改为显示网络接口流量
get_total_traffic() {
    # 尝试从系统网络接口获取流量信息
    if [ -f /proc/net/dev ]; then
        # 获取主网络接口的流量
        local rx_bytes=$(awk '/eth0|ens|enp|wlan/ {rx+=$2} END {print rx+0}' /proc/net/dev)
        local tx_bytes=$(awk '/eth0|ens|enp|wlan/ {tx+=$10} END {print tx+0}' /proc/net/dev)
        local total_bytes=$((rx_bytes + tx_bytes))
        
        if [ "$total_bytes" -gt 1073741824 ]; then
            echo "$(echo "scale=2; $total_bytes/1073741824" | bc 2>/dev/null || echo $((total_bytes/1073741824))) GB"
        elif [ "$total_bytes" -gt 1048576 ]; then
            echo "$(echo "scale=1; $total_bytes/1048576" | bc 2>/dev/null || echo $((total_bytes/1048576))) MB"
        elif [ "$total_bytes" -gt 1024 ]; then
            echo "$(echo "scale=0; $total_bytes/1024" | bc 2>/dev/null || echo $((total_bytes/1024))) KB"
        else
            echo "${total_bytes} B"
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
    
    # 显示系统网络统计信息
    echo -e "${Green_font_prefix}端口\t连接数\t状态\t\t\t目标地址\t\t\t备注${Font_color_suffix}"
    echo "--------------------------------------------------------------------------------"
    
    if [ -f "$raw_conf_path" ] && [ -s "$raw_conf_path" ]; then
        while IFS= read -r line; do
            local port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
            local target=$(echo "$line" | cut -d'#' -f2)
            local target_port=$(echo "$line" | cut -d'#' -f3)
            local remark=$(grep "^${port}:" "$remarks_path" 2>/dev/null | cut -d':' -f2- || echo "无备注")
            
            # 获取端口连接数
            local connections=$(ss -tuln 2>/dev/null | grep ":${port} " | wc -l || echo "0")
            
            # 检查端口状态
            local status="监听中"
            if [ "$connections" -eq 0 ]; then
                if netstat -tuln 2>/dev/null | grep -q ":${port} "; then
                    status="监听中"
                else
                    status="未监听"
                fi
            fi
            
            printf "%s\t%s\t\t%s\t\t\t%s:%s\t\t\t%s\n" "$port" "$connections" "$status" "$target" "$target_port" "$remark"
        done < "$raw_conf_path"
    else
        echo -e "${Warning} 暂无转发规则"
    fi
    
    echo
    echo -e "${Info} 实时流量监控信息:"
    echo -e "  - 连接数: 当前活跃的网络连接数量"
    echo -e "  - 状态: 端口是否正在监听"
    echo -e "  - 监听中: 转发规则正常工作"
    echo -e "  - 未监听: 可能服务未启动或配置有误"
    echo
    echo -e "${Info} 系统网络概况:"
    
    # 显示总体网络统计
    if command -v ss >/dev/null 2>&1; then
        local tcp_connections=$(ss -t 2>/dev/null | grep ESTAB | wc -l || echo "0")
        local udp_connections=$(ss -u 2>/dev/null | wc -l || echo "0")
        echo -e "  - TCP连接数: $tcp_connections"
        echo -e "  - UDP连接数: $udp_connections"
    fi
    
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
    
    case "${1:-}" in
        --menu)
            # 直接进入菜单，不安装
            init_config
            main_menu
            ;;
        *)
            # 检查是否需要安装
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
                # 已安装，检查是否需要创建快捷命令
                if [ ! -f "/usr/bin/g" ]; then
                    create_shortcut
                fi
                init_config
                main_menu
            fi
            ;;
    esac
}

# 运行主程序
main "$@"
