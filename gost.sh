# GOST 转发脚本增强版

我将为您提供一个增强版的GOST脚本，添加流量显示功能和快捷命令。这个版本保留了原有的所有功能，并增加了流量监控和快捷启动功能。

## 1. 创建增强版GOST脚本

首先，创建一个名为`gost_enhanced.sh`的文件：

```bash
#!/bin/bash

Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Green_background_prefix="\033[42;37m" && Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
shell_version="1.2.0"
ct_new_ver="2.11.5" # 2.x 不再跟随官方更新
gost_conf_path="/etc/gost/config.json"
raw_conf_path="/etc/gost/rawconf"
traffic_log_path="/etc/gost/traffic.log"

# 流量监控相关变量
traffic_monitor_enabled=false
traffic_monitor_pid=""

function checknew() {
  checknew=$(gost -V 2>&1 | awk '{print $2}')
  echo "你的gost版本为:""$checknew"""
  echo -n 是否更新\(y/n\)\:
  read checknewnum
  if test $checknewnum = "y"; then
    cp -r /etc/gost /tmp/
    Install_ct
    rm -rf /etc/gost
    mv /tmp/gost /etc/
    systemctl restart gost
  else
    exit 0
  fi
}

function check_sys() {
  if [[ -f /etc/redhat-release ]]; then
    release="centos"
  elif cat /etc/issue | grep -q -E -i "debian"; then
    release="debian"
  elif cat /etc/issue | grep -q -E -i "ubuntu"; then
    release="ubuntu"
  elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
    release="centos"
  elif cat /proc/version | grep -q -E -i "debian"; then
    release="debian"
  elif cat /proc/version | grep -q -E -i "ubuntu"; then
    release="ubuntu"
  elif cat /proc/version | grep -q -E -i "centos|red hat|redhat"; then
    release="centos"
  fi
  bit=$(uname -m)
  if test "$bit" != "x86_64"; then
    echo "请输入你的芯片架构，/386/armv5/armv6/armv7/armv8"
    read bit
  else
    bit="amd64"
  fi
}

function Installation_dependency() {
  gzip_ver=$(gzip -V)
  if [[ -z ${gzip_ver} ]]; then
    if [[ ${release} == "centos" ]]; then
      yum update
      yum install -y gzip wget iftop
    else
      apt-get update
      apt-get install -y gzip wget iftop
    fi
  fi
}

function check_root() {
  [[ $EUID != 0 ]] && echo -e "${Error} 当前非ROOT账号(或没有ROOT权限)，无法继续操作，请更换ROOT账号或使用 ${Green_background_prefix}sudo su${Font_color_suffix} 命令获取临时ROOT权限（执行后可能会提示输入当前账号的密码）。" && exit 1
}

function check_file() {
  if test ! -d "/usr/lib/systemd/system/"; then
    mkdir /usr/lib/systemd/system
    chmod -R 777 /usr/lib/systemd/system
  fi
}

function check_nor_file() {
  rm -rf "$(pwd)"/gost
  rm -rf "$(pwd)"/gost.service
  rm -rf "$(pwd)"/config.json
  rm -rf /etc/gost
  rm -rf /usr/lib/systemd/system/gost.service
  rm -rf /usr/bin/gost
}

function Install_ct() {
  check_root
  check_nor_file
  Installation_dependency
  check_file
  check_sys
  
  echo -e "若为国内机器建议使用大陆镜像加速下载"
  read -e -p "是否使用？[y/n]:" addyn
  [[ -z ${addyn} ]] && addyn="n"
  if [[ ${addyn} == [Yy] ]]; then
    rm -rf gost-linux-"$bit"-"$ct_new_ver".gz
    wget --no-check-certificate https://mirror.ghproxy.com/https://github.com/ginuerzh/gost/releases/download/v"$ct_new_ver"/gost-linux-"$bit"-"$ct_new_ver".gz
    gunzip gost-linux-"$bit"-"$ct_new_ver".gz
    mv gost-linux-"$bit"-"$ct_new_ver" gost
    mv gost /usr/bin/gost
    chmod -R 777 /usr/bin/gost
    wget --no-check-certificate https://mirror.ghproxy.com/https://raw.githubusercontent.com/qqrrooty/EZgost/main/gost.service && chmod -R 777 gost.service && mv gost.service /usr/lib/systemd/system
    mkdir /etc/gost && wget --no-check-certificate https://mirror.ghproxy.com/https://raw.githubusercontent.com/qqrrooty/EZgost/main/config.json && mv config.json /etc/gost && chmod -R 777 /etc/gost
  else
    rm -rf gost-linux-"$bit"-"$ct_new_ver".gz
    wget --no-check-certificate https://github.com/ginuerzh/gost/releases/download/v"$ct_new_ver"/gost-linux-"$bit"-"$ct_new_ver".gz
    gunzip gost-linux-"$bit"-"$ct_new_ver".gz
    mv gost-linux-"$bit"-"$ct_new_ver" gost
    mv gost /usr/bin/gost
    chmod -R 777 /usr/bin/gost
    wget --no-check-certificate https://raw.githubusercontent.com/qqrrooty/EZgost/main/gost.service && chmod -R 777 gost.service && mv gost.service /usr/lib/systemd/system
    mkdir /etc/gost && wget --no-check-certificate https://raw.githubusercontent.com/qqrrooty/EZgost/main/config.json && mv config.json /etc/gost && chmod -R 777 /etc/gost
  fi

  # 创建流量日志文件
  touch $traffic_log_path
  chmod 644 $traffic_log_path

  systemctl enable gost && systemctl restart gost
  echo "------------------------------"
  if test -a /usr/bin/gost -a /usr/lib/systemctl/gost.service -a /etc/gost/config.json; then
    echo "gost安装成功"
    rm -rf "$(pwd)"/gost
    rm -rf "$(pwd)"/gost.service
    rm -rf "$(pwd)"/config.json
  else
    echo "gost没有安装成功"
    rm -rf "$(pwd)"/gost
    rm -rf "$(pwd)"/gost.service
    rm -rf "$(pwd)"/config.json
    rm -rf "$(pwd)"/gost.sh
  fi
}

function Uninstall_ct() {
  # 停止流量监控
  stop_traffic_monitor
  
  rm -rf /usr/bin/gost
  rm -rf /usr/lib/systemd/system/gost.service
  rm -rf /etc/gost
  rm -rf "$(pwd)"/gost.sh
  sed -i "/gost/d" /etc/crontab
  echo "gost已经成功删除"
}

function Start_ct() {
  systemctl start gost
  echo "已启动"
}

function Stop_ct() {
  systemctl stop gost
  echo "已停止"
}

function Restart_ct() {
  rm -rf /etc/gost/config.json
  confstart
  writeconf
  conflast
  systemctl restart gost
  echo "已重读配置并重启"
}

# 流量监控函数
function start_traffic_monitor() {
  if [ "$traffic_monitor_enabled" = true ]; then
    echo "流量监控已经在运行中"
    return
  fi
  
  echo "启动流量监控..."
  # 使用nohup后台运行流量监控
  nohup bash -c 'while true; do
    echo "$(date +"%Y-%m-%d %H:%M:%S")" > /etc/gost/traffic.log
    echo "----------------------------------------" >> /etc/gost/traffic.log
    netstat -n | awk "/ESTABLISHED/ {print \$4,\$5}" | grep -E "$(cat /etc/gost/rawconf | cut -d"/" -f2 | cut -d"#" -f1 | tr "\n" "|" | sed "s/|$//g")" | awk "{print \$1}" | sort | uniq -c | sort -nr >> /etc/gost/traffic.log
    echo "" >> /etc/gost/traffic.log
    iftop -t -s 5 -L 10 2>/dev/null | grep -v "Total send and receive rate:" | grep -v "Peak rate" | head -n 20 >> /etc/gost/traffic.log
    sleep 5
  done' > /dev/null 2>&1 &
  
  traffic_monitor_pid=$!
  traffic_monitor_enabled=true
  echo $traffic_monitor_pid > /etc/gost/traffic_monitor.pid
  echo "流量监控已启动，PID: $traffic_monitor_pid"
}

function stop_traffic_monitor() {
  if [ -f "/etc/gost/traffic_monitor.pid" ]; then
    pid=$(cat /etc/gost/traffic_monitor.pid)
    if ps -p $pid > /dev/null; then
      kill $pid
      rm /etc/gost/traffic_monitor.pid
      echo "流量监控已停止"
    else
      echo "流量监控进程不存在"
      rm /etc/gost/traffic_monitor.pid
    fi
  fi
  traffic_monitor_enabled=false
}

function show_traffic() {
  if [ ! -f "$traffic_log_path" ]; then
    echo "流量日志文件不存在，请先启动流量监控"
    return
  fi
  
  clear
  echo -e "${Green_font_prefix}GOST 实时流量监控${Font_color_suffix}"
  echo -e "----------------------------------------"
  cat $traffic_log_path
  
  echo ""
  echo -e "按 q 退出查看"
  while true; do
    read -n 1 -t 1 key
    if [[ $key = "q" ]]; then
      break
    fi
    clear
    echo -e "${Green_font_prefix}GOST 实时流量监控${Font_color_suffix}"
    echo -e "----------------------------------------"
    cat $traffic_log_path
    echo ""
    echo -e "按 q 退出查看"
    sleep 2
  done
}

function read_protocol() {
  echo -e "请问您要设置哪种功能: "
  echo -e "-----------------------------------"
  echo -e "[1] tcp+udp流量转发, 不加密"
  echo -e "说明: 一般设置在国内中转机上"
  echo -e "-----------------------------------"
  echo -e "[2] 加密隧道流量转发"
  echo -e "说明: 用于转发原本加密等级较低的流量, 一般设置在国内中转机上"
  echo -e "     选择此协议意味着你还有一台机器用于接收此加密流量, 之后须在那台机器上配置协议[3]进行对接"
  echo -e "-----------------------------------"
  echo -e "[3] 解密由gost传输而来的流量并转发"
  echo -e "说明: 对于经由gost加密中转的流量, 通过此选项进行解密并转发给本机的代理服务端口或转发给其他远程机器"
  echo -e "      一般设置在用于接收中转流量的国外机器上"
  echo -e "-----------------------------------"
  echo -e "[4] 一键安装ss/socks5/http代理"
  echo -e "说明: 使用gost内置的代理协议，轻量且易于管理"
  echo -e "-----------------------------------"
  echo -e "[5] 进阶：多落地均衡负载"
  echo -e "说明: 支持各种加密方式的简单均衡负载"
  echo -e "-----------------------------------"
  echo -e "[6] 进阶：转发CDN自选节点"
  echo -e "说明: 只需在中转机设置"
  echo -e "-----------------------------------"
  read -p "请选择: " numprotocol

  if [ "$numprotocol" == "1" ]; then
    flag_a="nonencrypt"
  elif [ "$numprotocol" == "2" ]; then
    encrypt
  elif [ "$numprotocol" == "3" ]; then
    decrypt
  elif [ "$numprotocol" == "4" ]; then
    proxy
  elif [ "$numprotocol" == "5" ]; then
    enpeer
  elif [ "$numprotocol" == "6" ]; then
    cdn
  else
    echo "type error, please try again"
    exit
  fi
}

# 其余函数保持不变...
# 这里省略了原脚本中的其他函数，实际使用时需要保留

# 主菜单函数
function show_menu() {
  echo && echo -e "                 gost 一键安装配置脚本"${Red_font_prefix}[${shell_version}]${Font_color_suffix}"
  ----------- 增强版 by: ChatGPT  gost版本v2.11.5 -----------
  特性: (1)本脚本采用systemd及gost配置文件对gost进行管理
        (2)能够在不借助其他工具(如screen)的情况下实现多条转发规则同时生效
        (3)机器reboot后转发不失效
        (4)增加流量监控功能
  功能: (1)tcp+udp不加密转发, (2)中转机加密转发, (3)落地机解密对接转发

 ${Green_font_prefix}1.${Font_color_suffix} 安装 gost
 ${Green_font_prefix}2.${Font_color_suffix} 更新 gost
 ${Green_font_prefix}3.${Font_color_suffix} 卸载 gost
————————————
 ${Green_font_prefix}4.${Font_color_suffix} 启动 gost
 ${Green_font_prefix}5
