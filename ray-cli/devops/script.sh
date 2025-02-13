#!/bin/bash

# 日志路径
RAY_CLI_PATH="/home/ray-cli"
LOG_PATH=$RAY_CLI_PATH/cli/config/logs

function set_access_path(){
    echo "设置日志路径"
    mkdir -p $LOG_PATH
    echo "替换日志路径"
    sed -i 's|AccessPath: .*|AccessPath: /etc/Ray-Cli/logs|' $RAY_CLI_PATH/cli/config/config.yml

    # 将文件类型转换为 Unix 格式
    #sed -i 's/\r$//' $RAY_CLI_PATH/cli/config/config.yml
}

function restart_docker(){
    echo "重启docker"
    cd $RAY_CLI_PATH || exit 1
    docker compose pull
    docker compose up -d
}

function set_cron(){
    echo "设置定时任务"
    # 检查是否已经存在相同的定时任务
    if ! crontab -l | grep -q "find $LOG_PATH -type f -mtime +7 -delete"; then
        (crontab -l 2>/dev/null; echo "0 1 * * * find $LOG_PATH -type f -mtime +7 -delete") | crontab -
        crontab -l
        echo "定时任务已设置"
    else
        echo "定时任务已存在"
    fi
}

function remove_cron(){
    echo "删除定时任务"
    crontab -l | grep -v "find $LOG_PATH -type f -mtime +7 -delete" | crontab -
    echo "定时任务已删除"
}

function install_rsync(){
    echo "安装rsync"

    if command -v rsync >/dev/null 2>&1; then
        echo "rsync 已安装"
        return
    fi

    if ! apt-get install -y rsync; then
        echo "apt-get 安装失败，尝试使用 yum 安装"
        sudo yum install -y rsync
    fi

    # 判断 rsync 是否安装成功
    if command -v rsync >/dev/null 2>&1; then
        echo "rsync 安装成功"
        rsync --version
    else
        echo "rsync 安装失败"
    fi
}

set_access_path
restart_docker
remove_cron
set_cron
install_rsync