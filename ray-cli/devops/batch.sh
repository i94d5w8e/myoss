#!/usr/bin/env bash

# 严格模式
set -euo pipefail
IFS=$'\n\t'

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# 常量定义
readonly TIMEOUT=30
readonly MAX_RETRIES=2
readonly RETRY_INTERVAL=3
readonly CONNECT_TIMEOUT=10
readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
readonly SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}")
readonly LOG_DIR="${SCRIPT_DIR}/logs"
readonly LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME}.lock"
# 主机配置相关
readonly DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/hosts.conf"
readonly DEFAULT_PORT=22
readonly DEFAULT_USER="root"

# 确保目录存在
mkdir -p "${LOG_DIR}"

# 全局变量
declare -A HOSTS
declare -i VERBOSE=0
# 主机数组声明
declare -A HOSTS

# Rsync配置
RSYNC_REMOTE_PATH="/home/ray-cli/cli/config/logs/"
RSYNC_LOCAL_PATH="${SCRIPT_DIR}/logbak/{host}/logs/"
RSYNC_LOG_FILE="${LOG_DIR}/rsync.log"
RSYNC_ERROR_LOG="${LOG_DIR}/rsync_errors.log"

# 日志函数
function log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local color=""
    
    case "$level" in
        INFO)  color=$GREEN ;;
        WARN)  color=$YELLOW ;;
        ERROR) color=$RED ;;
        DEBUG) color=$BLUE ;;
    esac
    
    echo -e "${color}${timestamp} [${level}] ${message}${NC}" | tee -a "$LOG_FILE"
    
    # 错误日志额外处理
    if [[ $level == "ERROR" ]]; then
        echo "Stack trace:" >> "$LOG_FILE"
        local frame=0
        while caller $frame; do
            ((frame++))
        done >> "$LOG_FILE"
    fi
}

function info()  { log "INFO" "$*"; }
function warn()  { log "WARN" "$*"; }
function error() { log "ERROR" "$*"; }
function debug() { [[ $VERBOSE -eq 1 ]] && log "DEBUG" "$*"; }

# 错误处理
function cleanup() {
    local exit_code=$?
    local line_number=${BASH_LINENO[0]}
    rm -f "$LOCK_FILE"
    if [[ $exit_code -ne 0 ]]; then
        error "脚本执行失败，在第 ${line_number} 行退出，退出码: $exit_code"
        # 显示调用栈
        local frame=0
        while caller $frame; do
            ((frame++))
        done | while read -r line sub file; do
            error "  在 $file 的第 $line 行，函数 $sub"
        done
    fi
    exit $exit_code
}

function error_handler() {
    local line_no=$1
    local command=$2
    local error_code=${3:-1}
    error "错误发生在第 $line_no 行: '$command' (错误码: $error_code)"
}

# 设置trap
trap 'error_handler ${LINENO} "$BASH_COMMAND" $?' ERR
trap cleanup EXIT

# 单例运行检查
function check_single_instance() {
    if [[ -f "$LOCK_FILE" ]]; then
        pid=$(cat "$LOCK_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            error "另一个实例正在运行 (PID: $pid)"
            exit 1
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

deps_check() {
    local deps=("curl" "expect" "nc")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            error "未找到依赖 $dep."
            install_tools "$dep" || exit 1
            #exit 1
        fi
    done
}

install_tools() {
    dep=$1
    echo "安装依赖: $dep"
    # 获取操作系统信息
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu)
                # 对于 Ubuntu 系统，使用 apt-get 安装
                sudo apt-get install -y $dep
                ;;
            centos|rocky)
                # 对于 CentOS 和 Rocky Linux 系统，使用 yum 安装
                sudo yum install -y $dep
                ;;
            fedora)
                # 对于 Fedora 系统，使用 dnf 安装
                sudo dnf install -y $dep
                ;;
            *)
                echo "不支持的发行版：$NAME"
                return 1
                ;;
        esac
    else
        echo "/etc/os-release 文件不存在，无法判断系统类型。"
        return 1
    fi
    return 0
}


# 加载配置
function load_config() {
    local config_file="${SCRIPT_DIR}/config.ini"
    if [[ -f "$config_file" ]]; then
        info "加载配置文件: $config_file"
        source "$config_file"
    else
        warn "配置文件不存在: $config_file"
    fi
}

# 测试连接函数
function test_connection() {
    local host=$1
    local port=$2
    local user=$3
    local password=${4:-}
    local timeout=5
    
    info "测试连接 $host:$port ($user)"
    
    # DNS检查
    # if [[ ! "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    #     # 不是IP地址，需要进行DNS解析
    #     if ! host "$host" &>/dev/null; then
    #         warn "  └─ DNS解析失败: $host"
    #         return 1
    #     fi
    # fi
    
    # 端口检查
    if [ "$(command -v nc)" ]; then
        if ! nc -z -w3 "$host" "$port" &>/dev/null; then
            warn "  └─ 端口 $port 未开放"
            return 1
        fi
    fi
    
    

    if [[ "${password}" != "" ]]; then
        info "SSH有密码连接测试"
        # 尝试使用不同的方法分发公钥
        if command -v expect >/dev/null 2>&1; then
            expect -c "
                set timeout $timeout
                spawn ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -p $port $user@$host "exit"
                expect {
                    \"*yes/no*\" { send \"yes\r\"; exp_continue }
                    \"*password:*\" { send \"$password\r\"; exp_continue }
                    timeout { 
                        puts \"连接超时\"
                        exit 1
                    }
                }
                expect eof
                catch wait result
                exit [lindex \$result 3]
            " &>/dev/null
            
            # 检查连接结果
            if [[ $? -ne 0 ]]; then
                warn "  └─ SSH连接失败"
                return 1
            fi
        elif command -v sshpass >/dev/null 2>&1; then
            # SSH连接测试
            if ! timeout $timeout sshpass -p "$password" ssh -o BatchMode=yes \
                                    -o ConnectTimeout=3 \
                                    -o StrictHostKeyChecking=no \
                                    -p "$port" "$user@$host" "exit" &>/dev/null; then
                warn "  └─ SSH连接失败"
                return 1
            fi
        fi
    else
        info "SSH无密码连接测试"
        # SSH连接测试
        if ! timeout $timeout ssh -o BatchMode=yes \
                                -o ConnectTimeout=3 \
                                -o StrictHostKeyChecking=no \
                                -p "$port" "$user@$host" "exit" &>/dev/null; then
            warn "  └─ SSH连接失败"
            return 1
        fi
    fi
    
    info "  └─ SSH连接测试成功"
    return 0
}

# 批量执行命令的优化版本
function batch_exec_command() {
    local script=$1
    local success_count=0
    local failed_count=0
    local total_hosts=${#HOSTS[@]}
    local start_total=$(date +%s)

    info "开始批量执行命令: $script"
    info "==============================="
    
    # 检查主机配置
    if ! needHosts; then
        warn "请先配置主机信息"
        return 1    # 使用 return 而不是 exit
    fi

    for host_info in "${HOSTS[@]}"; do
        IFS=',' read -r host port user password _ <<< "$host_info"
        
        # 连接测试
        if ! test_connection "$host" "$port" "$user"; then
            ((failed_count++))
            continue
        fi

        local retry_count=0
        local success=false
        
        while [[ $retry_count -lt $MAX_RETRIES ]]; do
            local start_time=$(date +%s)
            
            info "执行命令: ssh -p $port $user@$host"
            output=$(timeout $TIMEOUT ssh \
                -o ConnectTimeout=$CONNECT_TIMEOUT \
                -o StrictHostKeyChecking=no \
                -o BatchMode=yes \
                -o ServerAliveInterval=5 \
                -o ServerAliveCountMax=2 \
                -o LogLevel=ERROR \
                "$user@$host" -p "$port" "bash -s" <<< "$script" 2>&1) || true
            
            local exit_code=$?
            local duration=$(($(date +%s) - start_time))

            case $exit_code in
                0)
                    info "✅ $host 执行成功 (${duration}s)"
                    [[ -n "$output" ]] && info "输出:\n$output"
                    success=true
                    ((success_count++))
                    break
                    ;;
                124)
                    warn "⏱️ $host 执行超时"
                    ;;
                *)
                    warn "❌ $host 执行失败 (代码: $exit_code)"
                    [[ -n "$output" ]] && warn "错误:\n$output"
                    ;;
            esac

            ((retry_count++))
            [[ $retry_count -lt $MAX_RETRIES ]] && {
                warn "等待 ${RETRY_INTERVAL}s 后重试..."
                sleep $RETRY_INTERVAL
            }
        done

        ! $success && ((failed_count++))
    done

    local total_duration=$(($(date +%s) - start_total))
    
    # 执行报告
    info "📊 执行报告:"
    info "总耗时: ${total_duration}s"
    info "总主机: $total_hosts"
    info "成功数: $success_count"
    info "失败数: $failed_count"
    
    return $((failed_count > 0))
}


# 批量执行安装
function batch_exec_install() {
    local script="bash <(curl -LsS https://goo.su/Bs1w0B6) install"
    local success_count=0
    local failed_count=0
    local total_hosts=${#HOSTS[@]}
    local start_total=$(date +%s)

    info "开始批量执行命令: $script"
    info "==============================="
    
    # 检查主机配置
    if ! needHosts; then
        warn "请先配置主机信息"
        return 1    # 使用 return 而不是 exit
    fi

    for host_info in "${HOSTS[@]}"; do
        IFS=',' read -r host port user password apihost apikey nodeid <<< "$host_info"
        
        # 连接测试
        if ! test_connection "$host" "$port" "$user"; then
            ((failed_count++))
            continue
        fi

        if [[ "$apihost" != "" ]]; then
            script="ENV_APIHOST='$apihost' ENV_APIKEY='$apikey' ENV_NODE_ID=$nodeid $script"
        fi

        local retry_count=0
        local success=false
        
        while [[ $retry_count -lt $MAX_RETRIES ]]; do
            local start_time=$(date +%s)
            
            info "执行命令: ssh -p $port $user@$host  $script"
            output=$(timeout $TIMEOUT ssh \
                -o ConnectTimeout=$CONNECT_TIMEOUT \
                -o StrictHostKeyChecking=no \
                -o BatchMode=yes \
                -o ServerAliveInterval=5 \
                -o ServerAliveCountMax=2 \
                -o LogLevel=ERROR \
                "$user@$host" -p "$port" "bash -s" <<< "$script" 2>&1) || true
            
            local exit_code=$?
            local duration=$(($(date +%s) - start_time))

            case $exit_code in
                0)
                    info "✅ $host 执行成功 (${duration}s)"
                    [[ -n "$output" ]] && info "输出:\n$output"
                    success=true
                    ((success_count++))
                    break
                    ;;
                124)
                    warn "⏱️ $host 执行超时"
                    ;;
                *)
                    warn "❌ $host 执行失败 (代码: $exit_code)"
                    [[ -n "$output" ]] && warn "错误:\n$output"
                    ;;
            esac

            ((retry_count++))
            [[ $retry_count -lt $MAX_RETRIES ]] && {
                warn "等待 ${RETRY_INTERVAL}s 后重试..."
                sleep $RETRY_INTERVAL
            }
        done

        ! $success && ((failed_count++))
    done

    local total_duration=$(($(date +%s) - start_total))
    
    # 执行报告
    info "📊 执行报告:"
    info "总耗时: ${total_duration}s"
    info "总主机: $total_hosts"
    info "成功数: $success_count"
    info "失败数: $failed_count"
    
    return $((failed_count > 0))
}

# 批量执行脚本文件
function batch_exec_script() {
    local script_path=$1
    local success_count=0
    local failed_count=0
    local start_total=$(date +%s)

    # 检查脚本文件
    if [[ ! -f "$script_path" ]]; then
        error "脚本文件不存在: $script_path"
        return 1
    fi

    # 读取脚本内容
    local script_content
    script_content=$(cat "$script_path") || {
        error "无法读取脚本文件: $script_path"
        return 1
    }

    info "开始批量执行脚本: $script_path"
    info "==============================="
    
    # 检查主机配置
    if ! needHosts; then
        warn "请先配置主机信息"
        return 1    # 使用 return 而不是 exit
    fi

    for host_info in "${HOSTS[@]}"; do
        IFS=',' read -r host port user password _ <<< "$host_info"
        
        # 连接测试
        if ! test_connection "$host" "$port" "$user"; then
            ((failed_count++))
            continue
        fi

        local retry_count=0
        local success=false
        
        while [[ $retry_count -lt $MAX_RETRIES ]]; do
            local start_time=$(date +%s)
            
            info "执行脚本: ssh -p $port $user@$host"
            output=$(timeout $TIMEOUT ssh \
                -o ConnectTimeout=$CONNECT_TIMEOUT \
                -o StrictHostKeyChecking=no \
                -o BatchMode=yes \
                -o ServerAliveInterval=5 \
                -o ServerAliveCountMax=2 \
                -o LogLevel=ERROR \
                "$user@$host" -p "$port" "bash -s" <<< "$script_content" 2>&1) || true
            
            local exit_code=$?
            local duration=$(($(date +%s) - start_time))

            case $exit_code in
                0)
                    info "✅ $host 执行成功 (${duration}s)"
                    [[ -n "$output" ]] && info "输出:\n$output"
                    success=true
                    ((success_count++))
                    break
                    ;;
                124)
                    warn "⏱️ $host 执行超时"
                    ;;
                *)
                    warn "❌ $host 执行失败 (代码: $exit_code)"
                    [[ -n "$output" ]] && warn "错误:\n$output"
                    ;;
            esac

            ((retry_count++))
            [[ $retry_count -lt $MAX_RETRIES ]] && {
                warn "等待 ${RETRY_INTERVAL}s 后重试..."
                sleep $RETRY_INTERVAL
            }
        done

        ! $success && ((failed_count++))
    done

    local total_duration=$(($(date +%s) - start_total))
    
    # 执行报告
    info "📊 执行报告:"
    info "总耗时: ${total_duration}s"
    info "总主机: ${#HOSTS[@]}"
    info "成功数: $success_count"
    info "失败数: $failed_count"
    
    return $((failed_count > 0))
}

# SSH密钥管理相关函数
function check_ssh_key() {
    local key_file="$HOME/.ssh/id_rsa"
    local pub_file="$HOME/.ssh/id_rsa.pub"
    
    # 检查SSH目录
    if [[ ! -d "$HOME/.ssh" ]]; then
        info "创建 .ssh 目录"
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
    fi
    
    # 检查现有密钥
    if [[ -f "$key_file" ]]; then
        info "发现已存在的SSH密钥: $key_file"
        read -p "是否重新生成密钥? [y/N] " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && return 0
    fi
    
    return 1
}

function ssh_keygen() {
    info "开始SSH密钥生成流程..."
    
    # 检查现有密钥
    check_ssh_key || {
        local key_file="$HOME/.ssh/id_rsa"
        local key_type="rsa"
        local key_bits=4096
        local key_comment="auto-generated-$(date +%Y%m%d)"
        
        info "生成 $key_bits 位 $key_type 密钥"
        
        # 尝试使用密码保护
        read -p "是否为密钥设置密码? [y/N] " -n 1 -r
        echo
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            ssh-keygen -t "$key_type" \
                      -b "$key_bits" \
                      -C "$key_comment" \
                      -f "$key_file"
        else
            ssh-keygen -t "$key_type" \
                      -b "$key_bits" \
                      -C "$key_comment" \
                      -f "$key_file" \
                      -N ""
        fi
        
        if [[ $? -eq 0 ]]; then
            info "SSH密钥生成成功"
            info "公钥位置: ${key_file}.pub"
            info "私钥位置: ${key_file}"
            
            # 设置正确的权限
            chmod 600 "$key_file"
            chmod 644 "${key_file}.pub"
            
            # 显示公钥内容
            info "公钥内容:"
            cat "${key_file}.pub"
            
            # 提示后续操作
            info "建议执行以下操作:"
            info "1. 备份私钥"
            info "2. 使用 ssh-copy-id 分发公钥到目标服务器"
            return 0
        else
            error "SSH密钥生成失败"
            return 1
        fi
    }
}

function ssh_copy_id() {
    info "开始批量分发SSH公钥..."
    
    # 检查是否存在SSH密钥
    if [[ ! -f "$HOME/.ssh/id_rsa.pub" ]]; then
        error "未找到SSH公钥，请先运行 ssh-keygen"
        return 1
    fi
    
    # 检查主机配置
    if ! needHosts; then
        warn "请先配置主机信息"
        return 1    # 使用 return 而不是 exit
    fi

    local success_count=0
    local failed_count=0
    
    for host_info in "${HOSTS[@]}"; do
        IFS=',' read -r host port user password _ <<< "$host_info"
        info "正在处理主机: $host"
        
        # 检查连接
        # if ! test_connection "$host" "$port" "$user"; then
        #     ((failed_count++))
        #     continue
        # fi
        
        # 尝试使用不同的方法分发公钥
        if command -v expect >/dev/null 2>&1; then
            info "使用 expect 分发公钥"
            expect -c "
                set timeout 10
                spawn ssh-copy-id -p $port $user@$host
                expect {
                    \"*yes/no*\" { send \"yes\r\"; exp_continue }
                    \"*password:*\" { send \"$password\r\"; exp_continue }
                    timeout { 
                        puts \"连接超时\"
                        exit 1
                    }
                }
                expect eof
                catch wait result
                exit [lindex \$result 3]
            " &>/dev/null
            
        elif command -v sshpass >/dev/null 2>&1; then
            info "使用 sshpass 分发公钥"
            sshpass -p "$password" ssh-copy-id -p "$port" "$user@$host" &>/dev/null
            
        else
            warn "$host: 未找到 expect 或 sshpass，使用手动模式"
            info "请手动输入密码: "
            ssh-copy-id -p "$port" "$user@$host"
        fi
        
        # 验证公钥访问
        if ssh -o BatchMode=yes -p "$port" "$user@$host" exit 2>/dev/null; then
            info "✅ $host: 公钥分发成功"
            ((success_count++))
        else
            warn "❌ $host: 公钥分发失败"
            ((failed_count++))
        fi
    done
    
    # 输出统计信息
    info "📊 公钥分发统计:"
    info "总主机数: ${#HOSTS[@]}"
    info "成功数量: $success_count"
    info "失败数量: $failed_count"
    
    return $((failed_count > 0))
}


function load_hosts() {
    local config_file=${1:-$DEFAULT_CONFIG_FILE}
    info "加载默认主机配置: $config_file"
    
    # 检查配置文件
    if [[ ! -f "$config_file" ]]; then
        warn "默认配置文件不存在: $config_file"
        return
    fi
    
    # 清空现有配置
    HOSTS=()
    local host_count=0
    local line_number=0
    local invalid_count=0
    
    # 读取配置文件
    while IFS=',' read -r host port user password _ || [[ -n "$host" ]]; do
        ((line_number++))
        
        # 跳过注释和空行
        [[ "$host" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$host" ]] && continue
        
        # 清理输入
        host=$(echo "$host" | tr -d '[:space:]')
        port=$(echo "${port:-$DEFAULT_PORT}" | tr -d '[:space:]')
        user=$(echo "${user:-$DEFAULT_USER}" | tr -d '[:space:]')
        password=$(echo "$password" | tr -d '[:space:]')
        
        # 验证必要字段
        if [[ -z "$host" || -z "$password" ]]; then
            warn "第 $line_number 行: 缺少必要字段"
            ((invalid_count++))
            continue
        fi
        
        # 存储主机信息
        HOSTS[$host_count]="$host,$port,$user,$password"
        ((host_count++))
        
        info "添加主机: $host:$port ($user)"
    done < "$config_file"
    
    # 输出加载统计
    info "配置加载统计:"
    info "- 总行数: $line_number"
    info "- 有效主机: $host_count"
    info "- 无效配置: $invalid_count"
    
    # 验证是否有有效配置
    if [[ ${#HOSTS[@]} -eq 0 ]]; then
        error "没有找到有效的主机配置"
        return 1
    fi
    
    # 提示大量无效配置
    if [[ $invalid_count -gt 0 ]]; then
        warn "发现 $invalid_count 个无效配置，请检查配置文件"
    fi
    
    return 0
}

# 显示主机配置（隐藏密码）
function list_hosts() {
    needHosts || return 0

    info "当前主机配置:"
    printf "%-3s %-20s %-10s %-10s %-10s\n" "序号" "主机" "端口" "用户" "密码"
    echo "--------------------------------------------------------------"

    local i=0
    for host_info in "${HOSTS[@]}"; do
        IFS=',' read -r host port user _ <<< "$host_info"
        printf "%-3d %-20s %-10s %-10s %-15s\n" "$i" "$host" "$port" "$user" "*****"
        ((i++))
    done
    echo "--------------------------------------------------------------"
    return 0
}

# 验证主机配置
function validate_hosts() {
    local invalid_count=0
    local total_hosts=${#HOSTS[@]}
    local start_time=$(date +%s)
    
    info "开始验证主机配置..."
    info "总计 $total_hosts 个主机待验证"
    info "==============================="
    
    # 检查主机配置
    if ! needHosts; then
        warn "请先配置主机信息"
        return 1    # 使用 return 而不是 exit
    fi

    # 存储验证结果
    declare -A validation_results
    
    for host_info in "${HOSTS[@]}"; do
        IFS=',' read -r host port user password _ <<< "$host_info"
        info "正在验证: $host:$port ($user)"
        
        local error_msg=""
        local status="✅ 正常"
        
        # 检查DNS解析
        # if [[ ! "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        #     if ! host "$host" &>/dev/null; then
        #         error_msg="DNS解析失败"
        #         status="❌ 失败"
        #         ((invalid_count++))
        #     fi
        # fi

        # 端口检查
        if ! nc -z -w3 "$host" "$port" &>/dev/null; then
            error_msg="端口 $port 未开放"
            status="❌ 失败"
            ((invalid_count++))
        else
            
            if ! test_connection "$host" "$port" "$user" "$password"; then
                error_msg="SSH连接失败"
                status="❌ 失败"
                ((invalid_count++))
            fi

            # SSH连接测试
            # local ssh_output
            # ssh_output=$(timeout 5 ssh -o BatchMode=yes \
            #                         -o ConnectTimeout=3 \
            #                         -o StrictHostKeyChecking=no \
            #                         -p "$port" "$user@$host" "echo 'Connection test'" 2>&1)
            
            # if [ $? -ne 0 ]; then
            #     error_msg="SSH连接失败: ${ssh_output}"
            #     status="❌ 失败"
            #     ((invalid_count++))
            # fi
        fi
        
        # 存储验证结果
        validation_results["$host"]="$status | 端口: $port | 用户: $user | ${error_msg:-'验证通过'}"
        
        # 显示进度
        info "$status $host:$port ($user)"
        [[ -n "$error_msg" ]] && warn "  └─ $error_msg"
    done
    
    # 计算耗时
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # 输出验证报告
    info "\n📊 验证报告"
    info "==============================="
    info "总计主机数: $total_hosts"
    info "验证时间: ${duration}秒"
    info "验证失败: $invalid_count"
    info "验证成功: $((total_hosts - invalid_count))"
    
    # 如果是详细模式，显示所有主机状态
    if [[ $VERBOSE -eq 1 ]]; then
        info "\n📝 详细验证结果:"
        info "==============================="
        for host in "${!validation_results[@]}"; do
            info "$host"
            info "  └─ ${validation_results[$host]}"
        done
    fi
    
    return 0
}

function install_rsync() {
    info "检查 rsync 安装状态"

    if command -v rsync >/dev/null 2>&1; then
        info "✅ rsync 已安装: $(rsync --version | head -n1)"
        return 0
    fi

    info "开始安装 rsync..."
    
    # 检测包管理器
    local pkg_manager
    if command -v apt-get >/dev/null 2>&1; then
        pkg_manager="apt-get"
    elif command -v yum >/dev/null 2>&1; then
        pkg_manager="yum"
    else
        error "未找到支持的包管理器"
        return 1
    fi
    
    # 安装 rsync
    info "使用 $pkg_manager 安装..."
    if ! sudo $pkg_manager install -y rsync; then
        error "rsync 安装失败"
        return 1
    fi

    # 验证安装
    if command -v rsync >/dev/null 2>&1; then
        info "✅ rsync 安装成功: $(rsync --version | head -n1)"
        return 0
    else
        error "rsync 安装失败: 未找到可执行文件"
        return 1
    fi
}

function rsync_log() {
    info "开始同步远程日志"
    
    # 安装 rsync
    install_rsync || return 1
    
    # 创建日志目录
    mkdir -p "$(dirname "$RSYNC_LOG_FILE")" || {
        error "创建日志目录失败"
        return 1
    }
    
    local success_count=0
    local failed_count=0
    
    # 检查主机配置
    if ! needHosts; then
        warn "请先配置主机信息"
        return 1    # 使用 return 而不是 exit
    fi

    info "开始同步，共 ${#HOSTS[@]} 个主机"
    
    for host_info in "${HOSTS[@]}"; do
        IFS=',' read -r ip port user password <<< "$host_info"

        # 替换路径中的主机占位符
        local current_path=${RSYNC_LOCAL_PATH/\{host\}/$ip}
        # 确保目标目录存在
        mkdir -p "$current_path"
        
        info "正在从 $ip 同步 $RSYNC_REMOTE_PATH 日志 -> $current_path"

        if rsync -avzP \
            -e "ssh -p $port" \
            "$user@$ip:$RSYNC_REMOTE_PATH" \
            "$current_path" \
            --log-file="$RSYNC_LOG_FILE" \
            2>> "$RSYNC_ERROR_LOG"; then
            
            info "✅ $ip 同步成功"
            ((success_count++))
        else
            warn "❌ $ip 同步失败"
            ((failed_count++))
        fi
    done
    
    # 输出统计信息
    info "\n📊 同步报告"
    info "==============================="
    info "总计主机数: ${#HOSTS[@]}"
    info "同步成功: $success_count"
    info "同步失败: $failed_count"
    info "日志文件: $RSYNC_LOG_FILE"
    info "错误日志: $RSYNC_ERROR_LOG"
    
    # 返回状态
    [[ $failed_count -eq 0 ]]
}

function needHosts(){
    # 检查 HOSTS 数组是否为空
    if [[ ${#HOSTS[@]} -eq 0 ]]; then
        error "没有配置任何主机"
        return 1
    fi
    return 0
}

function set_cron(){
    info "开始设置定时任务..."
    
    # 检查是否安装了 crontab
    if ! command -v crontab >/dev/null 2>&1; then
        error "未安装 crontab，请先安装 cron 服务"
        return 1
    fi

    # 获取当前脚本的绝对路径
    local script_path
    script_path=$(readlink -f "$0")

    # 提示用户输入定时配置
    echo "请选择定时执行的类型："
    echo "1. 每天固定时间"
    echo "2. 每周固定时间"
    echo "3. 每月固定时间"
    echo "4. 自定义 cron 表达式"
    read -r -p "请选择 [1-4]: " cron_type
    
    local cron_expression=""
    case $cron_type in
        1)
            read -r -p "请输入执行时间 (格式 HH:MM): " time
            if [[ ! $time =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                error "时间格式错误"
                return 1
            fi
            IFS=: read -r hour minute <<< "$time"
            cron_expression="$minute $hour * * *"
            ;;
        2)
            read -r -p "请输入星期几 (1-7): " weekday
            read -r -p "请输入执行时间 (格式 HH:MM): " time
            if [[ ! $weekday =~ ^[1-7]$ ]] || [[ ! $time =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                error "输入格式错误"
                return 1
            fi
            IFS=: read -r hour minute <<< "$time"
            cron_expression="$minute $hour * * $weekday"
            ;;
        3)
            read -r -p "请输入日期 (1-31): " day
            read -r -p "请输入执行时间 (格式 HH:MM): " time
            if [[ ! $day =~ ^([1-9]|[12][0-9]|3[01])$ ]] || [[ ! $time =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                error "输入格式错误"
                return 1
            fi
            IFS=: read -r hour minute <<< "$time"
            cron_expression="$minute $hour $day * *"
            ;;
        4)
            read -r -p "请输入 cron 表达式 (格式: '分 时 日 月 周'): " cron_expression
            if [[ ! $cron_expression =~ ^[0-9*/-]+(\ [0-9*/-]+){4}$ ]]; then
                error "cron 表达式格式错误"
                return 1
            fi
            ;;
        *)
            error "无效的选择"
            return 1
            ;;
    esac
    
    read -r -p "请输入要执行的命令: " input_cmd

    # 构建完整的 cron 命令
    local script_cmd="bash $script_path $input_cmd"
    local cron_cmd="$cron_expression $script_cmd"

    # 检查是否已存在相同的定时任务
    if grep -F "$script_path" /tmp/crontab.bak >/dev/null 2>&1; then
        read -p "已存在相关定时任务，是否覆盖？[y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "操作已取消"
            return 0
        fi
        # 删除旧的定时任务
        sed -i "\#$script_path#d" /tmp/crontab.bak
    fi
    
    # 添加新的定时任务
    echo "$cron_cmd" >> /tmp/crontab.bak
    
    # 应用新的 crontab
    if crontab /tmp/crontab.bak; then
        info "定时任务设置成功"
        info "定时表达式: $cron_expression"
        # 显示当前的定时任务列表
        echo "当前定时任务列表："
        crontab -l
    else
        error "定时任务设置失败"
        return 1
    fi
    
    # 清理临时文件
    rm -f /tmp/crontab.bak
    return 0
}

# 清理操作痕迹
function clean_trace() {
    info "开始清理操作痕迹..."

    # 清理命令
    local clean_cmd
    clean_cmd=$(cat << 'EOF'
# 清理历史命令
#history -c
#rm -f ~/.bash_history

# 清理系统日志
#for log in /var/log/auth.log* /var/log/secure* /var/log/messages* /var/log/syslog*; do
#    if [ -f "$log" ]; then
#        echo > "$log" 2>/dev/null || true
#    fi
#done

# 清理临时文件
#rm -rf /tmp/* /var/tmp/* 2>/dev/null || true

# 清理登录记录
[ -f /var/log/wtmp ] && echo > /var/log/wtmp
[ -f /var/log/btmp ] && echo > /var/log/btmp
[ -f /var/log/lastlog ] && echo > /var/log/lastlog

# 清理当前会话历史
#unset HISTFILE
#export HISTSIZE=0
EOF
)
    
    #clean_script="echo > /var/log/wtmp; echo > /var/log/btmp; echo > /var/log/lastlog"
    # 执行清理脚本并处理结果
    if ! batch_exec_command "$clean_cmd"; then
        error "清理操作执行失败"
        return 1
    else
        info "清理操作完成"
        return 0
    fi
}

function scp_files_local_2_remote(){
    info "开始批量分发文件..."

    # 检查主机配置
    if ! needHosts; then
        warn "请先配置主机信息"
        return 1
    fi

    local file_path="$1"
    local remote_path="$2"

    # 如果没有传参，则交互式获取
    if [ -z "$file_path" ]; then
        read -r -p "请输入要分发的文件/文件夹路径: " file_path
    fi

    if [ ! -e "$file_path" ]; then
        error "文件路径不存在: $file_path"
        return 1
    fi

    if [ -z "$remote_path" ]; then
        read -r -p "请输入远程目标路径 (默认: ~): " remote_path
    fi
    remote_path=${remote_path:-"~"}

    # 判断文件类型并设置SCP参数
    local scp_args=()
    if [ -d "$file_path" ]; then
        scp_args=(-r)
        info "正在传输目录: $file_path"
    else
        info "正在传输文件: $file_path"
    fi

    local success_count=0
    local failed_count=0

    for host_info in "${HOSTS[@]}"; do
        IFS=',' read -r host port user password _ <<< "$host_info"
        info "正在传输到 $host:$port ($user)"

        # 连接测试
        if ! test_connection "$host" "$port" "$user"; then
            ((failed_count++))
            continue
        fi

        # 执行SCP传输
        if scp -P "$port" \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=$CONNECT_TIMEOUT \
            "${scp_args[@]}" \
            "$file_path" \
            "$user@$host:$remote_path" 2>/dev/null; then
            
            info "✅ $host 传输成功"
            ((success_count++))
        else
            warn "❌ $host 传输失败"
            ((failed_count++))
        fi
    done

    # 输出统计信息
    info "\n📊 传输报告"
    info "==============================="
    info "总计主机: ${#HOSTS[@]}"
    info "成功数量: $success_count"
    info "失败数量: $failed_count"
    
    return $((failed_count > 0))
}

#---------------------------------usage-----------------------------------

function usage_example(){
    cat << EOF
# 显示帮助
./${SCRIPT_NAME} --help

# 执行命令
./${SCRIPT_NAME} exec-command "uptime"

# 自定义超时和重试
./${SCRIPT_NAME} -t 60 -r 3 exec-command "long_running_command"

# 生成新的SSH密钥
./${SCRIPT_NAME} ssh-keygen

# 批量分发公钥
./${SCRIPT_NAME} ssh-copy-id

# 指定HOSTS配置文件
./${SCRIPT_NAME} --hosts=/path/to/hosts.conf exec-command "uptime"

# 显示主机列表
./${SCRIPT_NAME} list-hosts

# 验证主机配置
./${SCRIPT_NAME} -v validate-hosts

# 传输文件
./${SCRIPT_NAME} scp-files /path/to/local/file /path/to/remote/file
EOF
}

# 帮助信息
function show_help() {
    cat << EOF
用法: $(basename "$0") [选项] <命令>

选项:
    -h, --help          显示帮助信息
    -e, --example       显示使用示例
    -v, --verbose       显示详细输出
    -t, --timeout N     设置超时时间(秒, 默认:30)
    -r, --retries N     设置重试次数(默认:2)
    --hosts FILE        指定主机文件(默认:hosts.conf)

命令:
    1. ssh-keygen       生成SSH密钥
    2. ssh-copy-id      批量传输公钥
    3. exec-command     批量执行命令
    4. exec-script      批量执行脚本
    5. sync-log         同步远程日志
    6. set-cron         设置定时任务
    7. clean            清理痕迹
    8. list-hosts       列出主机列表
    9. validate-hosts   验证主机配置
    10. scp-files       传输文件

参数:
    <命令>              要执行的命令或脚本

说明:
    1. 默认情况下，脚本将使用默认配置文件执行命令。
    2. 如果需要自定义配置文件，请使用 --hosts 参数指定配置文件路径。
    3. 如果需要详细模式执行，请使用 -v 或 --verbose 参数。

主机配置文件格式:
    每行一个主机配置，格式为: 主机,端口,用户名,密码
    示例: server1.example.com,22,root,password123

更多信息:
    使用 -e 或 --example 查看详细使用示例
    使用 -v 或 --verbose 查看详细执行过程

EOF
}

function show_menu() {
    clear
    echo "========== 批量操作菜单 =========="
    echo "1.  生成SSH密钥"
    echo "2.  分发SSH公钥"
    echo "----------------------------------"
    echo "3.  执行远程命令"
    echo "4.  执行远程脚本"
    echo "----------------------------------"
    echo "5.  同步远程日志"
    echo "6.  设置定时任务"
    echo "7.  清理操作痕迹"
    echo "----------------------------------"
    echo "8.  列出主机列表"
    echo "9.  验证主机配置"
    echo "----------------------------------"
    echo "10. 传输文件"
    echo "11. 批量节点安装"
    echo "----------------------------------"
    echo "99. 显示帮助"
    echo "0.  退出程序"
    echo "=================================="
}

# 参数解析函数
function parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -e|--example)
                usage_example
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -t|--timeout)
                if [[ -z "$2" || $2 == -* ]]; then
                    error "选项 $1 需要参数"
                    exit 1
                fi
                if ! [[ $2 =~ ^[0-9]+$ ]]; then
                    error "超时时间必须是数字"
                    exit 1
                fi
                TIMEOUT="$2"
                shift 2
                ;;
            -r|--retries)
                if [[ -z "$2" || $2 == -* ]]; then
                    error "选项 $1 需要参数"
                    exit 1
                fi
                if ! [[ $2 =~ ^[0-9]+$ ]]; then
                    error "重试次数必须是数字"
                    exit 1
                fi
                MAX_RETRIES="$2"
                shift 2
                ;;
            -d|--debug)
                DEBUG=1
                VERBOSE=1
                shift
                ;;
            --timeout=*)
                local value=${1#*=}
                if ! [[ $value =~ ^[0-9]+$ ]]; then
                    error "超时时间必须是数字"
                    exit 1
                fi
                TIMEOUT="$value"
                shift
                ;;
            --retries=*)
                local value=${1#*=}
                if ! [[ $value =~ ^[0-9]+$ ]]; then
                    error "重试次数必须是数字"
                    exit 1
                fi
                MAX_RETRIES="$value"
                shift
                ;;
            --hosts=*)
                local value=${1#*=}
                # 检查 hosts 配置文件
                if [[ ! -f "$value" ]]; then
                    error "配置文件不存在: $value"
                    exit 1
                fi
                load_hosts "$value" || exit 1
                shift
                ;;
            -*)
                error "未知的选项: $1"
                exit 1
                ;;
            *)
                break
                ;;
        esac
    done

    # 循环处理所有命令
    while [ $# -gt 0 ]; do
        case "$1" in
            ssh-keygen|1)
                shift
                ssh_keygen "$@" || return $?
                ;;
            ssh-copy-id|2)
                shift
                ssh_copy_id "$@" || return $?
                ;;
            exec-command|3)
                shift
                if [ $# -eq 0 ]; then
                    error "exec-command 需要指定要执行的命令"
                    return 1
                fi
                batch_exec_command "$@" || return $?
                ;;
            exec-script|4)
                shift
                if [ $# -eq 0 ]; then
                    error "exec-script 需要指定脚本文件"
                    return 1
                fi
                batch_exec_script "$@" || return $?
                ;;
            sync-log|5)
                shift
                rsync_log "$@" || return $?
                ;;
            set-cron|6)
                shift
                set_cron "$@" || return $?
                ;;
            clean|7)
                shift
                clean_trace "$@" || return $?
                ;;
            list-hosts|8)
                shift
                list_hosts "$@" || return $?
                ;;
            validate-hosts|9)
                shift
                validate_hosts "$@" || return $?
                ;;
            scp-files|10)
                shift
                scp_files_local_2_remote "$@" || return $?
                ;;
            *)
                error "未知的命令: $1"
                return 1
                ;;
        esac
        shift
    done
}


function process_command() {
    local choice
    read -r -p "请选择操作 [0-11]: " choice
    
    case "$choice" in
        1)
            ssh_keygen || return $?
            ;;
        2)
            ssh_copy_id || return $?
            ;;
        3)
            read -p "请输入要执行的命令: " cmd
            [[ -z "$cmd" ]] && {
                error "命令不能为空"
                return 1
            }
            batch_exec_command "$cmd" || return $?
            ;;
        4)
            read -p "请输入脚本路径: " script
            [[ ! -f "$script" ]] && {
                error "脚本文件不存在: $script"
                return 1
            }
            batch_exec_script "$script" || return $?
            ;;
        5)
            rsync_log || return $?
            ;;
        6)
            set_cron || return $?
            ;;
        7)
            clean_trace || return $?
            ;;
        8)
            list_hosts || return $?
            ;;
        9)
            validate_hosts || return $?
            ;;
        10)
            scp_files_local_2_remote || return $?
            ;;
        11)
            batch_exec_install || return $?
            ;;
        99)
            show_help
            ;;
        0)
            info "程序退出"
            exit 0
            ;;
        *)
            error "无效的选择: $choice"
            return 1
            ;;
    esac
    
    read -r -p "按回车键继续..."
    return 0
}

# 主函数
function main() {
    # 检查必要条件
    check_single_instance || exit 1
    deps_check
    #load_config || exit 1
    load_hosts "" || exit 1
    list_hosts || warn "没有可用的主机"

    info "欢迎使用批量操作工具"

    # 解析参数并执行命令
    parse_args "$@"

    # 进入交互式菜单循环
    while true; do
        show_menu
        process_command || {
            warn "操作失败，按回车键继续..."
            read -r
        }
    done
}

# 执行主函数
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"