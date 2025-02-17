#!/bin/sh

CURRENT_DIR=$(
   cd "$(dirname "$0")" || exit
   pwd
)

BASE_PATH="/opt/ray-cli"
APP_DOCKER_IMAGE="i94d5w8e/ray-cli"
APP_COMPOSE_YML="docker-compose.yml"

SCRIPT_URL="https://goo.su/Bs1w0B6"
PACKAGE_DOWNLOAD_URL="https://goo.su/dqvmXS"
PACKAGE_FILE_TAR="ray-cli.zip"

APP_API_HOST=""
APP_API_ADD_NODE="$APP_API_HOST/api_v1/nodes/add"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

err() {
    printf "${red}%s${plain}\n" "$*" >&2
}

warn() {
    printf "${red}%s${plain}\n" "$*"
}

success() {
    printf "${green}%s${plain}\n" "$*"
}

info() {
    printf "${yellow}%s${plain}\n" "$*"
}

println() {
    printf "$*\n"
}

sudo() {
    myEUID=$(id -ru)
    if [ "$myEUID" -ne 0 ]; then
        if command -v sudo > /dev/null 2>&1; then
            command sudo "$@"
        else
            err "错误: 您的系统未安装 sudo，因此无法进行该项操作。"
            exit 1
        fi
    else
        "$@"
    fi
}

mustn() {
    set -- "$@"
    
    if ! "$@" >/dev/null 2>&1; then
        err "运行 '$*' 失败。"
        exit 1
    fi
}

deps_check() {
    deps="curl wget unzip grep"
    for dep in $deps; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            err "未找到依赖 $dep,请先安装。"
            exit 1
        fi
    done
}


installation_check() {
    if docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND="docker compose"
        if sudo $DOCKER_COMPOSE_COMMAND ls | grep -qw "$BASE_PATH/$APP_COMPOSE_YML" >/dev/null 2>&1; then
            FIND_IMAGE=$(sudo docker images --format "{{.Repository}}":"{{.Tag}}" | grep -w "$APP_DOCKER_IMAGE")
            if [ -n "$FIND_IMAGE" ]; then
                echo "存在带有 $APP_DOCKER_IMAGE 仓库的 Docker 镜像："
                echo "$FIND_IMAGE"
                return
            else
                echo "未找到带有 $APP_DOCKER_IMAGE 仓库的 Docker 镜像。"
            fi
        fi        
    fi

    if [ -f "$BASE_PATH" ]; then
        FRESH_INSTALL=0
    fi
}

install_docker() {
    if which docker >/dev/null 2>&1; then
        docker_version=$(docker --version | grep -oE '[0-9]+\.[0-9]+' | head -n 1)
        echo "当前docker版本: $docker_version"
    else
        echo "安装docker"
        curl -Lks https://linuxmirrors.cn/docker.sh -o /tmp/docker.sh
        # 检查 curl 的退出状态码
        if [ $? -ne 0 ]; then
            echo "下载失败,curl 命令出错。"
            exit 1
        fi

        # 检查文件是否存在
        if [ ! -f "/tmp/docker.sh" ]; then
            echo "下载失败"
            exit 1
        fi

        bash /tmp/docker.sh \
                --source mirrors.aliyun.com/docker-ce \
                --source-registry dockerproxy.net \
                --protocol http \
                --install-latest true \
                --close-firewall true \
                --ignore-backup-tips
    fi
    
}


init() {
    deps_check
    installation_check
    install_docker
}

update_script() {
    echo "> 更新脚本"

    HTTP_RESPONSE=$(curl -Lks $SCRIPT_URL -w "%{http_code}" -o /tmp/install.sh)
    # 检查 curl 的退出状态码
    if [ $? -ne 0 ]; then
        echo "下载失败,curl 命令出错。"
        exit 1
    fi

    # 检查文件是否存在
    if [ ! -f "/tmp/install.sh" ]; then
        echo "下载失败"
        exit 1
    fi

    if [ "$HTTP_RESPONSE" -eq 404 ]; then
        echo "未找到脚本"
        exit 1
    fi

    mv -f /tmp/install.sh ./install.sh && chmod a+x ./install.sh

    echo "3s后执行新脚本"
    sleep 3s
    clear
    exec ./install.sh
    exit 0
}

before_show_menu() {
    echo && info "* 按回车返回主菜单 *" && read temp
    show_menu
}


download(){
    echo "下载安装包: ${PACKAGE_DOWNLOAD_URL}"

    HTTP_RESPONSE=$(curl -Lks "$PACKAGE_DOWNLOAD_URL" -w "%{http_code}" -o $PACKAGE_FILE_TAR)
    if [ ! -f $PACKAGE_FILE_TAR ]; then
        echo "下载失败"
        exit 1
    fi

    if [ "$HTTP_RESPONSE" -eq 404 ]; then
        echo "未找到脚本"
        exit 1
    fi

    case "$PACKAGE_FILE_TAR" in
        *.zip)
            unzip -o -d "$BASE_PATH" "$PACKAGE_FILE_TAR"
            ;;
        *.tar.gz)
            tar zxf "$PACKAGE_FILE_TAR" -C "$BASE_PATH"
            if [ $? != 0 ]; then
                echo "解压失败"
                rm -f "$PACKAGE_FILE_TAR"
                exit 1
            fi
            ;;
        *)
            echo "不支持的文件格式"
            exit 1
            ;;
    esac

    echo "已完成下载安装"
}

install() {
    echo "> 安装"

    if [ ! "$FRESH_INSTALL" = 0 ]; then
        sudo mkdir -p $BASE_PATH
    else
        echo "您可能已经安装过($BASE_PATH)，重复安装会覆盖数据，请注意备份。"
        printf "是否退出安装? [Y/n]"
        read -r input
        case $input in
        [yY][eE][sS] | [yY])
            echo "退出安装"
            exit 0
            ;;
        [nN][oO] | [nN])
            echo "继续安装"
            ;;
        *)
            echo "退出安装"
            exit 0
            ;;
        esac
    fi

    download
    $DOCKER_COMPOSE_COMMAND -f ${BASE_PATH}/$APP_COMPOSE_YML pull

    changeHostAndKey 1
    changeConfigNodeId 1

    if [ $# = 0 ]; then
        before_show_menu
    fi
}

restart_and_update() {
    echo "> 重启并更新"

    _cmd="restart_and_update_docker"

    if eval "$_cmd"; then
        success "重启成功"
    else
        err "重启失败，可能是因为启动时间超过了两秒，请稍后查看日志信息"
    fi

    if [ $# = 0 ]; then
        before_show_menu
    fi
}

restart_and_update_docker() {
    sudo $DOCKER_COMPOSE_COMMAND -f ${BASE_PATH}/$APP_COMPOSE_YML pull
    sudo $DOCKER_COMPOSE_COMMAND -f ${BASE_PATH}/$APP_COMPOSE_YML down
    sleep 2
    sudo $DOCKER_COMPOSE_COMMAND -f ${BASE_PATH}/$APP_COMPOSE_YML up -d
}

show_log() {
    echo "> 获取日志"

    show_dashboard_log_docker

    if [ $# = 0 ]; then
        before_show_menu
    fi
}

show_dashboard_log_docker() {
    sudo $DOCKER_COMPOSE_COMMAND -f ${BASE_PATH}/$APP_COMPOSE_YML logs -f --tail 500
}

uninstall() {
    echo "> 卸载"

    warn "警告：卸载前请备份您的文件。"
    printf "继续？ [y/N] "
    read -r input
    case $input in
    [yY][eE][sS] | [yY])
        info "卸载中…"
        ;;
    [nN][oO] | [nN])
        return
        ;;
    *)
        return
        ;;
    esac

    uninstall_dashboard_docker

    if [ $# = 0 ]; then
        before_show_menu
    fi
}

uninstall_dashboard_docker() {
    sudo $DOCKER_COMPOSE_COMMAND -f ${BASE_PATH}/$APP_COMPOSE_YML down
    sudo rm -rf $BASE_PATH
    sudo docker rmi -f $APP_DOCKER_IMAGE >/dev/null 2>&1
}

bbr(){
    curl -Lks https://git.io/kernel.sh -o /tmp/kernel.sh
    # 检查 curl 的退出状态码
    if [ $? -ne 0 ]; then
        echo "下载失败,curl 命令出错。"
        exit 1
    fi

    # 检查文件是否存在
    if [ ! -f "/tmp/kernel.sh" ]; then
        echo "下载失败"
        exit 1
    fi

    bash /tmp/kernel.sh
}

addNodeAndApply(){
    echo "> 添加节点并应用"

    if ! command -v "jq" >/dev/null 2>&1; then
        err "未找到依赖 jq, 请先安装。"
        exit 1
    fi

    local_api_host="${ENV_APIHOST:-}"
    echo "当前环境变量: ENV_APIHOST: $local_api_host"
    if [ "${local_api_host}" != "" ]; then
        APP_API_HOST=$local_api_host
    fi
    
    printf "请输入请求数据文件路径(如：/path/node.json. 默认是当前目录下的node.json): "
    read -r data_json_path
    if [ -z "${data_json_path}" ] && [ -f "$CURRENT_DIR/node.json" ]; then
        data_json_path=$CURRENT_DIR/node.json
    fi
    
    if [ -z "${data_json_path}" ]; then
        printf "请输入 API KEY: "
        read -r app_api_key

        printf "请输入节点名称: "
        read -r name

        printf "请输入节点繁体名称: "
        read -r name_hant

        printf "请输入节点英文名称: "
        read -r name_en

        printf "请输入节点类型(V2Ray-VLESS, V2Ray, Trojan): "
        read -r nodetype

        printf "请输入节点等级(0-6): "
        read -r class
        class=${class:-0}
        
        printf "请输入节点地址: "
        read -r address

        printf "请输入节点的流量倍率: "
        read -r trafficrate
        trafficrate=${trafficrate:-1}

        printf "请输入节点流量上限(GB): "
        read -r trafficllimit
        trafficllimit=${trafficllimit:-0}

        printf "请输入节点限速(Mbps): "
        read -r speedlimit
        speedlimit=${speedlimit:-0}

        printf "节点是否启用(0/1): "
        read -r enable
        enable=${enable:-0}

        if [ "${nodetype}" = "V2Ray-VLESS" ]; then
            printf "请输入VLESS配置: "
            read -r customconf
        fi

        response=$(curl -s --location --request POST "$APP_API_ADD_NODE" \
                --header 'X-Requested-With: XMLHttpRequest' \
                --header 'User-Agent: curl(shell)' \
                --header 'Content-Type: application/json' \
                --data-raw "{
                    \"apikey\": \"$app_api_key\",
                    \"nodes\": [
                        {
                            \"name\": \"$name\",
                            \"name_hant\": \"$name_hant\",
                            \"name_en\": \"$name_en\",
                            \"enable\": $enable,
                            \"address\": \"$address\",
                            \"nodetype\": \"$nodetype\",
                            \"class\": $class,
                            \"trafficrate\": $trafficrate,
                            \"trafficllimit\": $trafficllimit,
                            \"speedlimit\": $speedlimit,
                            \"resetday\": 1,
                            \"customconf\": \"$customconf\"
                        }
                    ]
                }")
    else
        response=$(curl -s --location --request POST --data-binary "@$data_json_path" "$APP_API_ADD_NODE" \
                --header 'X-Requested-With: XMLHttpRequest' \
                --header 'User-Agent: curl(shell)' \
                --header 'Content-Type: application/json')
    fi
    echo "响应结果: $response"

    # 检查响应结果中的 code 字段
    code=$(echo "$response" | jq -r '.code')
    message=$(echo "$response" | jq -r '.msg')
    if [ "$code" -eq 401 ]; then
        err "错误：$message"
        exit 1
    elif [ "$code" -ne 1 ]; then
        err "错误: 添加失败，消息: $(echo "$response" | jq -r '.msg')"
        exit 1
    fi


    # 获取 nodes 中的第一个节点的 result 和 id
    node=$(echo "$response" | jq -c '.data.nodes[0]')
    if [ -z "$node" ]; then
        err "错误: 未找到节点数据。"
        exit 1
    fi

    echo "$node"
    result=$(echo "$node" | jq -r '.result')
    id=$(echo "$node" | jq -r '.id')
    echo "节点 ID: $id, 结果: $result"

    if [ "${result}" = "true" ]; then
        echo "节点添加成功,修改配置并重启服务"

        sed -i "s|NodeID: .\+|NodeID: $id|g" $BASE_PATH/cli/config/config.yml
        $DOCKER_COMPOSE_COMMAND -f ${BASE_PATH}/$APP_COMPOSE_YML restart
    fi
}

changeConfigNodeId(){
    echo "> 修改节点id并重启服务"

    printf "请输入节点id(可跳过): "
    read -r nodeId 

    if [ "${nodeId}" != "" ]; then
        sed -i "s|NodeID: .\+|NodeID: $nodeId|g" $BASE_PATH/cli/config/config.yml
        $DOCKER_COMPOSE_COMMAND -f ${BASE_PATH}/$APP_COMPOSE_YML restart
    fi
    
    if [ $# = 0 ]; then
        before_show_menu
    fi
}

changeHostAndKey(){
    echo "> 修改APIKey和Host"
    
    if [ ! -d "$BASE_PATH" ]; then
        echo "请先安装"
        before_show_menu
    fi

    local_api_host="${ENV_APIHOST:-}"
    echo "当前API网站: ENV_APIHOST: $local_api_host"
    if [ "${local_api_host}" = "" ]; then
        printf "请输入API HOST: "
        read -r apihost
        local_api_host="${apihost:-}"
    fi

    if [ "${local_api_host}" != "" ]; then
        APP_API_HOST=$local_api_host
        sed -i "s|ApiHost: .\+|ApiHost: \"$local_api_host\"|g" $BASE_PATH/cli/config/config.yml
    fi
    
    local_apikey="${ENV_APIKEY:-}"
    echo "当前API KEY: ENV_APIKEY: $local_apikey"
    if [ "${local_apikey}" = "" ]; then
        printf "请输入API KEY: "
        read -r apikey
        local_apikey="${apikey:-}"
    fi

    if [ "${local_apikey}" != "" ]; then
        sed -i "s|ApiKey: .\+|ApiKey: \"$local_apikey\"|g" $BASE_PATH/cli/config/config.yml
    fi

    if [ "${local_api_host}" != "" ] || [ "${local_apikey}" != "" ]; then
        $DOCKER_COMPOSE_COMMAND -f ${BASE_PATH}/$APP_COMPOSE_YML restart
    fi
    
    if [ $# = 0 ]; then
        before_show_menu
    fi
}

showConfig(){
    echo "> 查看配置"
    cat $BASE_PATH/cli/config/config.yml
    if [ $# = 0 ]; then
        before_show_menu
    fi
}

show_usage() {
    echo "脚本使用方法: "
    echo "支持(环境变量: ENV_APIKEY, ENV_APIHOST). "
    echo "--------------------------------------------------------"
    echo "./install.sh                    - 显示菜单"
    echo "./install.sh install            - 安装客户端"
    echo "./install.sh restart_and_update - 更新客户端并重启"
    echo "./install.sh show_log           - 查看客户端日志"
    echo "./install.sh uninstall          - 卸载客户端"
    echo "./install.sh brr                - 安装BBR"
    echo "--------------------------------------------------------"
}

show_menu() {
    println "${green}${plain}脚本使用方法:"
    println "${green}${plain}支持环境变量: ENV_APIKEY, ENV_APIHOST "
    println "${green}1.${plain}  安装节点客户端"
    println "${green}2.${plain}  更新客户端并重启"
    println "${green}3.${plain}  查看客户端日志"
    println "${green}4.${plain}  卸载客户端"
    echo "————————————————"
    println "${green}5.${plain}  更新脚本"
    echo "————————————————"
    println "${green}6.${plain}  安装BBR"
    println "${green}7.${plain}  修改节点配置"
    println "${green}8.${plain}  新增节点并应用"
    println "${green}9.${plain}  查看节点配置"
    echo "————————————————"
    println "${green}0.${plain}  退出脚本"

    echo && printf "请输入选择 [0-8]: " && read -r num
    case "${num}" in
        0)
            exit 0
            ;;
        1)
            install
            ;;
        2)
            restart_and_update
            ;;
        3)
            show_log
            ;;
        4)
            uninstall
            ;;
        5)
            update_script
            ;;
        6)
            bbr
            ;;
        7)
            changeHostAndKey 0
            changeConfigNodeId 0
            ;;
        8)
            addNodeAndApply
            ;;
        9)
            showConfig 0
            ;;
        *)
            err "请输入正确的数字 [0-8]"
            ;;
    esac
}

init

if [ $# -gt 0 ]; then
    case $1 in
        "install")
            install 0
            ;;
        "restart_and_update")
            restart_and_update 0
            ;;
        "show_log")
            show_log 0
            ;;
        "uninstall")
            uninstall 0
            ;;
        "update_script")
            update_script 0
            ;;
        "bbr")
            bbr 0
            ;;
        *) show_usage ;;
    esac
else
    show_menu
fi
