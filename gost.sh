#!/bin/bash
# GOST 简化版管理脚本 v2.3.0 - 仅包含到期管理功能
# 一键安装: bash <(curl -sSL https://raw.githubusercontent.com/xmg0828-01/gost/main/gost.sh)
# 快捷使用: g

Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Yellow_font_prefix="\033[33m"
Blue_font_prefix="\033[34m" && Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Warning="${Yellow_font_prefix}[警告]${Font_color_suffix}"
shell_version="2.3.0"
ct_new_ver="2.11.5"   # 默认安装/回退版本（2.x 分支稳定版）

gost_conf_path="/etc/gost/config.json"
raw_conf_path="/etc/gost/rawconf"
remarks_path="/etc/gost/remarks.txt"
expires_path="/etc/gost/expires.txt"

check_root() { [[ $EUID != 0 ]] && echo -e "${Error} 请使用root权限运行此脚本" && exit 1; }

detect_environment() {
    if [[ -f /etc/redhat-release ]]; then
        release="centos"
    elif cat /etc/issue | grep -q -E -i "debian|ubuntu"; then
        release="debian"
    else
        release="debian"
    fi
    case $(uname -m) in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) arch="amd64" ;;
    esac
}

is_oneclick_install() { [[ "$0" =~ /dev/fd/ ]] || [[ "$0" == "bash" ]] || [[ "$0" =~ /proc/self/fd/ ]]; }

install_gost() {
    echo -e "${Info} 开始安装GOST..."
    detect_environment
    # 基础工具
    echo -e "${Info} 安装基础工具..."
    if [[ $release == "centos" ]]; then
        yum install -y wget curl gzip >/dev/null 2>&1
    else
        apt-get update -y >/dev/null 2>&1
        apt-get install -y wget curl gzip >/dev/null 2>&1
    fi
    # 下载GOST（2.x 老仓库，和你现有配置兼容）
    cd /tmp || exit 1
    echo -e "${Info} 下载GOST程序..."
    if ! wget -q --timeout=30 -O gost.gz "https://github.com/ginuerzh/gost/releases/download/v${ct_new_ver}/gost-linux-${arch}-${ct_new_ver}.gz"; then
        echo -e "${Info} 使用镜像源下载..."
        if ! wget -q --timeout=30 -O gost.gz "https://mirror.ghproxy.com/https://github.com/ginuerzh/gost/releases/download/v${ct_new_ver}/gost-linux-${arch}-${ct_new_ver}.gz"; then
            echo -e "${Error} GOST下载失败"; exit 1
        fi
    fi
    gunzip -f gost.gz
    install -m 0755 gost /usr/bin/gost

    # systemd
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
    systemctl enable gost >/dev/null 2>&1

    # 到期检查
    cat > /usr/local/bin/gost-expire-check.sh << 'EOF'
#!/bin/bash
EXPIRES_FILE="/etc/gost/expires.txt"
RAW_CONF="/etc/gost/rawconf"
GOST_CONF="/etc/gost/config.json"
[ ! -f "$EXPIRES_FILE" ] && exit 0
current_time=$(date +%s)
expired_ports=""
while IFS=: read -r port expire_date; do
  [ -z "$port" ] && continue
  if [ "$expire_date" != "永久" ] && [ "$expire_date" -lt "$current_time" ]; then
    expired_ports="$expired_ports $port"
  fi
done < "$EXPIRES_FILE"
if [ -n "$expired_ports" ]; then
  for port in $expired_ports; do
    sed -i "/\/${port}#/d" "$RAW_CONF"
    sed -i "/^${port}:/d" "$EXPIRES_FILE"
    sed -i "/^${port}:/d" "/etc/gost/remarks.txt"
    echo "[$(date)] 端口 $port 的转发规则已过期并删除" >> /var/log/gost.log
  done
  bash -c 'source /usr/local/bin/gost-manager.sh && rebuild_config'
fi
EOF
    chmod +x /usr/local/bin/gost-expire-check.sh
    echo "0 2 * * * root /usr/local/bin/gost-expire-check.sh >/dev/null 2>&1" > /etc/cron.d/gost-expire
    echo -e "${Info} GOST安装完成"
}

# ======== 新增：获取 2.x 老仓库最新 tag（失败回退 ct_new_ver） ========
get_latest_gost_ver() {
    # releases/latest
    local v=""
    v=$(curl -m 6 -fsSL https://api.github.com/repos/ginuerzh/gost/releases/latest \
        | grep -oE '"tag_name"\s*:\s*"v[0-9\.]+"' | head -n1 | sed 's/[^0-9\.]//g')
    # tags 列表兜底
    if [[ -z "$v" ]]; then
        v=$(curl -m 6 -fsSL https://api.github.com/repos/ginuerzh/gost/tags \
            | grep -oE '"name"\s*:\s*"v[0-9\.]+"' | head -n1 | sed 's/[^0-9\.]//g')
    fi
    [[ -n "$v" ]] && echo "$v" || echo "$ct_new_ver"
}

# ======== 新增：升级到 2.x 最新版（保留你现有配置格式） ========
update_gost() {
    detect_environment
    local ver; ver=$(get_latest_gost_ver)
    echo -e "${Info} 准备更新到 GOST v${ver} (${arch}) ..."
    cd /tmp || { echo -e "${Error} 无法进入 /tmp"; return 1; }
    rm -f /tmp/gost.gz /tmp/gost
    local urls=(
      "https://github.com/ginuerzh/gost/releases/download/v${ver}/gost-linux-${arch}-${ver}.gz"
      "https://mirror.ghproxy.com/https://github.com/ginuerzh/gost/releases/download/v${ver}/gost-linux-${arch}-${ver}.gz"
      "https://ghproxy.net/https://github.com/ginuerzh/gost/releases/download/v${ver}/gost-linux-${arch}-${ver}.gz"
    )
    local ok=""
    for u in "${urls[@]}"; do
      echo -e "${Info} 尝试下载：$u"
      if curl -fL --retry 3 -o /tmp/gost.gz "$u"; then
        if gzip -t /tmp/gost.gz 2>/dev/null; then ok=1; break
        else echo -e "${Warning} 不是有效的 gzip，换源重试..."; fi
      fi
    done
    if [ -z "$ok" ]; then echo -e "${Error} 下载失败，稍后再试或手动指定版本"; return 1; fi
    gunzip -f /tmp/gost.gz
    install -m 0755 /tmp/gost /usr/bin/gost
    systemctl restart gost >/dev/null 2>&1 || true
    echo -e "${Info} 已更新到 v${ver}"
    gost -V 2>/dev/null && echo
}

create_shortcut() {
    echo -e "${Info} 创建快捷命令..."
    if is_oneclick_install; then
        if wget -q -O /usr/local/bin/gost-manager.sh "https://raw.githubusercontent.com/xmg0828-01/gost/main/gost.sh"; then
            chmod +x /usr/local/bin/gost-manager.sh
        else
            cat > /usr/local/bin/gost-manager.sh << 'EOF'
#!/bin/bash
bash <(curl -sSL https://raw.githubusercontent.com/xmg0828-01/gost/main/gost.sh) --menu
EOF
            chmod +x /usr/local/bin/gost-manager.sh
        fi
    else
        cp "$0" /usr/local/bin/gost-manager.sh
        chmod +x /usr/local/bin/gost-manager.sh
    fi
    ln -sf /usr/local/bin/gost-manager.sh /usr/bin/g
    echo -e "${Info} 快捷命令 'g' 创建成功"
}

init_config() {
    mkdir -p /etc/gost
    touch /etc/gost/{rawconf,remarks.txt,expires.txt}
    [ ! -f "$gost_conf_path" ] && echo '{"Debug":false,"Retries":0,"ServeNodes":[]}' > "$gost_conf_path"
}

show_header() {
    clear
    echo -e "${Blue_font_prefix}======================================================${Font_color_suffix}"
    echo -e "${Green_font_prefix}          GOST 简化版管理面板 v${shell_version}${Font_color_suffix}"
    echo -e "${Blue_font_prefix}======================================================${Font_color_suffix}"
    echo -e "${Yellow_font_prefix}功能: 转发管理 | 到期时间 | 备注信息${Font_color_suffix}"
    echo -e "${Blue_font_prefix}======================================================${Font_color_suffix}"
    echo
}

check_expired_rules() {
    local expired_count=0 current_date=$(date +%s)
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
    echo -e "${Blue_font_prefix}========================= 转发规则列表 =========================${Font_color_suffix}"
    if [ ! -f "$raw_conf_path" ] || [ ! -s "$raw_conf_path" ]; then
        echo -e "${Warning} 暂无转发规则"; echo; return
    fi
    printf "${Green_font_prefix}%-4s %-10s %-25s %-15s %-12s${Font_color_suffix}\n" "ID" "端口" "目标地址" "备注" "到期时间"
    echo -e "${Blue_font_prefix}----------------------------------------------------------------${Font_color_suffix}"
    local id=1
    while IFS= read -r line; do
        local port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
        local target=$(echo "$line" | cut -d'#' -f2)
        local target_port=$(echo "$line" | cut -d'#' -f3)
        local remark=$(grep "^${port}:" "$remarks_path" 2>/dev/null | cut -d':' -f2- || echo "无")
        local expire_info=$(grep "^${port}:" "$expires_path" 2>/dev/null | cut -d':' -f2- || echo "永久")
        local expire_display=$(format_expire_date "$expire_info")
        [ ${#remark} -gt 13 ] && remark="${remark:0:13}.."
        [ ${#target} -gt 15 ] && target_display="${target:0:12}..." || target_display="$target"
        if [ "$expire_display" = "已过期" ]; then
            expire_color="${Red_font_prefix}"
        elif [ "$expire_display" = "今天到期" ]; then
            expire_color="${Yellow_font_prefix}"
        else
            expire_color=""
        fi
        printf "%-4s %-10s %-25s %-15s ${expire_color}%-12s${Font_color_suffix}\n" \
            "$id" "$port" "${target_display}:${target_port}" "$remark" "$expire_display"
        ((id++))
    done < "$raw_conf_path"
    echo
}

add_forward_rule() { ...同你原来的一致... }
delete_forward_rule() { ...同你原来的一致... }
rebuild_config() { ...同你原来的一致... }

manage_forwards() {
    while true; do
        show_header
        show_forwards_list
        echo -e "${Green_font_prefix}=================== 转发管理 ===================${Font_color_suffix}"
        echo -e "${Green_font_prefix}1.${Font_color_suffix} 新增转发规则"
        echo -e "${Green_font_prefix}2.${Font_color_suffix} 删除转发规则"
        echo -e "${Green_font_prefix}3.${Font_color_suffix} 清理过期规则"
        echo -e "${Green_font_prefix}4.${Font_color_suffix} 重启GOST服务"
        echo -e "${Green_font_prefix}0.${Font_color_suffix} 返回主菜单"
        echo
        read -p "请选择操作: " choice
        case $choice in
            1) add_forward_rule ;;
            2) delete_forward_rule ;;
            3) /usr/local/bin/gost-expire-check.sh; echo -e "${Info} 已清理过期规则"; sleep 2 ;;
            4) systemctl restart gost && echo -e "${Info} 服务已重启" && sleep 2 ;;
            0) break ;;
            *) echo -e "${Error} 无效选择" && sleep 2 ;;
        esac
    done
}

# ======== 修改这里：系统管理菜单里加入“升级 GOST 到最新版” ========
system_management() {
    while true; do
        show_header
        echo -e "${Green_font_prefix}=================== 系统管理 ===================${Font_color_suffix}"
        echo -e "${Green_font_prefix}1.${Font_color_suffix} 查看服务状态"
        echo -e "${Green_font_prefix}2.${Font_color_suffix} 启动GOST服务"
        echo -e "${Green_font_prefix}3.${Font_color_suffix} 停止GOST服务"
        echo -e "${Green_font_prefix}4.${Font_color_suffix} 重启GOST服务"
        echo -e "${Green_font_prefix}5.${Font_color_suffix} 升级 GOST 到最新版"
        echo -e "${Green_font_prefix}6.${Font_color_suffix} 卸载GOST"
        echo -e "${Green_font_prefix}0.${Font_color_suffix} 返回主菜单"
        echo
        read -p "请选择操作: " choice
        case $choice in
            1)  echo -e "${Info} 服务状态: $(systemctl is-active gost 2>/dev/null || echo '未运行')"
                echo -e "${Info} 开机自启: $(systemctl is-enabled gost 2>/dev/null || echo '未设置')"
                echo -e "${Info} 配置文件: $gost_conf_path"
                echo -e "${Info} 规则文件: $raw_conf_path"
                read -p "按Enter继续..." ;;
            2) systemctl start gost && echo -e "${Info} 服务已启动" && sleep 2 ;;
            3) systemctl stop gost && echo -e "${Info} 服务已停止" && sleep 2 ;;
            4) systemctl restart gost && echo -e "${Info} 服务已重启" && sleep 2 ;;
            5) update_gost; read -p "按Enter继续..." ;;
            6) read -p "确认卸载GOST？(y/N): " confirm
               if [[ $confirm =~ ^[Yy]$ ]]; then
                 systemctl stop gost 2>/dev/null
                 systemctl disable gost 2>/dev/null
                 rm -f /usr/bin/gost /etc/systemd/system/gost.service /usr/bin/g
                 rm -rf /etc/gost /usr/local/bin/gost-manager.sh /usr/local/bin/gost-expire-check.sh
                 rm -f /etc/cron.d/gost-expire
                 echo -e "${Info} 卸载完成"; exit 0
               fi ;;
            0) break ;;
            *) echo -e "${Error} 无效选择" && sleep 2 ;;
        esac
    done
}

main_menu() { ...同你原来的一致... }

main() { ...同你原来的一致... }

# 导出函数供expire-check使用
export -f rebuild_config

# 执行主函数
main "$@"
