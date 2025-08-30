#!/bin/bash
# GOST 简化版管理脚本 v2.3.1（完整可运行）
# 功能：一键安装/更新 GOST、systemd 管理、转发规则维护、到期清理、快捷命令 g
# 说明：全脚本均为英文直引号，已处理 if/fi 配对与 sed 正则问题

Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Yellow_font_prefix="\033[33m"
Blue_font_prefix="\033[34m" && Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Warning="${Yellow_font_prefix}[警告]${Font_color_suffix}"
shell_version="2.3.1"
# 若查询最新版本失败，将回退到此版本：
fallback_gost_ver="2.11.5"

gost_conf_path="/etc/gost/config.json"
raw_conf_path="/etc/gost/rawconf"
remarks_path="/etc/gost/remarks.txt"
expires_path="/etc/gost/expires.txt"

check_root() {
  [[ $EUID != 0 ]] && echo -e "${Error} 请使用 root 权限运行此脚本" && exit 1
}

detect_environment() {
  if [[ -f /etc/redhat-release ]]; then
    release="centos"
  elif grep -qiE "debian|ubuntu" /etc/issue 2>/dev/null || grep -qiE "debian|ubuntu" /etc/os-release 2>/dev/null; then
    release="debian"
  else
    release="debian"
  fi
  case "$(uname -m)" in
    x86_64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) arch="amd64" ;;
  esac
}

get_latest_gost_ver() {
  # 取 GitHub 最新版 tag（如 v2.11.5），失败返回 fallback
  local v
  v=$(curl -m 6 -fsSL https://api.github.com/repos/ginuerzh/gost/releases/latest \
      | grep -oE '"tag_name"\s*:\s*"v[0-9\.]+"' | head -n1 | sed 's/[^0-9\.]//g')
  if [[ -n "$v" ]]; then
    echo "$v"
  else
    echo "$fallback_gost_ver"
  fi
}

is_oneclick_install() {
  [[ "$0" =~ /dev/fd/ ]] || [[ "$0" == "bash" ]] || [[ "$0" =~ /proc/self/fd/ ]]
}

ensure_deps() {
  detect_environment
  if [[ $release == "centos" ]]; then
    yum install -y wget curl gzip tar cronie >/dev/null 2>&1
    systemctl enable crond >/dev/null 2>&1 || true
    systemctl start crond >/dev/null 2>&1 || true
  else
    apt-get update -y >/dev/null 2>&1
    apt-get install -y wget curl gzip cron >/dev/null 2>&1
    systemctl enable cron >/dev/null 2>&1 || true
    systemctl start cron >/dev/null 2>&1 || true
  fi
}

download_gost() {
  # 参数：$1=版本号（如 2.11.5）
  local ver="$1"
  local main_url="https://github.com/ginuerzh/gost/releases/download/v${ver}/gost-linux-${arch}-${ver}.gz"
  local mirror_url="https://mirror.ghproxy.com/${main_url}"
  cd /tmp || exit 1
  echo -e "${Info} 下载 GOST v${ver} (${arch}) ..."
  if ! wget -q --timeout=30 -O gost.gz "$main_url"; then
    echo -e "${Warning} 主源失败，尝试镜像源..."
    if ! wget -q --timeout=30 -O gost.gz "$mirror_url"; then
      echo -e "${Error} GOST v${ver} 下载失败"
      return 1
    fi
  fi
  gunzip -f gost.gz
  chmod +x gost
  mv -f gost /usr/bin/gost
  return 0
}

install_gost() {
  ensure_deps
  mkdir -p /etc/gost
  local ver
  ver=$(get_latest_gost_ver)
  download_gost "$ver" || { echo -e "${Error} 安装失败"; exit 1; }

  # systemd 服务
  cat > /etc/systemd/system/gost.service << 'SERVICE'
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
SERVICE

  systemctl daemon-reload
  systemctl enable gost >/dev/null 2>&1

  # 到期检查脚本
  cat > /usr/local/bin/gost-expire-check.sh << 'CHK'
#!/bin/bash
EXPIRES_FILE="/etc/gost/expires.txt"
RAW_CONF="/etc/gost/rawconf"
GOST_CONF="/etc/gost/config.json"
REMARKS="/etc/gost/remarks.txt"

[ ! -f "$EXPIRES_FILE" ] && exit 0

current_time=$(date +%s)
expired_ports=""

while IFS=: read -r port expire_date; do
  [ -z "$port" ] && continue
  if [ "$expire_date" != "永久" ] && [ "$expire_date" -lt "$current_time" ] 2>/dev/null; then
    expired_ports="$expired_ports $port"
  fi
done < "$EXPIRES_FILE"

if [ -n "$expired_ports" ]; then
  for port in $expired_ports; do
    sed -i "/\/${port}#/d" "$RAW_CONF"
    sed -i "/^${port}:/d" "$EXPIRES_FILE"
    sed -i "/^${port}:/d" "$REMARKS"
    echo "[$(date '+%F %T')] 端口 $port 的转发规则已过期并删除" >> /var/log/gost.log
  done
  /usr/local/bin/gost-manager.sh --rebuild >/dev/null 2>&1
fi
CHK
  chmod +x /usr/local/bin/gost-expire-check.sh

  # 每日 02:00 执行
  echo "0 2 * * * root /usr/local/bin/gost-expire-check.sh >/dev/null 2>&1" > /etc/cron.d/gost-expire
  systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null

  echo -e "${Info} GOST 安装完成"
}

update_gost() {
  ensure_deps
  local ver
  ver=$(get_latest_gost_ver)
  echo -e "${Info} 准备更新到 GOST v${ver} ..."
  if download_gost "$ver"; then
    systemctl restart gost >/dev/null 2>&1 || true
    echo -e "${Info} 已更新到 v${ver}"
  else
    echo -e "${Error} 更新失败"
    exit 1
  fi
}

create_shortcut() {
  echo -e "${Info} 创建快捷命令 ..."
  if is_oneclick_install; then
    cat > /usr/local/bin/gost-manager.sh << 'LDR'
#!/bin/bash
exec /root/gost_manager.sh "$@"
LDR
    chmod +x /usr/local/bin/gost-manager.sh
  else
    cp -f "$0" /usr/local/bin/gost-manager.sh
    chmod +x /usr/local/bin/gost-manager.sh
  fi
  ln -sf /usr/local/bin/gost-manager.sh /usr/bin/g
  echo -e "${Info} 快捷命令 'g' 创建成功"
}

init_config() {
  mkdir -p /etc/gost
  touch /etc/gost/rawconf /etc/gost/remarks.txt /etc/gost/expires.txt
  if [ ! -f "$gost_conf_path" ]; then
    echo '{"Debug":false,"Retries":0,"ServeNodes":[]}' > "$gost_conf_path"
  fi
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
  local expired_count=0
  local current_date
  current_date=$(date +%s)
  if [ -f "$expires_path" ]; then
    while IFS=: read -r port expire_date; do
      [ -z "$port" ] && continue
      if [ "$expire_date" != "永久" ] && [ "$expire_date" -lt "$current_date" ] 2>/dev/null; then
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
    local current days_left
    current=$(date +%s)
    days_left=$(( (expire_timestamp - current) / 86400 ))
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
  if [ ! -s "$raw_conf_path" ]; then
    echo -e "${Warning} 暂无转发规则"; echo; return
  fi
  printf "%-4s %-10s %-25s %-15s %-12s\n" "ID" "端口" "目标地址" "备注" "到期时间"
  echo -e "${Blue_font_prefix}----------------------------------------------------------------${Font_color_suffix}"

  local id=1
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local port target target_port remark expire_info expire_display target_display expire_color
    port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
    target=$(echo "$line" | cut -d'#' -f2)
    target_port=$(echo "$line" | cut -d'#' -f3)
    remark=$(grep "^${port}:" "$remarks_path" 2>/dev/null | cut -d':' -f2-)
    [ -z "$remark" ] && remark="无"
    expire_info=$(grep "^${port}:" "$expires_path" 2>/dev/null | cut -d':' -f2-)
    [ -z "$expire_info" ] && expire_info="永久"
    expire_display=$(format_expire_date "$expire_info")
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

add_forward_rule() {
  echo -e "${Info} 添加 TCP+UDP 转发规则"
  read -rp "本地监听端口: " local_port
  read -rp "目标 IP 地址: " target_ip
  read -rp "目标端口: " target_port
  read -rp "备注信息 (可选): " remark

  echo -e "${Info} 设置到期时间:"
  echo "1) 永久有效"
  echo "2) 自定义天数"
  read -rp "请选择 [1-2]: " expire_choice

  local expire_timestamp="永久"
  if [ "$expire_choice" = "2" ]; then
    read -rp "请输入有效天数: " days
    if [[ $days =~ ^[0-9]+$ ]] && [ "$days" -gt 0 ]; then
      expire_timestamp=$(date -d "+${days} days" +%s)
      echo -e "${Info} 规则将在 ${days} 天后到期"
    else
      echo -e "${Warning} 天数格式错误，设置为永久有效"
      expire_timestamp="永久"
    fi
  fi

  if [[ ! $local_port =~ ^[0-9]+$ ]] || [[ ! $target_port =~ ^[0-9]+$ ]]; then
    echo -e "${Error} 端口必须为数字"; sleep 2; return
  fi
  if grep -q "/${local_port}#" "$raw_conf_path" 2>/dev/null; then
    echo -e "${Error} 端口 $local_port 已被使用"; sleep 2; return
  fi

  echo "nonencrypt/${local_port}#${target_ip}#${target_port}" >> "$raw_conf_path"
  [ -n "$remark" ] && echo "${local_port}:${remark}" >> "$remarks_path"
  echo "${local_port}:${expire_timestamp}" >> "$expires_path"

  rebuild_config
  echo -e "${Info} 规则已添加：${local_port} -> ${target_ip}:${target_port}"
  echo -e "${Info} 到期：$(format_expire_date "$expire_timestamp")"
  sleep 1
}

delete_forward_rule() {
  if [ ! -s "$raw_conf_path" ]; then
    echo -e "${Warning} 暂无转发规则"; sleep 1; return
  fi
  read -rp "请输入要删除的规则 ID: " rule_id
  if ! [[ $rule_id =~ ^[0-9]+$ ]] || [ "$rule_id" -lt 1 ]; then
    echo -e "${Error} 无效的规则 ID"; sleep 1; return
  fi
  local line
  line=$(sed -n "${rule_id}p" "$raw_conf_path")
  if [ -z "$line" ]; then
    echo -e "${Error} 规则 ID 不存在"; sleep 1; return
  fi
  local port
  port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
  sed -i "${rule_id}d" "$raw_conf_path"
  sed -i "/^${port}:/d" "$remarks_path" 2>/dev/null
  sed -i "/^${port}:/d" "$expires_path" 2>/dev/null
  rebuild_config
  echo -e "${Info} 已删除规则 (端口: ${port})"
  sleep 1
}

rebuild_config() {
  if [ ! -s "$raw_conf_path" ]; then
    echo '{"Debug":false,"Retries":0,"ServeNodes":[]}' > "$gost_conf_path"
  else
    {
      echo '{"Debug":false,"Retries":0,"ServeNodes":['
      local i=1 count_line
      count_line=$(wc -l < "$raw_conf_path")
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        local port target target_port
        port=$(echo "$line" | cut -d'/' -f2 | cut -d'#' -f1)
        target=$(echo "$line" | cut -d'#' -f2)
        target_port=$(echo "$line" | cut -d'#' -f3)
        printf '        "tcp://:%s/%s:%s","udp://:%s/%s:%s"' "$port" "$target" "$target_port" "$port" "$target" "$target_port"
        if [ "$i" -lt "$count_line" ]; then
          echo ","
        else
          echo
        fi
        ((i++))
      done < "$raw_conf_path"
      echo "    ]}"
    } > "$gost_conf_path"
  fi
  systemctl restart gost >/dev/null 2>&1
}

manage_forwards() {
  while true; do
    show_header
    show_forwards_list
    echo -e "${Green_font_prefix}=================== 转发管理 ===================${Font_color_suffix}"
    echo -e "${Green_font_prefix}1.${Font_color_suffix} 新增转发规则"
    echo -e "${Green_font_prefix}2.${Font_color_suffix} 删除转发规则"
    echo -e "${Green_font_prefix}3.${Font_color_suffix} 清理过期规则"
    echo -e "${Green_font_prefix}4.${Font_color_suffix} 重启 GOST 服务"
    echo -e "${Green_font_prefix}0.${Font_color_suffix} 返回主菜单"
    echo
    read -rp "请选择操作: " choice
    case "$choice" in
      1) add_forward_rule ;;
      2) delete_forward_rule ;;
      3) /usr/local/bin/gost-expire-check.sh; echo -e "${Info} 已清理过期规则"; sleep 1 ;;
      4) systemctl restart gost && echo -e "${Info} 服务已重启" && sleep 1 ;;
      0) break ;;
      *) echo -e "${Error} 无效选择"; sleep 1 ;;
    esac
  done
}

system_management() {
  while true; do
    show_header
    echo -e "${Green_font_prefix}=================== 系统管理 ===================${Font_color_suffix}"
    echo -e "${Green_font_prefix}1.${Font_color_suffix} 查看服务状态"
    echo -e "${Green_font_prefix}2.${Font_color_suffix} 启动 GOST"
    echo -e "${Green_font_prefix}3.${Font_color_suffix} 停止 GOST"
    echo -e "${Green_font_prefix}4.${Font_color_suffix} 重启 GOST"
    echo -e "${Green_font_prefix}5.${Font_color_suffix} 升级 GOST 到最新版"
    echo -e "${Green_font_prefix}6.${Font_color_suffix} 卸载 GOST"
    echo -e "${Green_font_prefix}0.${Font_color_suffix} 返回主菜单"
    echo
    read -rp "请选择操作: " choice
    case "$choice" in
      1)
        echo -e "${Info} 服务状态: $(systemctl is-active gost 2>/dev/null || echo '未运行')"
        echo -e "${Info} 开机自启: $(systemctl is-enabled gost 2>/dev/null || echo '未设置')"
        echo -e "${Info} 配置文件: $gost_conf_path"
        echo -e "${Info} 规则文件: $raw_conf_path"
        read -rp "按 Enter 继续..." ;;
      2) systemctl start gost && echo -e "${Info} 已启动" && sleep 1 ;;
      3) systemctl stop gost && echo -e "${Info} 已停止" && sleep 1 ;;
      4) systemctl restart gost && echo -e "${Info} 已重启" && sleep 1 ;;
      5) update_gost; read -rp "按 Enter 继续..." ;;
      6)
        read -rp "确认卸载 GOST？(y/N): " c
        if [[ $c =~ ^[Yy]$ ]]; then
          systemctl stop gost 2>/dev/null
          systemctl disable gost 2>/dev/null
          rm -f /usr/bin/gost /etc/systemd/system/gost.service /usr/bin/g
          rm -rf /etc/gost /usr/local/bin/gost-manager.sh /usr/local/bin/gost-expire-check.sh
          rm -f /etc/cron.d/gost-expire
          systemctl daemon-reload
          echo -e "${Info} 卸载完成"; exit 0
        fi ;;
      0) break ;;
      *) echo -e "${Error} 无效选择"; sleep 1 ;;
    esac
  done
}

main_menu() {
  while true; do
    show_header
    get_system_info
    echo -e "${Green_font_prefix}==================== 主菜单 ====================${Font_color_suffix}"
    echo -e "${Green_font_prefix}1.${Font_color_suffix} 转发管理"
    echo -e "${Green_font_prefix}2.${Font_color_suffix} 系统管理"
    echo -e "${Green_font_prefix}0.${Font_color_suffix} 退出程序"
    echo -e "${Blue_font_prefix}=================================================${Font_color_suffix}"
    echo -e "${Yellow_font_prefix}提示: 使用命令 'g' 可快速打开此面板${Font_color_suffix}"
    echo
    read -rp "请选择操作 [0-2]: " choice
    case "$choice" in
      1) manage_forwards ;;
      2) system_management ;;
      0) echo -e "${Info} 感谢使用!"; exit 0 ;;
      *) echo -e "${Error} 无效选择"; sleep 1 ;;
    esac
  done
}

main() {
  check_root
  case "${1:-}" in
    --menu)    init_config; main_menu ;;
    --rebuild) rebuild_config ;;
    *)
      if ! command -v gost >/dev/null 2>&1; then
        echo -e "${Info} 检测到 GOST 未安装，开始安装..."
        install_gost
        create_shortcut
        init_config
        echo -e "${Info} 安装完成！现在可以使用 'g' 命令打开管理面板"
        echo -e "${Info} 正在打开管理面板..."
        sleep 1
        main_menu
      else
        [ ! -f "/usr/bin/g" ] && create_shortcut
        init_config
        main_menu
      fi
      ;;
  esac
}

main "$@"
