#!/bin/bash
# redis-tui.sh - Redis 集群管理工具，命令行版（bash + redis-cli）
#
# 用法: ./redis-tui.sh [host] [port] [password]
#       ./redis-tui.sh --profile "连接名"（交互输入密码）
#   1  查询单个 Key
#   2  搜索 Key：输入关键字即可模糊匹配，表格显示类型 / 过期时间 / 大小，按前缀分组；
#      可按"仅无过期"、类型、前缀筛选，按序号查看值和批量删除
#   3  Redis 监控：各节点内存、连接、每秒命令、命中率、主从状态，可自动刷新
#
# 依赖: bash 4 及以上、redis-cli（优先用同目录下的 redis-cli，其次是 PATH 里的；
#       也可以用环境变量 REDIS_CLI 指定路径）
#
# 在装了 WSL 的 Windows 机器上，双击同目录的 redis-tui.cmd 启动：它把本脚本放进 WSL 里运行，
# 每次 redis-cli 调用不到 0.1 秒。直接在 Git Bash 里运行也能用，但每次调用要经 wsl.exe 中转，约 1 秒

# ============ 基础设置 ============
# 字符串一律按字节处理：下面计算中文的显示宽度、给 Key 排序都依赖这一点
export LC_ALL=C
shopt -s extglob

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REDIS_CLI="${REDIS_CLI:-}"
if [ -z "$REDIS_CLI" ]; then
    if [ -x "$SELF_DIR/redis-cli" ]; then REDIS_CLI="$SELF_DIR/redis-cli"; else REDIS_CLI="redis-cli"; fi
fi

CONFIG_HOST=""; CONFIG_PORT=""; CONFIG_PASS=""
CONFIG_NAME=""; CONFIG_USER=""; CONFIG_TLS=0; CONFIG_CA=""; CONFIG_TLS_NAME=""
PROFILE_DIR="${REDIS_TUI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/redis-tui/connections}"
ALLOW_WRITES=0
LAST_PATTERN=""
SEARCH_LIMIT=2000; SEARCH_SECONDS=15
if [[ ${REDIS_TUI_SEARCH_LIMIT:-} =~ ^[1-9][0-9]{0,4}$ ]] && [ "$REDIS_TUI_SEARCH_LIMIT" -le 10000 ]; then
    SEARCH_LIMIT=$REDIS_TUI_SEARCH_LIMIT
fi
if [[ ${REDIS_TUI_SEARCH_SECONDS:-} =~ ^[1-9][0-9]{0,2}$ ]] && [ "$REDIS_TUI_SEARCH_SECONDS" -le 120 ]; then
    SEARCH_SECONDS=$REDIS_TUI_SEARCH_SECONDS
fi

if [ ! -x "$REDIS_CLI" ] && ! command -v "$REDIS_CLI" >/dev/null 2>&1; then
    echo "找不到 redis-cli: $REDIS_CLI"
    echo "请把它放到本脚本所在目录，或用环境变量 REDIS_CLI 指定路径"
    exit 1
fi

# ============ 颜色 ============
if [ -t 1 ] && [ "${TERM:-}" != dumb ] && [ -z "${NO_COLOR:-}" ]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'
    CYAN=$'\033[36m'; MAGENTA=$'\033[35m'; GRAY=$'\033[37m'; WHITE=$'\033[97m'
    DARKGRAY=$'\033[90m'; NC=$'\033[0m'
    BRAND=$'\033[1;97;41m'; ACCENT=$'\033[1;36m'
    READ_BADGE=$'\033[97;44m'; WRITE_BADGE=$'\033[30;43m'; TABLE_BAND=$'\033[97;100m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; MAGENTA=""; GRAY=""; WHITE=""; DARKGRAY=""; NC=""
    BRAND=""; ACCENT=""; READ_BADGE=""; WRITE_BADGE=""; TABLE_BAND=""
fi

# ============ 输出与输入 ============
say()  { printf '%s%s%s\n' "$2" "$1" "$NC"; }
sayn() { printf '%s%s%s' "$2" "$1" "$NC"; }

clear_screen() {
    [ -t 1 ] || return 0
    clear 2>/dev/null || printf '\033[H\033[2J';
}

tty_width() {
    local w=""
    if [ -n "${REDIS_TUI_WIDTH:-}" ] && [ "$REDIS_TUI_WIDTH" -ge 40 ] 2>/dev/null; then echo "$REDIS_TUI_WIDTH"; return; fi
    w=$(tput cols 2>/dev/null) && [ "$w" -ge 40 ] 2>/dev/null && { echo "$w"; return; }
    echo 120
}

# 一页显示多少行：终端高度减去表头和命令区
page_size() {
    local grouped="$1" h=""
    if [ -n "${REDIS_TUI_PAGE_SIZE:-}" ] && [ "$REDIS_TUI_PAGE_SIZE" -ge 1 ] 2>/dev/null; then echo "$REDIS_TUI_PAGE_SIZE"; return; fi
    h=$(tput lines 2>/dev/null) && [ "$h" -ge 12 ] 2>/dev/null || h=30
    h=$(( h - 18 ))
    [ "$grouped" = 1 ] && h=$(( h / 2 ))
    [ "$h" -lt 1 ] && h=1
    [ "$h" -gt 200 ] && h=200
    echo "$h"
}

# 显示宽度：ASCII 算 1 格，非 ASCII（中文等）算 2 格。
# 依赖 LC_ALL=C：${#s} 是字节数；一个 3 字节的字符多占 1 个字节，4 字节的多占 2 个，减掉即可
str_width() {
    local s="$1" n3 n4=0
    case "$s" in
        *[$'\x80'-$'\xff']*)
            n3=$(printf '%s' "$s" | tr -cd '\340-\367' | wc -c)
            case "$s" in *[$'\xf0'-$'\xf7']*) n4=$(printf '%s' "$s" | tr -cd '\360-\367' | wc -c) ;; esac
            echo $(( ${#s} - n3 - 2 * n4 )) ;;
        *) echo "${#s}" ;;
    esac
}

# 按显示宽度截断，截掉时末尾加三个点（省略号在中文终端里是全角的，会多占一格） → REPLY
str_cut() {
    local s="$1" max=$(( $2 - 3 )) out='' w=0 len cw
    while [ -n "$s" ]; do
        case "$s" in
            [$'\x01'-$'\x7f']*) len=1; cw=1 ;;
            [$'\xc0'-$'\xdf']*) len=2; cw=2 ;;
            [$'\xe0'-$'\xef']*) len=3; cw=2 ;;
            *) len=4; cw=2 ;;
        esac
        if [ $(( w + cw )) -gt "$max" ]; then break; fi
        out+="${s:0:len}"
        w=$(( w + cw ))
        s="${s:len}"
    done
    REPLY="$out..."
}

# 排成一列：太长就截断，再补空格到指定的显示宽度 → REPLY。$3 为 1 时右对齐
pad() {
    local s="$1" w="$2" right="${3:-0}" p
    if [ "$(str_width "$s")" -gt "$w" ]; then str_cut "$s" "$w"; s="$REPLY"; fi
    p=$(( w - $(str_width "$s") ))
    [ "$p" -lt 0 ] && p=0
    if [ "$right" = 1 ]; then printf -v REPLY '%*s%s' "$p" '' "$s"; else printf -v REPLY '%s%*s' "$s" "$p" ''; fi
}

say_fit() {
    local line="$1"
    line=${line//[[:cntrl:]]/?}
    if [ "$(str_width "$line")" -gt "$3" ]; then str_cut "$line" "$3"; line="$REPLY"; fi
    say "$line" "$2"
}

trim() { local v="${1#+([[:space:]])}"; REPLY="${v%%+([[:space:]])}"; }

# 读一行到 REPLY；输入结束时返回非 0
read_line() { IFS= read -r -p "$1"; }

pause() { IFS= read -r -p '按回车继续...' _ || true; }

rule() {
    local n=$(( $1 - 3 )) line
    [ "$n" -lt 10 ] && n=10
    printf -v line '%*s' "$n" ''
    say "  ${line// /─}" "$DARKGRAY"
}

show_header() {
    local width="${1:-$(tty_width)}" mode='[只读]' mode_color="$READ_BADGE" profile_label
    if [ "$ALLOW_WRITES" = 1 ]; then mode='[可写]'; mode_color="$WRITE_BADGE"; fi
    echo
    printf '  '
    sayn ' REDIS ' "$BRAND"
    say '  集群管理' "$WHITE"
    if [ -n "$CONFIG_HOST" ]; then
        printf '  '
        sayn "$mode" "$mode_color"
        sayn '   节点 ' "$GRAY"
        say_fit "$CONFIG_HOST:$CONFIG_PORT" "$WHITE" $(( width - 17 ))
        if [ -n "$CONFIG_NAME" ] || [ "$CONFIG_TLS" = 1 ]; then
            profile_label="${CONFIG_NAME:-临时连接}"
            [ "$CONFIG_TLS" != 1 ] || profile_label+=" · TLS"
            say_fit "  配置 $profile_label" "$GRAY" $(( width - 1 ))
        fi
    else
        echo
    fi
    rule "$width"
}

# ============ 格式化（结果都放进 REPLY） ============
fmt_ttl() {
    local s="$1"
    case "$s" in
        ''|-|-) REPLY='-'; return ;;
        -1) REPLY='永不过期'; return ;;
        -2) REPLY='已失效'; return ;;
    esac
    [[ "$s" =~ ^[0-9]+$ ]] || { REPLY='-'; return; }
    if [ "$s" -ge 86400 ]; then REPLY="$(( s / 86400 ))天$(( (s % 86400) / 3600 ))小时"
    elif [ "$s" -ge 3600 ]; then REPLY="$(( s / 3600 ))小时$(( (s % 3600) / 60 ))分钟"
    elif [ "$s" -ge 60 ]; then
        local sec=$(( s % 60 ))
        if [ "$sec" -gt 0 ]; then REPLY="$(( s / 60 ))分钟${sec}秒"; else REPLY="$(( s / 60 ))分钟"; fi
    else REPLY="${s}秒"
    fi
}

fmt_size() {
    local b="$1"
    [[ "$b" =~ ^[0-9]+$ ]] || { REPLY='-'; return; }
    if [ "$b" -lt 1024 ]; then REPLY="${b} B"
    elif [ "$b" -lt 1048576 ]; then REPLY=$(awk -v x="$b" 'BEGIN { printf "%.1f KB", x / 1024 }')
    elif [ "$b" -lt 1073741824 ]; then REPLY=$(awk -v x="$b" 'BEGIN { printf "%.1f MB", x / 1048576 }')
    else REPLY=$(awk -v x="$b" 'BEGIN { printf "%.1f GB", x / 1073741824 }')
    fi
}

fmt_uptime() {
    local s="$1"
    [[ "$s" =~ ^[0-9]+$ ]] || { REPLY='-'; return; }
    if [ "$s" -ge 86400 ]; then REPLY="$(( s / 86400 ))天$(( (s % 86400) / 3600 ))小时"
    elif [ "$s" -ge 3600 ]; then REPLY="$(( s / 3600 ))小时$(( (s % 3600) / 60 ))分"
    else REPLY="$(( s / 60 ))分$(( s % 60 ))秒"
    fi
}

# 整数加千位分隔符
fmt_count() {
    local s="$1" out=''
    [[ "$s" =~ ^[0-9]+$ ]] || { REPLY='-'; return; }
    while [ ${#s} -gt 3 ]; do out=",${s: -3}$out"; s=${s:0:${#s}-3}; done
    REPLY="$s$out"
}

type_color() {
    case "$1" in
        string) TCOLOR="$GREEN" ;;
        hash) TCOLOR="$YELLOW" ;;
        list) TCOLOR="$CYAN" ;;
        set) TCOLOR="$MAGENTA" ;;
        zset) TCOLOR="$BLUE" ;;
        stream) TCOLOR="$CYAN" ;;
        *) TCOLOR="$GRAY" ;;
    esac
}

# ============ redis-cli ============
# 两种传输都从进程环境读取密码。ACL nopass 用户仍需发送用户名和空密码。
exec_redis_cli() {
    local -a options=()
    if [ -n "$CONFIG_USER$CONFIG_PASS" ]; then export REDISCLI_AUTH="$CONFIG_PASS"
    else unset REDISCLI_AUTH; fi
    if [ "$CONFIG_TLS" = 1 ]; then
        if [ "${1:-}" = -c ]; then options+=(--follow); shift; fi
        options+=(--host "$2" --port "$4" --user "$CONFIG_USER" --ca "$CONFIG_CA" --server-name "$CONFIG_TLS_NAME")
        shift 4
        exec python3 "$SELF_DIR/redis-tls.py" --cli "$REDIS_CLI" "${options[@]}" -- "$@"
    else
        [ -z "$CONFIG_USER" ] || options+=(--user "$CONFIG_USER")
        exec "$REDIS_CLI" "${options[@]}" "$@"
    fi
}

run_redis_cli() ( exec_redis_cli "$@" )

rex() { run_redis_cli -c -h "$CONFIG_HOST" -p "$CONFIG_PORT" "$@" 2>/dev/null; }
rex_node() { run_redis_cli -h "$1" -p "$2" "${@:3}" 2>/dev/null; }
# 批量执行：标准输入里每行一条命令，回复按原始格式输出。只用于回复是单行的命令。
# REDISCLI_BATCH 告诉 redis-cli 转发器：这次要把标准输入带过去
rex_raw() { REDISCLI_BATCH=1 run_redis_cli -h "$1" -p "$2" --raw 2>/dev/null; }

# 节点连不上时的原因（不丢弃错误输出，取第一行）
node_reason() { run_redis_cli -h "$1" -p "$2" PING 2>&1 | head -n 1; }

# 给 redis-cli 批量参数加引号，结果放在 REPLY。
cli_quote() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    printf -v REPLY '"%s"' "$s"
}

# 批量执行并把回复整理成每条命令一个，放进 REP[]。
# redis-cli 在错误回复（MOVED / ERR / NOAUTH ...）后面会多输出一个空行，这里把它去掉。
# 整理后的回复数和命令数对不上时返回非 0（调用方按"都没取到"处理）
batch() {
    local addr="$1" cmds="$2" n line
    n=0
    if [ -n "$cmds" ]; then n=$(printf '%s\n' "$cmds" | grep -c .); fi
    REP=()
    if [ -n "${search_file:-}" ]; then
        search_cli "$cmds" -h "${addr%%:*}" -p "${addr##*:}" --raw || return 1
    fi
    while IFS= read -r line; do
        REP+=("$line")
        if [[ "$line" = *" "* ]]; then
            if IFS= read -r line; then [ -n "$line" ] && REP+=("$line"); fi
        fi
    done < <(
        if [ -n "${search_file:-}" ]; then cat "$search_file"
        else printf '%s\n' "$cmds" | rex_raw "${addr%%:*}" "${addr##*:}"; fi
    )
    [ "${#REP[@]}" -eq "$n" ]
}

# ============ 登录 ============
set_login() {
    local r
    say '  正在测试连接...' "$DARKGRAY"
    if r=$(run_redis_cli -h "$CONFIG_HOST" -p "$CONFIG_PORT" PING 2>&1) && [ "$r" = PONG ]; then
        ALLOW_WRITES=0
        say '  √ 连接成功' "$GREEN"
        return 0
    fi
    say "  × 连接失败: $r" "$RED"
    pause
    return 1
}

toggle_write_mode() {
    if [ "$ALLOW_WRITES" = 1 ]; then ALLOW_WRITES=0; return; fi
    say "  启用写入 · $CONFIG_HOST:$CONFIG_PORT" "$YELLOW"
    read_line '  输入 WRITE 确认 > ' || return 0
    if [ "$REPLY" = WRITE ]; then ALLOW_WRITES=1; fi
}

# 文件逐行存放版本、名称、主机、端口、用户名、TLS、CA 路径、验证名。密码只来自本次输入。
valid_profile_name() {
    [ -n "$1" ] && [ "${#1}" -le 60 ] && [[ "$1" != *[[:cntrl:]]* ]]
}

profile_file() {
    local hex
    valid_profile_name "$1" || return 1
    hex=$(printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n')
    REPLY="$PROFILE_DIR/p-$hex.connection"
}

valid_connection_settings() {
    local host="$1" port="$2" username="$3" tls="$4" ca="$5" tls_name="$6"
    [[ -n "$host" && "$host" != *[[:space:][:cntrl:]]* && "$port" =~ ^[0-9]{1,5}$ ]] &&
        [ "$port" -ge 1 ] && [ "$port" -le 65535 ] &&
        [[ "$username$ca" != *[[:cntrl:]]* && "$tls_name" != *[[:space:][:cntrl:]]* ]] &&
        { [ "$tls" = 1 ] || [[ "$tls" = 0 && -z "$ca$tls_name" ]]; }
}

load_profile() {
    local file="$1" i
    local -a record=()
    mapfile -t record < "$file" || return 1
    [ "${#record[@]}" -eq 8 ] || return 1
    for i in "${!record[@]}"; do record[$i]=${record[$i]%$'\r'}; done
    [ "${record[0]}" = redis-tui-connection-v1 ] || return 1
    profile_file "${record[1]}" && [ "$REPLY" = "$file" ] || return 1
    valid_connection_settings "${record[@]:2}" || return 1
    profile=("${record[@]:1}")
}

save_profile() (
    local name="$1" replace="$2" file temp
    profile_file "$name" || return 1
    file="$REPLY"
    umask 077
    mkdir -p -- "$PROFILE_DIR" || return 1
    temp=$(mktemp "$PROFILE_DIR/.connection.XXXXXX") || return 1
    trap 'rm -f -- "$temp"' EXIT
    printf '%s\n' redis-tui-connection-v1 "$name" "$CONFIG_HOST" "$CONFIG_PORT" "$CONFIG_USER" "$CONFIG_TLS" "$CONFIG_CA" "$CONFIG_TLS_NAME" > "$temp" || return 1
    if [ "$replace" = 1 ]; then mv -f -- "$temp" "$file"
    else mv -n -- "$temp" "$file" && [ ! -e "$temp" ]; fi
)

read_redis_password() {
    local password
    say '  密码 [无密码留空] >' "$GRAY"
    IFS= read -r -s password || return 1
    [ ! -t 0 ] || echo
    REPLY="$password"
}

connect_profile() {
    local name="$1" host="$2" port="$3" username="$4" tls="$5" ca="$6" tls_name="$7" password="$8"
    local -a previous=("$CONFIG_NAME" "$CONFIG_HOST" "$CONFIG_PORT" "$CONFIG_USER" "$CONFIG_TLS" "$CONFIG_CA" "$CONFIG_TLS_NAME" "$CONFIG_PASS")
    CONFIG_NAME="$name"; CONFIG_HOST="$host"; CONFIG_PORT="$port"; CONFIG_USER="$username"
    CONFIG_TLS="$tls"; CONFIG_CA="$ca"; CONFIG_TLS_NAME="$tls_name"; CONFIG_PASS="$password"
    if set_login; then LAST_PATTERN=''; return 0; fi
    CONFIG_NAME=${previous[0]}; CONFIG_HOST=${previous[1]}; CONFIG_PORT=${previous[2]}; CONFIG_USER=${previous[3]}
    CONFIG_TLS=${previous[4]}; CONFIG_CA=${previous[5]}; CONFIG_TLS_NAME=${previous[6]}; CONFIG_PASS=${previous[7]}
    return 1
}

connect_saved_profile() {
    local -a profile=()
    if ! load_profile "$1"; then say '  无法读取该连接配置。' "$RED"; pause; return 1; fi
    say_fit "  连接 ${profile[0]} · ${profile[1]}:${profile[2]}" "$ACCENT" $(( $(tty_width) - 1 ))
    read_redis_password || return 1
    connect_profile "${profile[@]}" "$REPLY"
}

new_connection() {
    local host port username tls=0 ca='' tls_name='' answer password name replace=0
    say '  新建连接' "$ACCENT"
    read_line '  主机 [默认 127.0.0.1] > ' || return 1
    trim "$REPLY"; host="${REPLY:-127.0.0.1}"
    read_line '  端口 [默认 7000] > ' || return 1
    trim "$REPLY"; port="${REPLY:-7000}"
    read_line '  ACL 用户名 [回车使用默认用户] > ' || return 1
    username="$REPLY"
    read_line '  启用 TLS [y/N] > ' || return 1
    trim "$REPLY"; answer="$REPLY"
    case "$answer" in
        y|Y|yes|YES)
            tls=1
            read_line '  CA PEM 路径 [回车使用系统信任] > ' || return 1
            ca="$REPLY"
            if [ -n "$ca" ] && [[ "$ca" != /* && "$ca" != [A-Za-z]:/* ]]; then ca="$PWD/$ca"; fi
            read_line '  TLS 验证名 [回车按节点地址校验] > ' || return 1
            trim "$REPLY"; tls_name="$REPLY" ;;
        ''|n|N|no|NO) ;;
        *) say '  TLS 设置请输入 y 或 n。' "$YELLOW"; pause; return 1 ;;
    esac
    if ! valid_connection_settings "$host" "$port" "$username" "$tls" "$ca" "$tls_name"; then
        say '  主机、端口或连接选项无效。' "$RED"
        pause
        return 1
    fi
    port=$(( 10#$port ))
    read_redis_password || return 1
    password="$REPLY"
    connect_profile '' "$host" "$port" "$username" "$tls" "$ca" "$tls_name" "$password" || return 1
    read_line '  保存为名称 [回车仅本次使用] > ' || return 0
    trim "$REPLY"; name="$REPLY"
    [ -n "$name" ] || return 0
    if ! profile_file "$name"; then
        say '  名称无效，当前连接可继续使用。' "$YELLOW"; pause; return 0
    fi
    if [ -e "$REPLY" ]; then
        read_line '  同名配置已存在。输入 YES 更新 > ' || return 0
        [ "$REPLY" = YES ] || return 0
        replace=1
    fi
    if save_profile "$name" "$replace"; then
        CONFIG_NAME="$name"
    else
        say '  保存失败，当前连接可继续使用。' "$YELLOW"
        pause
    fi
    return 0
}

do_login() {
    local file number choice mode width
    local -a files=() profile=()
    while true; do
        clear_screen
        width=$(tty_width)
        show_header "$width"
        echo
        say '  连接配置' "$ACCENT"
        files=()
        for file in "$PROFILE_DIR"/p-*.connection; do
            [ -f "$file" ] && load_profile "$file" || continue
            files+=("$file")
            mode='TCP'; [ "${profile[4]}" != 1 ] || mode='TLS'
            say_fit "  ${#files[@]}) ${profile[0]}  ·  ${profile[1]}:${profile[2]}  ·  $mode" "$WHITE" $(( width - 1 ))
        done
        if [ "${#files[@]}" -eq 0 ]; then new_connection; return $?; fi
        echo
        hint_line n 新建连接 q 返回
        read_line '  连接 > ' || return 1
        trim "$REPLY"; choice="$REPLY"
        case "$choice" in
            q|Q|'') return 1 ;;
            n|N) if new_connection; then return 0; fi ;;
            *)
                if [[ "$choice" =~ ^[0-9]{1,6}$ ]]; then
                    number=$(( 10#$choice ))
                    if [ "$number" -ge 1 ] && [ "$number" -le "${#files[@]}" ] &&
                        connect_saved_profile "${files[$(( number - 1 ))]}"; then return 0; fi
                fi ;;
        esac
    done
}

# ============ 查看单个 Key ============
detail_header() {
    local width="$1" key="$2" type="$3" ttl="$4" size="$5" label text
    clear_screen
    show_header "$width"
    echo
    say '  Key 详情' "$ACCENT"
    say "  ${key//[[:cntrl:]]/?}" "$WHITE"
    echo
    pad '类型' 6 0; label="$REPLY"; type_color "$type"; say "  $label$type" "$TCOLOR"
    fmt_ttl "$ttl"; text="$REPLY"; pad '过期' 6 0; say "  $REPLY$text" "$GRAY"
    if [[ "$size" =~ ^[0-9]+$ ]]; then
        fmt_size "$size"; text="$REPLY"; pad '大小' 6 0; say "  $REPLY$text" "$GRAY"
    fi
    rule "$width"
}

read_detail_csv() {
    local response
    response=$(rex --csv "$@") || return 1
    parse_redis_csv "$response"
}

# 游标和批内偏移构成一个页位置。只缓存当前 Redis 批次，前翻到旧批次时按游标重读。
load_detail_scan() {
    local command="$1" cursor="$2" offset="$3" stride="$4" rounds=0 available end i next
    local -a args=()
    while true; do
        rounds=$(( rounds + 1 ))
        if [ "$cursor" != "$cached_cursor" ]; then
            args=("$command" "$key" "$cursor" COUNT "$detail_size")
            [ -z "$filter_pattern" ] || args+=(MATCH "$filter_pattern")
            read_detail_csv "${args[@]}" || return 1
            [[ "${csv_fields[0]:-}" =~ ^\"([0-9]+)\"$ ]] || return 1
            next=${BASH_REMATCH[1]}
            [ $(( (${#csv_fields[@]} - 1) % stride )) -eq 0 ] || return 1
            scan_batch=("${csv_fields[@]:1}")
            cached_next="$next"
            cached_cursor="$cursor"
        fi
        available=$(( ${#scan_batch[@]} / stride ))
        if [ "$offset" -lt "$available" ] || [ "$cached_next" = 0 ] || [ "$rounds" -ge 4 ]; then break; fi
        cursor="$cached_next"; offset=0
    done

    end=$(( offset + detail_size ))
    [ "$end" -le "$available" ] || end=$available
    for ((i = offset; i < end; i++)); do detail_tuple "$stride" "${scan_batch[@]:$(( i * stride )):$stride}"; done
    if [ "$end" -lt "$available" ]; then
        next_position="$cursor"; next_offset="$end"
    elif [ "$cached_next" != 0 ]; then
        next_position="$cached_next"
    fi
}

detail_tuple() {
    local stride="$1" label
    decode_csv_text "$2"
    label="${REPLY:-（空）}"
    if [ "$stride" -eq 2 ]; then
        decode_csv_text "$3"
        if [ "$type" = zset ]; then
            page_lines+=("  $label    分数 ${REPLY:-（空）}")
        else
            page_lines+=("  $label = ${REPLY:-（空）}")
        fi
    else
        page_lines+=("  $label")
    fi
    page_items=$(( page_items + 1 ))
}

load_detail_range() {
    local position="$1" last=$(( $1 + detail_size - 1 )) stride=1 i
    if [ "$type" = list ]; then
        read_detail_csv LRANGE "$key" "$position" "$last" || return 1
    else
        stride=2
        read_detail_csv ZRANGE "$key" "$position" "$last" WITHSCORES || return 1
    fi
    [ $(( ${#csv_fields[@]} % stride )) -eq 0 ] || return 1
    for ((i = 0; i < ${#csv_fields[@]}; i += stride)); do
        detail_tuple "$stride" "${csv_fields[@]:$i:$stride}"
    done
    if [ "$page_items" -eq "$detail_size" ] &&
        { [ -z "$total" ] || [ "$last" -lt "$(( total - 1 ))" ]; }; then
        next_position=$(( last + 1 ))
    fi
}

# Stream ID 的两段都是无符号 64 位。按十进制进位以兼容 Bash 的有符号算术和 Redis 5/6.0。
increment_decimal() {
    local digits="$1" suffix='' last
    while [[ "$digits" = *9 ]]; do digits=${digits%9}; suffix+=0; done
    last=${digits: -1}
    REPLY="${digits%?}$(( ${last:-0} + 1 ))$suffix"
}

next_stream_id() {
    local ms="${1%-*}" seq="${1##*-}" max=18446744073709551615
    if [ "$seq" = "$max" ]; then
        [ "$ms" != "$max" ] || return 1
        increment_decimal "$ms"; REPLY="$REPLY-0"
    else
        increment_decimal "$seq"; REPLY="$ms-$REPLY"
    fi
}

load_detail_stream() {
    local start="$1" id label i
    # CSV 展平嵌套数组，所以每次只取一条，保留该条的字段边界。
    while [ "$page_items" -lt "$detail_size" ]; do
        read_detail_csv XRANGE "$key" "$start" + COUNT 1 || return 1
        [ "${#csv_fields[@]}" -gt 0 ] || return 0
        [[ "${csv_fields[0]}" =~ ^\"([0-9]+-[0-9]+)\"$ ]] || return 1
        id=${BASH_REMATCH[1]}
        [ $(( ${#csv_fields[@]} % 2 )) -eq 1 ] || return 1
        page_lines+=("  $id")
        for ((i = 1; i + 1 < ${#csv_fields[@]}; i += 2)); do
            decode_csv_text "${csv_fields[$i]}"; label="${REPLY:-（空）}"
            decode_csv_text "${csv_fields[$(( i + 1 ))]}"
            page_lines+=("    $label = ${REPLY:-（空）}")
        done
        page_items=$(( page_items + 1 ))
        next_stream_id "$id" || return 0
        start="$REPLY"
    done
    if [ -z "$total" ] || [ $(( (page + 1) * detail_size )) -lt "$total" ]; then next_position="$start"; fi
}

show_collection() {
    local key="$1" type="$2" ttl="$3" size="$4" total_command total width detail_size
    local page=0 choice filter='' filter_pattern='' next_position next_offset page_items cached_cursor='' cached_next=''
    local message='' load=1 text
    local -a positions=(0) offsets=(0) csv_fields=() scan_batch=() page_lines=()
    case "$type" in
        hash) total_command=HLEN ;;
        set) total_command=SCARD ;;
        list) total_command=LLEN ;;
        zset) total_command=ZCARD ;;
        stream) total_command=XLEN; positions=(-) ;;
    esac
    detail_size=$(page_size 0)
    [ "$detail_size" -le 20 ] || detail_size=20
    if [ "$type" = stream ] && [ "$detail_size" -gt 10 ]; then detail_size=10; fi
    total=$(rex "$total_command" "$key")
    [[ "$total" =~ ^[0-9]+$ ]] || total=''
    while true; do
        if [ "$load" = 1 ]; then
            page_items=0; page_lines=(); next_position=''; next_offset=0; message=''
            case "$type" in
                hash) load_detail_scan HSCAN "${positions[$page]}" "${offsets[$page]}" 2 ;;
                set) load_detail_scan SSCAN "${positions[$page]}" "${offsets[$page]}" 1 ;;
                list|zset) load_detail_range "${positions[$page]}" ;;
                stream) load_detail_stream "${positions[$page]}" ;;
            esac
            if [ "$?" -ne 0 ]; then message='读取当前页失败，按 r 重试。'; fi
            load=0
        fi
        width=$(tty_width)
        detail_header "$width" "$key" "$type" "$ttl" "$size"
        say "  值 · 第 $(( page + 1 )) 页 · 本页 $page_items 项" "$ACCENT"
        [ -z "$total" ] || say "  集合总量 $total" "$GRAY"
        if [ -n "$filter" ]; then say_fit "  字段包含 $filter" "$GRAY" $(( width - 1 )); fi
        for text in "${page_lines[@]}"; do say "$text" "$WHITE"; done
        if [ "$page_items" -eq 0 ] && [ -z "$message" ]; then
            if [ -n "$next_position" ]; then say '  本批无匹配，按 > 继续扫描。' "$GRAY"
            else say '  本页没有可显示的数据。' "$GRAY"; fi
        fi
        [ -z "$message" ] || say "  $message" "$YELLOW"
        echo
        hint_line '<' 上页 '>' 下页 r 重试 q 返回
        [ "$type" != hash ] || hint_line f 字段筛选
        read_line '  详情 > ' || return 0
        trim "$REPLY"; choice="$REPLY"; message=''
        case "$choice" in
            q|Q|'') return 0 ;;
            '<')
                if [ "$page" -gt 0 ]; then page=$(( page - 1 )); load=1
                else message='已经是第一页。'; fi ;;
            '>')
                if [ -n "$next_position" ]; then
                    page=$(( page + 1 )); positions[page]="$next_position"; offsets[page]="$next_offset"; load=1
                else message='当前没有下一页。'; fi ;;
            r|R)
                total=$(rex "$total_command" "$key")
                [[ "$total" =~ ^[0-9]+$ ]] || total=''
                cached_cursor=''; load=1 ;;
            f|F)
                if [ "$type" = hash ]; then
                    read_line '  字段包含 [回车清除] > ' || return 0
                    filter="$REPLY"; filter_pattern=''
                    if [ -n "$filter" ]; then
                        literal_prefix_pattern "$filter"; filter_pattern="*$REPLY"
                    fi
                    positions=(0); offsets=(0); page=0; cached_cursor=''; load=1
                fi ;;
        esac
    done
}

show_detail() {
    local key="$1" type ttl size width
    type=$(rex TYPE "$key")
    if [ -z "$type" ] || [ "$type" = none ]; then
        clear_screen
        show_header
        echo
        say '  Key 详情' "$ACCENT"
        say "  Key 不存在 · ${key//[[:cntrl:]]/?}" "$RED"
        say '  从主菜单选择 2 搜索 Key。' "$GRAY"
    else
        ttl=$(rex TTL "$key")
        size=$(rex MEMORY USAGE "$key")
        case "$type" in
            hash|set|list|zset|stream) show_collection "$key" "$type" "$ttl" "$size"; return 0 ;;
        esac
        width=$(tty_width)
        detail_header "$width" "$key" "$type" "$ttl" "$size"
        say '  值' "$ACCENT"
        if [ "$type" = string ]; then rex GET "$key"
        else say "  (不支持显示类型: $type)" "$GRAY"; fi
    fi
    echo
    pause
}

query_key() {
    local key
    clear_screen
    show_header
    echo
    say '  查询单个 Key' "$ACCENT"
    read_line '  Key > ' || return 0
    trim "$REPLY"; key="$REPLY"
    [ -z "$key" ] && return 0
    # 带通配符（* 或 ?，含全角）说明是想搜索，直接转到搜索界面
    case "$key" in *'*'*|*'?'*|*'＊'*|*'？'*) key_list "$key"; return 0 ;; esac
    show_detail "$key"
}

# ============ 搜索 Key ============
# 分组前缀：第一个冒号（含）之前的部分，例如 sit:data:permission:1 归到 sit:
key_prefix() {
    case "$1" in *:*) REPLY="${1%%:*}:" ;; *) REPLY='' ;; esac
}

# K_KEY[] 变动过（去掉了一些行）之后，重新计算每一行的分组前缀
rebuild_pfx() {
    local i
    K_PFX=()
    for ((i = 0; i < NKEYS; i++)); do key_prefix "${K_KEY[$i]}"; K_PFX[$i]="$REPLY"; done
}

# 把用户输入变成搜索用的 Pattern → REPLY：
#   - 中文输入法可能把 * 和 ? 打成全角，统一换成半角
#   - 不带通配符时按模糊匹配处理，前后各补一个 *：输入 permission 就等于 *permission*
to_pattern() {
    local t="$1"
    t="${t//＊/*}"
    t="${t//？/?}"
    case "$t" in *'*'*|*'?'*) ;; *) t="*$t*" ;; esac
    REPLY="$t"
}

# 给还没有元数据的行补上类型和过期时间（按所在节点分批执行）
load_meta() {
    local -a nodes=() idxs=()
    local i n k a cmds t ttl q
    declare -A seen=()
    for ((i = 0; i < NKEYS; i++)); do
        [ -z "${K_TYPE[$i]}" ] || continue
        n="${K_NODE[$i]}"
        [ -n "${seen[$n]+x}" ] || { seen[$n]=1; nodes+=("$n"); }
    done
    for n in "${nodes[@]}"; do
        idxs=()
        for ((i = 0; i < NKEYS; i++)); do
            [ -z "${K_TYPE[$i]}" ] && [ "${K_NODE[$i]}" = "$n" ] && idxs+=("$i")
        done
        for ((k = 0; k < ${#idxs[@]}; k += 200)); do
            search_active || return 0
            cmds=""
            for ((a = k; a < k + 200 && a < ${#idxs[@]}; a++)); do
                cli_quote "${K_KEY[${idxs[$a]}]}"; q="$REPLY"
                cmds+="TYPE $q"$'\n'"TTL $q"$'\n'
            done
            if ! batch "$n" "${cmds%$'\n'}"; then REP=(); fi
            [ -z "$search_stop" ] || return 0
            for ((a = k; a < k + 200 && a < ${#idxs[@]}; a++)); do
                i=${idxs[$a]}
                t=${REP[$(( (a - k) * 2 ))]-}
                ttl=${REP[$(( (a - k) * 2 + 1 ))]-}
                if [ -z "$t" ] || [[ "$t" = *" "* ]] || ! [[ "$ttl" =~ ^-?[0-9]+$ ]]; then
                    # 槽位已迁移或批量没取到：单条重试（rex 会跟随 MOVED / ASK 跳转）
                    t=''; ttl=''
                    if search_cli '' -c -h "$CONFIG_HOST" -p "$CONFIG_PORT" --raw TYPE "${K_KEY[$i]}"; then
                        IFS= read -r t < "$search_file"
                    fi
                    if search_cli '' -c -h "$CONFIG_HOST" -p "$CONFIG_PORT" --raw TTL "${K_KEY[$i]}"; then
                        IFS= read -r ttl < "$search_file"
                    fi
                    [ -z "$search_stop" ] || return 0
                    [[ "$t" = *' '* ]] && t=''
                    [[ "$ttl" =~ ^-?[0-9]+$ ]] || ttl=''
                fi
                K_TYPE[$i]="$t"
                K_TTL[$i]="$ttl"
            done
        done
    done
}

# 给指定的行补上占用内存（只在显示时才查，避免对大量 Key 做不必要的计算）
load_sizes() {
    local -a all=("$@") idxs=() nodes=()
    local i n k cmds
    declare -A seen=()
    for i in "${all[@]}"; do
        [ -n "${K_SIZETXT[$i]}" ] && continue
        n="${K_NODE[$i]}"
        [ -n "${seen[$n]+x}" ] || { seen[$n]=1; nodes+=("$n"); }
    done
    for n in "${nodes[@]}"; do
        idxs=()
        cmds=""
        for i in "${all[@]}"; do
            if [ -z "${K_SIZETXT[$i]}" ] && [ "${K_NODE[$i]}" = "$n" ]; then
                idxs+=("$i")
                cli_quote "${K_KEY[$i]}"
                cmds+="MEMORY USAGE $REPLY"$'\n'
            fi
        done
        if batch "$n" "${cmds%$'\n'}"; then
            for k in "${!idxs[@]}"; do
                i=${idxs[$k]}
                if [[ "${REP[$k]}" =~ ^[0-9]+$ ]]; then
                    K_SIZE[$i]=${REP[$k]}
                    fmt_size "${REP[$k]}"
                    K_SIZETXT[$i]="$REPLY"
                else
                    K_SIZE[$i]=-1; K_SIZETXT[$i]='-'
                fi
            done
        else
            for i in "${idxs[@]}"; do K_SIZE[$i]=-1; K_SIZETXT[$i]='-'; done
        fi
    done
}

# 扫描到读取期间被删掉的 Key 不再显示
drop_missing() {
    local -a k=() n=() t=() tt=()
    local i
    for ((i = 0; i < NKEYS; i++)); do
        [ "${K_TYPE[$i]}" = none ] && continue
        k+=("${K_KEY[$i]}"); n+=("${K_NODE[$i]}"); t+=("${K_TYPE[$i]}"); tt+=("${K_TTL[$i]}")
    done
    K_KEY=("${k[@]}"); K_NODE=("${n[@]}"); K_TYPE=("${t[@]}"); K_TTL=("${tt[@]}")
    K_SIZE=(); K_SIZETXT=()
    NKEYS=${#K_KEY[@]}
    for ((i = 0; i < NKEYS; i++)); do K_SIZE[i]=""; K_SIZETXT[i]=""; done
    rebuild_pfx
}

search_active() {
    local key
    [ -z "$search_stop" ] || return 1
    if [ -t 0 ] && IFS= read -r -s -n 1 -t 0.001 key && [[ "$key" = [qQ] ]]; then
        search_stop='用户已取消'
    elif ! kill -0 "$search_timer" 2>/dev/null; then
        search_stop='达到时间上限'
    fi
    [ -z "$search_stop" ]
}

# 单条搜索命令用后台进程执行，等待回复时仍能处理按键与时间预算。
search_cli() {
    local input="$1" status
    shift
    search_active || return 1
    (
        if [ -n "$input" ]; then
            export REDISCLI_BATCH=1
            exec_redis_cli "$@" <<< "$input"
        fi
        exec_redis_cli "$@" </dev/null
    ) > "$search_file" 2>/dev/null &
    search_pid=$!
    while kill -0 "$search_pid" 2>/dev/null; do
        if ! search_active; then
            kill "$search_pid" 2>/dev/null || true
            break
        fi
        sleep 0.04
    done
    wait "$search_pid" 2>/dev/null
    status=$?
    search_pid=''
    [ "$status" -eq 0 ] && search_active
}

read_primary_nodes() {
    primary_nodes=()
    search_cli '' -c -h "$CONFIG_HOST" -p "$CONFIG_PORT" --raw CLUSTER NODES || return 1
    mapfile -t primary_nodes < <(awk '$3 ~ /(^|,)master(,|$)/ && $3 !~ /noaddr|handshake/ { sub(/@.*/, "", $2); print $2 }' "$search_file")
    [ "${#primary_nodes[@]}" -gt 0 ]
}

# 搜索与元数据读取共用同一预算，完整失败时保留旧快照。
scan_keys() {
    local pattern="$1" refreshing="$2" node host port cursor key i scans_ok=0 reason='' last_progress=-1
    local -a reply=() found_keys=() found_nodes=() warnings=() primary_nodes=()
    local -A seen=()
    if ! read_primary_nodes && [ -z "$search_stop" ]; then
        FIND_ERROR='CLUSTER NODES 没有返回主节点'
        return 1
    fi
    for node in "${primary_nodes[@]}"; do
        host=${node%%:*}; port=${node##*:}; cursor=0
        while true; do
            if [ "$last_progress" -ne "$SECONDS" ]; then
                say "  已找到 ${#found_keys[@]} 个 · $node" "$GRAY"
                last_progress=$SECONDS
            fi
            reply=()
            if search_cli '' -h "$host" -p "$port" --raw SCAN "$cursor" MATCH "$pattern" COUNT 500; then
                mapfile -t reply < "$search_file"
            fi
            [ -z "$search_stop" ] || break 2
            cursor=${reply[0]:-}
            if ! [[ "$cursor" =~ ^[0-9]+$ ]]; then
                warnings+=("扫描失败 $node")
                break
            fi
            for ((i = 1; i < ${#reply[@]}; i++)); do
                key="${reply[$i]}"
                [ -z "$key" ] && continue
                [ -n "${seen[$key]+x}" ] && continue
                if [ "${#found_keys[@]}" -ge "$SEARCH_LIMIT" ]; then reason='达到结果上限'; break 3; fi
                seen[$key]=1
                found_keys+=("$key")
                found_nodes+=("$node")
            done
            if [ "$cursor" = 0 ]; then scans_ok=$(( scans_ok + 1 )); break; fi
            if [ "${#found_keys[@]}" -ge "$SEARCH_LIMIT" ]; then reason='达到结果上限'; break 2; fi
        done
    done
    if [ "$scans_ok" -eq 0 ] && [ "${#found_keys[@]}" -eq 0 ] && [ -z "$search_stop$reason" ]; then
        FIND_ERROR='所有主节点扫描失败'
        return 1
    fi
    if [ "$refreshing" = refresh ] && [ "${#found_keys[@]}" -eq 0 ] && [ -n "$search_stop" ]; then
        FIND_ERROR="$search_stop"
        return 1
    fi

    # 扫描成功后再替换结果，全部失败时保留原列表。
    K_KEY=("${found_keys[@]}"); K_NODE=("${found_nodes[@]}")
    K_TYPE=(); K_TTL=(); K_SIZE=(); K_SIZETXT=(); K_PFX=()
    NKEYS=${#K_KEY[@]}
    SEARCH_WARN=("${warnings[@]}")
    FIND_ERROR=''
    if [ "$NKEYS" -gt 0 ] && search_active; then
        say "  已找到 $NKEYS 个 · 正在读取类型和 TTL" "$GRAY"
        load_meta
    fi
    SEARCH_STOP=${search_stop:-$reason}
    drop_missing
    return 0
}

with_search_budget() {
    local seconds="$1"
    shift
    local search_file search_pid='' search_stop='' search_timer status
    search_file=$(mktemp "${TMPDIR:-/tmp}/redis-tui-search.XXXXXX") || return 1
    sleep "$seconds" &
    search_timer=$!
    trap finish_search EXIT
    "$@"
    status=$?
    finish_search
    trap - EXIT
    return "$status"
}

find_keys() {
    FIND_ERROR='无法启动搜索，请检查临时目录'
    say "  搜索上限 $SEARCH_LIMIT 个 / ${SEARCH_SECONDS}秒" "$GRAY"
    [ -t 0 ] && say '  按 q 停止搜索' "$GRAY"
    with_search_budget "$SEARCH_SECONDS" scan_keys "$1" "${2:-}"
}

finish_search() {
    if [ -n "$search_pid" ]; then kill "$search_pid" 2>/dev/null; fi
    kill "$search_timer" 2>/dev/null
    wait "$search_timer" 2>/dev/null
    rm -f -- "$search_file"
}

# 把 "1,3,5-8" 或 "all" 解析成当前列表里的行号，放进 SPECS[]；格式不对时返回非 0。
# 序号就是当前列表里的位置（从 1 开始）
resolve_spec() {
    local spec="$1" part a b n
    SPECS=()
    [ "$spec" = all ] && { SPECS=("${V_ROW[@]}"); return 0; }
    declare -A want=()
    IFS=', ' read -r -a parts <<< "$spec"
    for part in "${parts[@]}"; do
        [ -z "$part" ] && continue
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            a=$(( 10#${BASH_REMATCH[1]} )); b=$(( 10#${BASH_REMATCH[2]} ))
            [ "$a" -gt "$b" ] && { local t=$a; a=$b; b=$t; }
            [ $(( b - a )) -gt 100000 ] && b=$(( a + 100000 ))
            for ((n = a; n <= b; n++)); do want[$n]=1; done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            want[$(( 10#$part ))]=1
        else
            return 1
        fi
    done
    for ((n = 1; n <= V_N; n++)); do
        [ -n "${want[$n]+x}" ] && SPECS+=("${V_ROW[$(( n - 1 ))]}")
    done
    return 0
}

# 删除指定的行：按所在节点分批执行 UNLINK。结果在 REMOVED（删掉的个数）和 FAILED（失败个数）
remove_rows() {
    [ "$ALLOW_WRITES" = 1 ] || return 1
    local -a idxs=("$@") mine=() k=() n=() t=() tt=()
    local node h p i a cmds r
    declare -A gone=() seen=()
    REMOVED=0; FAILED=0
    for i in "${idxs[@]}"; do
        node="${K_NODE[$i]}"
        [ -n "${seen[$node]+x}" ] || { seen[$node]=1; NODES_TO_TOUCH+=("$node"); }
    done
    for node in "${NODES_TO_TOUCH[@]}"; do
        h=${node%%:*}; p=${node##*:}
        mine=()
        for i in "${idxs[@]}"; do [ "${K_NODE[$i]}" = "$node" ] && mine+=("$i"); done
        for ((a = 0; a < ${#mine[@]}; a += 500)); do
            cmds=""
            for ((i = a; i < a + 500 && i < ${#mine[@]}; i++)); do
                cli_quote "${K_KEY[${mine[$i]}]}"
                cmds+="UNLINK $REPLY"$'\n'
            done
            batch "$node" "${cmds%$'\n'}" || REP=()
            for ((i = a; i < a + 500 && i < ${#mine[@]}; i++)); do
                r=${REP[$(( i - a ))]-}
                if ! [[ "$r" =~ ^[0-9]+$ ]]; then
                    # 槽位已迁移或批量没取到：单条重试。UNLINK 对不存在的 Key 返回 0，重试不会重复计数
                    r=$(rex_node "$h" "$p" UNLINK "${K_KEY[${mine[$i]}]}")
                fi
                if [[ "$r" =~ ^[0-9]+$ ]]; then
                    REMOVED=$(( REMOVED + r ))
                    gone["${K_KEY[${mine[$i]}]}"]=1
                else
                    FAILED=$(( FAILED + 1 ))
                fi
            done
        done
    done
    # 从列表里去掉已删除的行
    if [ "${#gone[@]}" -gt 0 ]; then
        for ((i = 0; i < NKEYS; i++)); do
            [ -n "${gone[${K_KEY[$i]}]+x}" ] && continue
            k+=("${K_KEY[$i]}"); n+=("${K_NODE[$i]}"); t+=("${K_TYPE[$i]}"); tt+=("${K_TTL[$i]}")
        done
        K_KEY=("${k[@]}"); K_NODE=("${n[@]}"); K_TYPE=("${t[@]}"); K_TTL=("${tt[@]}")
        K_SIZE=(); K_SIZETXT=()
        NKEYS=${#K_KEY[@]}
        for ((i = 0; i < NKEYS; i++)); do K_SIZE[i]=""; K_SIZETXT[i]=""; done
        rebuild_pfx
    fi
}

# 按当前筛选条件算出可见列表（放进 V_ROW[]，个数 V_N），并统计各组数量（G_COUNT）。
# 有前缀的 Key 按 Key 排序（同前缀的自然挨在一起），无前缀的排在最后
update_visible() {
    local -a recs=()
    local i pf rec bucket
    G_COUNT=()
    V_N=0
    V_ROW=()
    for ((i = 0; i < NKEYS; i++)); do
        [ "$NOEXPIRE" = 1 ] && [ "${K_TTL[$i]}" != "-1" ] && continue
        [ -n "$TYPEFILTER" ] && [ "${K_TYPE[$i]}" != "$TYPEFILTER" ] && continue
        [ -n "$PREFIXFILTER" ] && [ "${K_PFX[$i]}" != "$PREFIXFILTER" ] && continue
        pf="${K_PFX[$i]}"
        if [ -n "$pf" ]; then G_COUNT[$pf]=$(( ${G_COUNT[$pf]:-0} + 1 ))
        else G_COUNT['(无前缀)']=$(( ${G_COUNT['(无前缀)']:-0} + 1 )); fi
        bucket=0
        [ -z "$pf" ] && bucket=1
        recs+=("$bucket${K_KEY[$i]}"$'\001'"$i")
    done
    [ ${#recs[@]} -gt 0 ] || return 0
    while IFS= read -r -d '' rec; do
        V_ROW[V_N]=${rec##*$'\001'}
        V_N=$(( V_N + 1 ))
    done < <(printf '%s\0' "${recs[@]}" | sort -z)
}

print_row() {
    local number="$1" i="$2" keyw="$3" numw="$4" ttlw="$5" sizew="$6"
    local key="${K_KEY[$i]}" ttltext sizetext='-' cell ttlcolor="$GRAY"
    fmt_ttl "${K_TTL[$i]}"
    ttltext="$REPLY"
    [ "${K_TTL[$i]}" = "-1" ] && ttlcolor="$YELLOW"
    if [[ "${K_TTL[$i]}" =~ ^[0-9]+$ ]] && [ "${K_TTL[$i]}" -lt 600 ]; then ttlcolor="$RED"; fi
    [ -n "${K_SIZETXT[$i]}" ] && sizetext="${K_SIZETXT[$i]}"

    pad "$number" "$numw" 1; sayn "  $REPLY" "$GRAY"
    printf '  '
    pad "${key//[[:cntrl:]]/?}" "$keyw" 0; sayn "$REPLY" "$WHITE"
    printf '  '
    pad "${K_TYPE[$i]:--}" 6 0; cell="$REPLY"; type_color "${K_TYPE[$i]}"; sayn "$cell" "$TCOLOR"
    printf '  '
    pad "$ttltext" "$ttlw" 0; sayn "$REPLY" "$ttlcolor"
    if [ "$sizew" -gt 0 ]; then
        printf '  '
        pad "$sizetext" "$sizew" 1; sayn "$REPLY" "$GRAY"
    fi
    printf '\n'
}

render_table() {
    local pattern="$1" width="$2" start="$3" pcount="$4" sizew="$5"
    shift 5
    local -a page=("$@")
    local keyw numw=${#V_N} ttlw=10 h i k pf cnt lastpfx='' first=1
    local filters='全部' grouping='关闭' limit=$(( width - 1 ))
    clear_screen
    show_header "$width"
    sayn '  搜索结果  ' "$ACCENT"
    say_fit "$pattern" "$WHITE" $(( limit - 12 ))
    [ "$GROUPED" = 1 ] && grouping='开启'
    say "  显示 $V_N / $NKEYS    分组 $grouping" "$GRAY"
    if [ "$NOEXPIRE" = 1 ] || [ -n "$TYPEFILTER$PREFIXFILTER" ]; then
        filters=''
        [ "$NOEXPIRE" = 1 ] && filters+='  无过期'
        [ -n "$TYPEFILTER" ] && filters+="  类型 $TYPEFILTER"
        [ -n "$PREFIXFILTER" ] && filters+="  前缀 $PREFIXFILTER"
        filters=${filters#  }
    fi
    say_fit "  筛选  $filters" "$GRAY" "$limit"
    if [ "${#SEARCH_WARN[@]}" -gt 0 ]; then
        say "  部分结果 · ${#SEARCH_WARN[@]} 节点失败 [?]" "$YELLOW"
    fi
    [ -n "$SEARCH_STOP" ] && say "  部分结果 · $SEARCH_STOP" "$YELLOW"
    if [ -n "$REFRESH_ERROR" ]; then
        say_fit "  上次结果 · $REFRESH_ERROR" "$RED" "$limit"
    fi
    echo

    if [ "$V_N" = 0 ]; then
        if [ "$NKEYS" = 0 ] && { [ -n "$SEARCH_STOP" ] || [ "${#SEARCH_WARN[@]}" -gt 0 ]; }; then
            say '  暂无可显示的 Key。输入 r 重试。' "$GRAY"
        elif [ "$NKEYS" = 0 ]; then
            say '  没有匹配的 Key。输入 n 换关键词。' "$GRAY"
        else
            say '  筛选后无结果。输入 c 清除筛选。' "$GRAY"
        fi
    else
        [ "$numw" -lt 4 ] && numw=4
        [ "$sizew" -gt 0 ] && ttlw=14
        # 预留最后一格防止终端自动换行。
        keyw=$(( limit - 14 - numw - ttlw ))
        [ "$sizew" -gt 0 ] && keyw=$(( keyw - sizew - 2 ))
        [ "$keyw" -gt 90 ] && keyw=90
        pad '#' "$numw" 1; h="  $REPLY  "
        pad 'Key' "$keyw" 0; h+="$REPLY  "
        pad '类型' 6 0; h+="$REPLY  "
        pad '过期' "$ttlw" 0; h+="$REPLY"
        if [ "$sizew" -gt 0 ]; then pad '大小' "$sizew" 1; h+="  $REPLY"; fi
        printf '  '
        say "${h:2}" "$TABLE_BAND"

        for ((k = 0; k < ${#page[@]}; k++)); do
            i=${page[$k]}
            if [ "$GROUPED" = 1 ]; then
                pf="${K_PFX[$i]}"
                if [ "$first" = 1 ] || [ "$pf" != "$lastpfx" ]; then
                    cnt=${G_COUNT[${pf:-'(无前缀)'}]:-0}
                    say_fit "  $cnt 个 · ${pf:-无前缀}" "$CYAN" "$limit"
                    lastpfx="$pf"
                    first=0
                fi
            fi
            print_row $(( start + k + 1 )) "$i" "$keyw" "$numw" "$ttlw" "$sizew"
        done
    fi

    rule "$width"
    if [ -n "$MESSAGE" ]; then say_fit "  $MESSAGE" "$MSGCOLOR" "$limit"; fi
    hint_line "第 $(( PAGE + 1 )) / $pcount 页" '' '<' 上页 '>' 下页
    hint_line 序号 查看 r 刷新 n 新搜 q 返回
    hint_line f 无过期 t 类型 p 前缀 g 分组
    if [ "$ALLOW_WRITES" = 1 ]; then hint_line c 清筛选 d 删除 '?' 帮助
    else hint_line c 清筛选 '?' 帮助; fi
}

hint_line() {
    printf '  '
    while [ "$#" -ge 2 ]; do
        sayn "$1" "$ACCENT"
        [ -n "$2" ] && sayn " $2" "$GRAY"
        shift 2
        [ "$#" -gt 0 ] && printf '  '
    done
    printf '\n'
}

# 筛选选项是从结果里实际存在的类型 / 前缀中选。$1 = type 或 prefix
choose_filter() {
    local what="$1" i v k ans limit
    declare -A cnt=()
    for ((i = 0; i < NKEYS; i++)); do
        if [ "$what" = type ]; then v="${K_TYPE[$i]}"; else v="${K_PFX[$i]}"; fi
        [ -z "$v" ] && continue
        cnt[$v]=$(( ${cnt[$v]:-0} + 1 ))
    done
    names=()
    while IFS= read -r v; do [ -n "$v" ] && names+=("$v"); done < <(printf '%s\n' "${!cnt[@]}" | sort)
    limit=$(( $(tty_width) - 1 ))
    echo
    if [ "$what" = type ]; then say '  按类型筛选' "$CYAN"; else say '  按前缀筛选' "$CYAN"; fi
    for k in "${!names[@]}"; do
        say_fit "  $(( k + 1 ))) (${cnt[${names[$k]}]}) ${names[$k]}" "$GRAY" "$limit"
    done
    say '  a) 全部    q) 取消' "$GRAY"
    read_line '  选择: ' || return 0
    ans="$REPLY"
    trim "$ans"; ans="$REPLY"
    v=''
    if [ -z "$ans" ] || [ "$ans" = a ] || [ "$ans" = A ]; then
        v=''
    elif [[ "$ans" =~ ^[0-9]+$ ]] && [ $(( 10#$ans )) -ge 1 ] && [ $(( 10#$ans )) -le ${#names[@]} ]; then
        v=${names[$(( 10#$ans - 1 ))]}
    else
        return 0
    fi
    if [ "$what" = type ]; then TYPEFILTER="$v"; else PREFIXFILTER="$v"; fi
    PAGE=0
    DIRTY=1
}

list_delete() {
    local spec="$1" i key shown
    if [ "$ALLOW_WRITES" != 1 ]; then
        MESSAGE='只读会话，删除已禁用'; MSGCOLOR="$YELLOW"; return
    fi
    if [ -n "$REFRESH_ERROR" ]; then
        MESSAGE='请先刷新，再执行删除'; MSGCOLOR="$YELLOW"; return
    fi
    if [ "$spec" = all ] && { [ -n "$SEARCH_STOP" ] || [ "${#SEARCH_WARN[@]}" -gt 0 ]; }; then
        MESSAGE='结果不完整，请按序号选择'; MSGCOLOR="$YELLOW"; return
    fi
    if ! resolve_spec "$spec"; then
        say '  序号格式不对。示例: d 1,3,5-8 或 d all' "$RED"
        pause
        return
    fi
    if [ ${#SPECS[@]} -eq 0 ]; then
        say '  没有匹配的序号（只能选当前列表里的序号）' "$RED"
        pause
        return
    fi
    echo
    say "  将删除 ${#SPECS[@]} 个 Key" "$YELLOW"
    shown=0
    for i in "${SPECS[@]}"; do
        shown=$(( shown + 1 ))
        [ "$shown" -gt 10 ] && break
        key="${K_KEY[$i]}"
        say "    ${key//[[:cntrl:]]/?}" "$GRAY"
    done
    if [ ${#SPECS[@]} -gt $(( shown - 1 )) ] && [ ${#SPECS[@]} -gt 10 ]; then say "    ... 还有 $(( ${#SPECS[@]} - 10 )) 个" "$DARKGRAY"; fi
    read_line '  输入 YES 确认删除: ' || { echo; say '  已取消' "$GRAY"; pause; return; }
    if [ "$REPLY" != YES ]; then
        say '  已取消' "$GRAY"
        pause
        return
    fi
    NODES_TO_TOUCH=()
    remove_rows "${SPECS[@]}"
    echo
    say "  √ 已删除 $REMOVED 个" "$GREEN"
    if [ "$FAILED" -gt 0 ]; then say "  × $FAILED 个删除失败" "$RED"; fi
    echo
    pause
    DIRTY=1
}

view_spec() {
    local spec="$1" i
    if ! resolve_spec "$spec" || [ ${#SPECS[@]} -eq 0 ]; then
        MESSAGE='没有匹配的序号（只能选当前列表里的序号）'
        MSGCOLOR="$YELLOW"
        return
    fi
    for i in "${SPECS[@]}"; do show_detail "${K_KEY[$i]}"; done
}

# 搜索结果界面。结束时 LIST_ACTION 是 back（返回主菜单）或 new（换条件重新搜索）
list_screen() {
    local pattern="$1"
    local width sizew psize pcount start stop i line verb arg warn
    local -a page=()
    NOEXPIRE=0; TYPEFILTER=""; PREFIXFILTER=""; GROUPED=1; PAGE=0; DIRTY=1
    MESSAGE=""; MSGCOLOR="$GRAY"; REFRESH_ERROR=""
    while true; do
        if [ "$DIRTY" = 1 ]; then update_visible; DIRTY=0; fi
        width=$(tty_width)
        sizew=0
        [ "$width" -ge 64 ] && sizew=10
        psize=$(page_size "$GROUPED")
        pcount=$(( ( V_N + psize - 1 ) / psize ))
        [ "$pcount" -lt 1 ] && pcount=1
        [ "$PAGE" -ge "$pcount" ] && PAGE=$(( pcount - 1 ))
        start=$(( PAGE * psize ))
        stop=$(( start + psize ))
        [ "$stop" -gt "$V_N" ] && stop=$V_N
        page=()
        for ((i = start; i < stop; i++)); do page+=("${V_ROW[$i]}"); done
        if [ "$sizew" -gt 0 ] && [ ${#page[@]} -gt 0 ] && [ -z "$SEARCH_STOP$REFRESH_ERROR" ]; then
            load_sizes "${page[@]}"
        fi

        render_table "$pattern" "$width" "$start" "$pcount" "$sizew" "${page[@]}"
        MESSAGE=""; MSGCOLOR="$GRAY"

        read_line '  命令 > ' || { LIST_ACTION=back; return 0; }
        line="$REPLY"
        trim "$line"; line="$REPLY"
        [ -z "$line" ] && continue
        verb=${line%% *}
        arg=''
        if [ "$verb" != "$line" ]; then arg=${line#* }; trim "$arg"; arg="$REPLY"; fi

        case "$verb" in
            q) LIST_ACTION=back; return 0 ;;
            n) LIST_ACTION=new; return 0 ;;
            r)
                say '  正在刷新搜索结果...' "$GRAY"
                if find_keys "$pattern" refresh; then
                    PAGE=0; DIRTY=1
                    REFRESH_ERROR=''
                    if [ -z "$SEARCH_STOP" ]; then MESSAGE='已刷新'; MSGCOLOR="$GREEN"; fi
                else
                    REFRESH_ERROR="$FIND_ERROR"
                fi ;;
            c) NOEXPIRE=0; TYPEFILTER=''; PREFIXFILTER=''; PAGE=0; DIRTY=1 ;;
            '?'|'？')
                echo
                say '  查看：3、1,3 或 v 1-3' "$GRAY"
                if [ "$ALLOW_WRITES" = 1 ]; then
                    say '  删除：d 1,3 或 d 1-3' "$GRAY"
                    say '  d all 选择完整筛选结果（含其他页）' "$YELLOW"
                    say '  删除前需输入 YES 确认' "$GRAY"
                fi
                [ "$sizew" -eq 0 ] && say '  Key 详情可查看大小' "$GRAY"
                if [ -n "$REFRESH_ERROR" ]; then say "  刷新失败：$REFRESH_ERROR" "$RED"; fi
                for warn in "${SEARCH_WARN[@]}"; do say_fit "  $warn" "$YELLOW" $(( width - 1 )); done
                pause ;;
            f) NOEXPIRE=$(( 1 - NOEXPIRE )); PAGE=0; DIRTY=1 ;;
            g) GROUPED=$(( 1 - GROUPED )); PAGE=0 ;;
            '>')
                if [ $(( PAGE + 1 )) -lt "$pcount" ]; then PAGE=$(( PAGE + 1 ))
                else MESSAGE='已经是最后一页'; MSGCOLOR="$YELLOW"; fi ;;
            '<')
                if [ "$PAGE" -gt 0 ]; then PAGE=$(( PAGE - 1 ))
                else MESSAGE='已经是第一页'; MSGCOLOR="$YELLOW"; fi ;;
            t) choose_filter type ;;
            p) choose_filter prefix ;;
            d)
                if [ -n "$arg" ]; then list_delete "$arg"
                elif [ "$ALLOW_WRITES" != 1 ]; then MESSAGE='只读会话，删除已禁用'; MSGCOLOR="$YELLOW"
                else MESSAGE='删除要带序号，例如: d 1,3,5-8 或 d all'; MSGCOLOR="$YELLOW"; fi ;;
            v)
                if [ -n "$arg" ]; then view_spec "$arg"
                else MESSAGE='查看要带序号，例如: 3 或 v 1,3'; MSGCOLOR="$YELLOW"; fi ;;
            [0-9]*)
                view_spec "$(printf '%s' "$line" | tr -s '[:space:]' ',')" ;;
            *) MESSAGE="不认识的命令: $verb"; MSGCOLOR="$YELLOW" ;;
        esac
    done
}

# $1: 可选的初始 Pattern（有值就直接搜，不再询问）
key_list() {
    local pattern="$1" typed width
    while true; do
        if [ -z "$pattern" ]; then
            clear_screen
            width=$(tty_width)
            show_header "$width"
            echo
            say '  搜索 Key' "$CYAN"
            say '  输入关键词或通配符，如 user:*' "$GRAY"
            [ -n "$LAST_PATTERN" ] && say_fit "  回车沿用 $LAST_PATTERN" "$GRAY" $(( width - 1 ))
            say '  输入 :q 返回主菜单' "$GRAY"
            read_line '  搜索 > ' || return 0
            typed="$REPLY"
            trim "$typed"; typed="$REPLY"
            [ "$typed" = :q ] && return 0
            if [ -n "$typed" ]; then to_pattern "$typed"; pattern="$REPLY"
            elif [ -n "$LAST_PATTERN" ]; then pattern="$LAST_PATTERN"
            else return 0; fi
        fi
        to_pattern "$pattern"
        pattern="$REPLY"
        LAST_PATTERN="$pattern"
        say '  正在搜索并读取类型、过期时间...' "$DARKGRAY"
        if ! find_keys "$pattern"; then
            echo
            say "  × $FIND_ERROR" "$RED"
            echo
            pause
            return 0
        fi
        list_screen "$pattern"
        # n = 换条件重新搜索：清空后回到上面的输入提示
        [ "$LIST_ACTION" = new ] || return 0
        pattern=''
    done
}

# ============ Redis 监控 ============
declare -A INFO OKS HR LAGM ROLETXT MASTEROF PROB MID2ADDR PREV_H PREV_M ERRTXT CHOSEN G_COUNT
MN_LIST=(); MN_TABLE=()
COLS_NAME=(); COLS_W=(); COLS_N=0
OUT_LINES=0; MW=120

# $1 = 节点地址，$2 = INFO 文本。字段放进 INFO[地址|字段]，键总数放进 INFO[地址|__keys]
parse_info() {
    local addr="$1" line key val
    INFO["$addr|__keys"]=0
    while IFS= read -r line; do
        line=${line%$'\r'}
        case "$line" in ''|'#'*) continue ;; esac
        key=${line%%:*}
        [ "$key" = "$line" ] && continue
        val=${line#*:}
        case "$key" in
            db[0-9]*)
                case "$val" in keys=*) val=${val#keys=}; val=${val%%,*}; INFO["$addr|__keys"]=$(( ${INFO["$addr|__keys"]} + val )) ;; esac
                continue ;;
        esac
        [ -n "${INFO[$addr|$key]+x}" ] || INFO["$addr|$key"]="$val"
    done <<< "$2"
}

# 看某个字段的值：$1 节点地址，$2 字段 → REPLY（没有就是空串）
inf() { REPLY="${INFO[$1|$2]:-}"; }

# 监控画面的一行：补空格到整行宽，这样原地刷新时能盖住上一轮的内容
mout() {
    pad "$1" $(( MW - 1 )) 0
    say "$REPLY" "$2"
    OUT_LINES=$(( OUT_LINES + 1 ))
}

mblank() { printf '%*s\n' $(( MW - 1 )) ''; OUT_LINES=$(( OUT_LINES + 1 )); }

# 按可用宽度挑表格列：$1 = 可用宽度，其余参数是按显示顺序排的 "列名:宽度"。
# 先保证 COL_PRIORITY（空格分隔）里排在前面的列，放得下才加后面的。结果放进 COLS_NAME[] / COLS_W[]
select_cols() {
    local avail="$1" name w cost used=0 c
    shift
    local -a cands=("$@")
    CHOSEN=()
    for name in $COL_PRIORITY; do
        w=0
        for c in "${cands[@]}"; do [ "${c%%:*}" = "$name" ] && w=${c##*:}; done
        cost=$w
        [ "${#CHOSEN[@]}" -gt 0 ] && cost=$(( cost + 2 ))
        if [ "${#CHOSEN[@]}" -eq 0 ] || [ $(( used + cost )) -le "$avail" ]; then
            CHOSEN[$name]=1
            used=$(( used + cost ))
        fi
    done
    COLS_NAME=(); COLS_W=()
    for c in "${cands[@]}"; do
        name=${c%%:*}
        if [ -n "${CHOSEN[$name]+x}" ]; then COLS_NAME+=("$name"); COLS_W+=("${c##*:}"); fi
    done
    COLS_N=${#COLS_NAME[@]}
}

# 某个节点在某列上显示的内容：$1 节点地址，$2 列名 → REPLY
mcell() {
    local a="$1" c="$2" m
    [ "$c" = 节点 ] && { REPLY="$a"; return; }
    if [ "${OKS[$a]:-0}" != 1 ]; then
        case "$c" in 角色) REPLY="${ROLETXT[$a]:-}" ;; 内存) REPLY='× 无法连接' ;; *) REPLY='—' ;; esac
        return
    fi
    case "$c" in
        角色) REPLY="${ROLETXT[$a]:-}" ;;
        内存) inf "$a" used_memory; fmt_size "$REPLY" ;;
        上限)
            inf "$a" maxmemory; m=$REPLY
            if [[ "$m" =~ ^[0-9]+$ ]] && [ "$m" -gt 0 ]; then fmt_size "$m"; else REPLY='不限'; fi ;;
        占用)
            inf "$a" maxmemory; m=$REPLY
            if [[ "$m" =~ ^[0-9]+$ ]] && [ "$m" -gt 0 ]; then inf "$a" used_memory; REPLY="$(( REPLY * 100 / m ))%"; else REPLY='-'; fi ;;
        碎片率) inf "$a" mem_fragmentation_ratio ;;
        客户端) inf "$a" connected_clients; fmt_count "$REPLY" ;;
        每秒命令) inf "$a" instantaneous_ops_per_sec; fmt_count "$REPLY" ;;
        命中率) REPLY="${HR[$a]:--}" ;;
        键数) fmt_count "${INFO[$a|__keys]:-0}" ;;
        运行时间) inf "$a" uptime_in_seconds; fmt_uptime "$REPLY" ;;
        主节点) REPLY="${MASTEROF[$a]:-}" ;;
        同步) inf "$a" master_link_status ;;
        主从延迟)
            inf "$a" master_last_io_seconds_ago
            if [[ "$REPLY" =~ ^[0-9]+$ ]]; then REPLY="$REPLY 秒"; else REPLY='-'; fi ;;
        复制落后) if [ -n "${LAGM[$a]+x}" ]; then fmt_size "${LAGM[$a]}"; else REPLY='-'; fi ;;
        版本) inf "$a" redis_version ;;
        从节点)
            if [ "${INFO[$a|role]:-}" = master ]; then inf "$a" connected_slaves; fmt_count "$REPLY"; else REPLY='-'; fi ;;
        过期键) inf "$a" expired_keys; fmt_count "$REPLY" ;;
        驱逐键) inf "$a" evicted_keys; fmt_count "$REPLY" ;;
        拒绝连接) inf "$a" rejected_connections; fmt_count "$REPLY" ;;
        RDB) inf "$a" rdb_last_bgsave_status ;;
        AOF)
            if [ "${INFO[$a|aof_enabled]:-0}" = 1 ]; then inf "$a" aof_last_bgrewrite_status; else REPLY='关'; fi ;;
        *) REPLY='-' ;;
    esac
    [ -z "$REPLY" ] && REPLY='-'
}

# 画一张表：$1 标题；行是 MN_TABLE[] 里的节点地址
mtable() {
    local title="$1" line a k c cell right color
    mout '' "$GRAY"
    mout "  $title" "$CYAN"
    line='  '
    for k in "${!COLS_NAME[@]}"; do
        right=0; [ "$k" -gt 0 ] && right=1
        pad "${COLS_NAME[$k]}" "${COLS_W[$k]}" "$right"
        line+="$REPLY  "
    done
    mout "${line%  }" "$CYAN"
    for a in "${MN_TABLE[@]}"; do
        line='  '
        for k in "${!COLS_NAME[@]}"; do
            right=0; [ "$k" -gt 0 ] && right=1
            mcell "$a" "${COLS_NAME[$k]}"
            pad "$REPLY" "${COLS_W[$k]}" "$right"
            line+="$REPLY  "
        done
        color="$WHITE"
        [ "${PROB[$a]:-0}" = 1 ] && color="$RED"
        mout "${line%  }" "$color"
    done
}

# 取一次全部数据并画出来
monitor_snapshot() {
    # 可用宽度要扣掉每行开头的两格缩进（表格行都以 "  " 起头）
    local avail=$(( MW - 3 ))
    local text rec id addr flags masterid ping pong epoch state a h p info role hits miss dh dm
    local -a masters=() replicas=()
    local line cstate='-' slots='-' okn='' asn='' cinfo k mm uu mo so lag stamp left title nbad reach=0
    local tk tm to tc
    local total_keys=0 total_mem=0 total_clients=0 total_ops=0 master_count=0 addrw=15

    text=$(rex CLUSTER NODES)
    MID2ADDR=()
    while read -r id addr flags masterid ping pong epoch state; do
        [ -n "$addr" ] || continue
        addr=${addr%%@*}
        case "$flags" in *noaddr*|*handshake*) continue ;; esac
        case "$flags" in
            *master*) masters+=("$id $addr $masterid"); MID2ADDR[$id]=$addr ;;
            *) replicas+=("$id $addr $masterid") ;;
        esac
    done <<< "$text"
    MN_LIST=(); MN_ISMASTER=(); MN_MASTERID=()
    for rec in "${masters[@]}"; do
        read -r id addr masterid <<< "$rec"
        MN_LIST+=("$addr"); MN_ISMASTER+=(1); MN_MASTERID+=("$masterid")
    done
    master_count=${#MN_LIST[@]}
    for rec in "${replicas[@]}"; do
        read -r id addr masterid <<< "$rec"
        MN_LIST+=("$addr"); MN_ISMASTER+=(0); MN_MASTERID+=("$masterid")
    done

    if [ ${#MN_LIST[@]} -eq 0 ]; then
        mout '' "$GRAY"
        mout "  × 取不到集群节点: $(node_reason "$CONFIG_HOST" "$CONFIG_PORT")" "$RED"
        return
    fi

    cinfo=$(rex CLUSTER INFO)
    while IFS= read -r line; do
        line=${line%$'\r'}
        case "$line" in
            cluster_state:*) cstate=${line#*:} ;;
            cluster_slots_ok:*) okn=${line#*:} ;;
            cluster_slots_assigned:*) asn=${line#*:} ;;
        esac
    done <<< "$cinfo"
    if [[ "$okn" =~ ^[0-9]+$ ]] && [[ "$asn" =~ ^[0-9]+$ ]]; then
        fmt_count "$okn"; tk="$REPLY"
        fmt_count "$asn"; slots="$tk / $REPLY"
    fi

    # 逐个节点取 INFO
    for a in "${MN_LIST[@]}"; do
        [ "${#a}" -gt "$addrw" ] && addrw=${#a}
        h=${a%%:*}; p=${a##*:}
        info=$(rex_node "$h" "$p" INFO)
        if [[ "$info" != *redis_version:* ]]; then
            OKS[$a]=0
            ERRTXT[$a]=$(node_reason "$h" "$p")
            ROLETXT[$a]='?'
            HR[$a]='-'
            continue
        fi
        OKS[$a]=1
        parse_info "$a" "$info"
        ROLETXT[$a]='?'
        role=${INFO[$a|role]:-}
        [ "$role" = master ] && ROLETXT[$a]='主'
        [ "$role" = slave ] && ROLETXT[$a]='从'
        # 命中率：优先用两次刷新之间的增量，第一次没有上一次的数据就用累计值
        hits=${INFO[$a|keyspace_hits]:-0}
        miss=${INFO[$a|keyspace_misses]:-0}
        HR[$a]='-'
        if [ -n "${PREV_H[$a]+x}" ]; then
            dh=$(( hits - PREV_H[$a] )); dm=$(( miss - PREV_M[$a] ))
            if [ "$dh" -ge 0 ] && [ "$dm" -ge 0 ] && [ $(( dh + dm )) -gt 0 ]; then
                HR[$a]=$(awk -v x="$dh" -v y="$dm" 'BEGIN { printf "%.1f%%", 100 * x / (x + y) }')
            fi
        fi
        if [ "${HR[$a]}" = '-' ] && [ $(( hits + miss )) -gt 0 ]; then
            HR[$a]=$(awk -v x="$hits" -v y="$miss" 'BEGIN { printf "%.1f%%", 100 * x / (x + y) }')
        fi
        PREV_H[$a]=$hits
        PREV_M[$a]=$miss
    done

    # 从节点对应的主节点、复制落后的字节数（主节点复制偏移量 - 从节点已复制的偏移量）、异常标记
    local kk ismaster
    for kk in "${!MN_LIST[@]}"; do
        a=${MN_LIST[$kk]}
        ismaster=${MN_ISMASTER[$kk]}
        MASTEROF[$a]=''; LAGM[$a]=''; PROB[$a]=0
        [ "$ismaster" = 0 ] && MASTEROF[$a]=${MID2ADDR[${MN_MASTERID[$kk]}]:-}
        if [ "$ismaster" = 0 ] && [ -n "${MASTEROF[$a]}" ] && [ "${OKS[$a]:-0}" = 1 ] && [ "${OKS[${MASTEROF[$a]}]:-0}" = 1 ]; then
            mo=${INFO[${MASTEROF[$a]}|master_repl_offset]:-0}
            so=${INFO[$a|slave_repl_offset]:-0}
            if [[ "$mo" =~ ^[0-9]+$ ]] && [[ "$so" =~ ^[0-9]+$ ]]; then
                lag=$(( mo - so ))
                [ "$lag" -lt 0 ] && lag=0
                LAGM[$a]=$lag
            fi
        fi
        if [ "${OKS[$a]:-0}" != 1 ]; then PROB[$a]=1; continue; fi
        [ "$ismaster" = 0 ] && [ "${INFO[$a|master_link_status]:-}" != up ] && PROB[$a]=1
        [ "${INFO[$a|rdb_last_bgsave_status]:-}" = err ] && PROB[$a]=1
        [ "${INFO[$a|aof_enabled]:-0}" = 1 ] && [ "${INFO[$a|aof_last_bgrewrite_status]:-}" = err ] && PROB[$a]=1
        mm=${INFO[$a|maxmemory]:-0}; uu=${INFO[$a|used_memory]:-0}
        if [[ "$mm" =~ ^[0-9]+$ ]] && [ "$mm" -gt 0 ] && [[ "$uu" =~ ^[0-9]+$ ]] && [ $(( uu * 100 / mm )) -ge 90 ]; then PROB[$a]=1; fi
        reach=$(( reach + 1 ))
        total_keys=$(( total_keys + ${INFO[$a|__keys]:-0} ))
        total_clients=$(( total_clients + ${INFO[$a|connected_clients]:-0} ))
        [ "$ismaster" = 1 ] && total_mem=$(( total_mem + ${INFO[$a|used_memory]:-0} ))
        [ "$ismaster" = 1 ] && total_ops=$(( total_ops + ${INFO[$a|instantaneous_ops_per_sec]:-0} ))
    done

    # ---- 标题与汇总 ----
    mout '' "$GRAY"
    stamp=$(date '+%Y-%m-%d %H:%M:%S')
    title='  Redis 集群监控'
    left=$(( MW - 1 - ${#stamp} - 2 - $(str_width "$title") ))
    [ "$left" -lt 1 ] && left=1
    printf -v line '%s%*s%s' "$title" "$left" '' "$stamp"
    mout "$line" "$WHITE"
    mout "  集群状态 $cstate    槽位 $slots    节点 ${#MN_LIST[@]} 个 ($master_count 主 $(( ${#MN_LIST[@]} - master_count )) 从)" "$CYAN"
    fmt_count "$total_keys"; tk="$REPLY"
    fmt_size "$total_mem"; tm="$REPLY"
    fmt_count "$total_ops"; to="$REPLY"
    fmt_count "$total_clients"; tc="$REPLY"
    mout "  主节点合计: $tk 个键 · $tm · 每秒 $to 条命令" "$GRAY"
    mout "  全部节点客户端 $tc    可连接 $reach / ${#MN_LIST[@]}" "$GRAY"

    # ---- 表 1：概览 ----
    COL_PRIORITY='节点 角色 内存 客户端 每秒命令 命中率 键数 上限 运行时间 碎片率 占用'
    select_cols "$avail" "节点:$addrw" '角色:4' '内存:10' '上限:9' '碎片率:6' '占用:6' '客户端:7' '每秒命令:8' '命中率:8' '键数:9' '运行时间:11'
    MN_TABLE=("${MN_LIST[@]}")
    mtable '概览'

    # ---- 表 2：主从复制 ----
    if [ $(( ${#MN_LIST[@]} - master_count )) -gt 0 ]; then
        COLS_NAME=('节点' '主节点' '同步' '主从延迟' '复制落后'); COLS_W=($addrw $addrw 6 10 10); COLS_N=5
        MN_TABLE=()
        for kk in "${!MN_LIST[@]}"; do [ "${MN_ISMASTER[$kk]}" = 0 ] && MN_TABLE+=("${MN_LIST[$kk]}"); done
        mtable '主从复制'
    fi

    # ---- 表 3：持久化与累计计数 ----
    COL_PRIORITY='节点 运行时间 RDB AOF 驱逐键 过期键 从节点 拒绝连接 版本'
    select_cols "$avail" "节点:$addrw" '运行时间:11' '过期键:9' '驱逐键:9' '拒绝连接:8' 'RDB:6' 'AOF:6' '从节点:6' '版本:8'
    MN_TABLE=("${MN_LIST[@]}")
    mtable '持久化与累计计数（自启动以来）'

    # 取不到信息的节点把原因列出来："无法连接"四个字不足以判断是网络、密码还是权限问题
    nbad=0
    for a in "${MN_LIST[@]}"; do
        [ "${OKS[$a]:-0}" = 1 ] && continue
        if [ "$nbad" = 0 ]; then mout '' "$GRAY"; mout '  以下节点的信息取不到:' "$RED"; fi
        nbad=$(( nbad + 1 ))
        mout "  × $a: ${ERRTXT[$a]}" "$RED"
    done

    mout '' "$GRAY"
    mout '  红色 = 有异常：连不上、主从断开、持久化出错、内存占用超过 90%' "$DARKGRAY"
    mout '  命中率 = 两次刷新之间的增量    过期键 / 驱逐键 = 自启动以来的累计数' "$DARKGRAY"
}

monitor_overview() {
    local interval=2 maxcount=0 maxlines=0 done=0 stopped=0 canredraw=0 waited i
    clear_screen
    show_header
    echo
    say '  集群概览' "$YELLOW"
    read_line '  刷新间隔秒数 (回车 = 2，输入 0 只看一次): ' || return 0
    [[ "$REPLY" =~ ^[0-9]+$ ]] && interval=$(( 10#$REPLY ))
    if [ "$interval" -gt 0 ]; then
        read_line '  刷新次数 (回车 = 一直刷新，按任意键停止): ' || return 0
        if [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -gt 0 ]; then maxcount=$(( 10#$REPLY )); fi
    fi
    clear_screen
    show_header
    PREV_H=(); PREV_M=()
    # 记住起始位置，之后每次刷新都从这里开始画
    if [ -t 1 ]; then printf '\0337'; canredraw=1; fi
    while true; do
        [ "$canredraw" = 1 ] && printf '\0338'
        MW=$(tty_width)
        OUT_LINES=0
        monitor_snapshot
        [ "$interval" -gt 0 ] && mout '  刷新中，按任意键停止 ...' "$DARKGRAY"
        # 用空行盖掉上一轮多出来的内容
        for ((i = OUT_LINES; i < maxlines; i++)); do mblank; done
        [ "$OUT_LINES" -gt "$maxlines" ] && maxlines=$OUT_LINES
        done=$(( done + 1 ))
        if [ "$interval" -le 0 ] || { [ "$maxcount" -gt 0 ] && [ "$done" -ge "$maxcount" ]; }; then break; fi
        # 等待下一个刷新点；终端里有按键就停
        waited=0
        while [ "$waited" -lt $(( interval * 10 )) ]; do
            if [ -t 0 ] && IFS= read -r -t 0.1 -n 1 2>/dev/null; then stopped=1; break; fi
            sleep 0.1
            waited=$(( waited + 1 ))
        done
        [ "$stopped" = 1 ] && break
    done
    echo
    [ "$stopped" = 1 ] && say '  已停止刷新' "$GRAY"
    pause
}

# ============ 监控子菜单、慢查询日志、命令与错误统计 ============
# 监控页面用的节点列表：主节点在前，放进 MN_LIST[] / MN_ISMASTER[]。取不到时返回非 0
monitor_nodes() {
    local text id addr flags masterid ping pong epoch state
    local -a masters=() replicas=()
    MN_LIST=(); MN_ISMASTER=()
    text=$(rex CLUSTER NODES) || return 1
    while read -r id addr flags masterid ping pong epoch state; do
        [ -n "$addr" ] || continue
        addr=${addr%%@*}
        case "$flags" in *noaddr*|*handshake*) continue ;; esac
        case "$flags" in *master*) masters+=("$addr") ;; *) replicas+=("$addr") ;; esac
    done <<< "$text"
    for addr in "${masters[@]}"; do MN_LIST+=("$addr"); MN_ISMASTER+=(1); done
    for addr in "${replicas[@]}"; do MN_LIST+=("$addr"); MN_ISMASTER+=(0); done
    [ ${#MN_LIST[@]} -gt 0 ] || return 1
    return 0
}

monitor_menu() {
    local choice width message=''
    while true; do
        width=$(tty_width)
        clear_screen
        show_header "$width"
        echo
        say '  Redis 监控' "$ACCENT"
        menu_item "$width" 1 '集群概览' '内存、连接、吞吐和主从状态'
        menu_item "$width" 2 '慢查询日志' '按时间查看各节点的慢命令'
        menu_item "$width" 3 '命令与错误统计' '命令次数、耗时和错误'
        menu_item "$width" 4 '大 Key 排行' '按节点和前缀采样内存占用'
        echo
        menu_item "$width" 0 '返回' ''
        echo
        [ -n "$message" ] && say "  $message" "$YELLOW"
        message=''
        read_line '  选择 [0–4] > ' || return 0
        choice="$REPLY"
        trim "$choice"; choice="$REPLY"
        case "$choice" in
            1) monitor_overview ;;
            2) show_slowlog ;;
            3) show_stats ;;
            4) show_big_keys ;;
            0) return 0 ;;
            *) message='请输入 0 到 4。' ;;
        esac
    done
}

# ============ 大 Key 排行 ============
literal_prefix_pattern() {
    local pattern="${1//\\/\\\\}"
    pattern=${pattern//\*/\\*}
    pattern=${pattern//\?/\\?}
    pattern=${pattern//\[/\\[}
    pattern=${pattern//\]/\\]}
    REPLY="$pattern*"
}

# CSV 保留 Redis 字符串的引号与转义。读取到 csv_fields，避免 Key 或值内的换行变成分隔符。
parse_redis_csv() {
    local line="$1" field='^("([^"\\]|\\.)*")(,|$)'
    csv_fields=()
    while [ -n "$line" ]; do
        [[ "$line" =~ $field ]] || return 1
        csv_fields+=("${BASH_REMATCH[1]}")
        line=${line:${#BASH_REMATCH[0]}}
    done
}

read_rank_scan() {
    local line
    local -a csv_fields=()
    IFS= read -r line < "$search_file" || return 1
    parse_redis_csv "$line" || return 1
    [[ "${csv_fields[0]:-}" =~ ^\"([0-9]+)\"$ ]] || return 1
    cursor=${BASH_REMATCH[1]}
    scan_fields=("${csv_fields[@]:1}")
}

decode_csv_text() {
    local text="${1:1:${#1}-2}" out='' part char escape='^([^\\]*)\\(x[0-9a-fA-F]{2}|.)'
    while [[ "$text" =~ $escape ]]; do
        part=${BASH_REMATCH[2]}
        case "$part" in
            x00) char='?' ;;
            '"') char='"' ;;
            *) printf -v char '%b' "\\$part" ;;
        esac
        out+="${BASH_REMATCH[1]}$char"
        text=${text:${#BASH_REMATCH[0]}}
    done
    out+="$text"
    REPLY=${out//[[:cntrl:]]/?}
}

display_rank_key() {
    decode_csv_text "$1"
    [ -n "$REPLY" ] || REPLY='(空 Key)'
}

collect_big_keys() {
    local pattern="$1" i node cursor key k offset j cmds overflow
    local -a scan_fields=() pending=()
    local -A seen=()
    for i in "${!nodes[@]}"; do
        search_active || break
        node=${nodes[$i]}; cursor=0
        state[i]='扫描中'
        say "  采样 $(( i + 1 )) / ${#nodes[@]} · $node" "$GRAY"
        while search_active; do
            rounds[i]=$(( ${rounds[i]:-0} + 1 ))
            if ! search_cli '' -h "${node%:*}" -p "${node##*:}" --csv SCAN "$cursor" MATCH "$pattern" COUNT 200 || ! read_rank_scan; then
                state[i]='扫描失败'
                break
            fi
            pending=(); overflow=0
            for key in "${scan_fields[@]}"; do
                [ -n "${seen[$key]+x}" ] && continue
                if [ "${sampled[i]:-0}" -ge "$sample_limit" ]; then overflow=1; break; fi
                sampled[i]=$(( ${sampled[i]:-0} + 1 ))
                seen[$key]=1
                pending+=("$key")
            done
            for ((offset = 0; offset < ${#pending[@]}; offset += 64)); do
                cmds=''
                for ((j = offset; j < offset + 64 && j < ${#pending[@]}; j++)); do
                    cmds+="MEMORY USAGE ${pending[$j]} SAMPLES 5"$'\n'
                done
                if batch "$node" "${cmds%$'\n'}"; then
                    for k in "${!REP[@]}"; do
                        [[ "${REP[$k]}" =~ ^[0-9]+$ ]] || continue
                        measured[i]=$(( ${measured[i]:-0} + 1 ))
                        rank_names+=("${pending[$(( offset + k ))]}")
                        rank_nodes+=("$node")
                        rank_bytes+=("${REP[$k]}")
                    done
                fi
                [ -z "$search_stop" ] || break
            done
            [ -z "$search_stop" ] || break
            if [ "$cursor" = 0 ] && [ "$overflow" = 0 ]; then state[i]='已遍历'; break; fi
            if [ "${sampled[i]:-0}" -ge "$sample_limit" ]; then state[i]='样本上限'; break; fi
            if [ "${rounds[i]}" -ge "$round_limit" ]; then state[i]='轮次上限'; break; fi
        done
        if [ -n "$search_stop" ]; then state[i]='已中止'; break; fi
    done
    sample_stop="$search_stop"
}

read_rank_number() {
    local prompt="$1" default="$2" max="$3" value
    while read_line "$prompt"; do
        trim "$REPLY"; value="$REPLY"
        case "$value" in '') REPLY="$default"; return 0 ;; q|Q) return 1 ;; esac
        if [[ "$value" =~ ^[0-9]{1,5}$ ]] && [ "$value" -lt "$(( max + 1 ))" ] &&
            { [ "$default" -eq 0 ] || [ "$value" -gt 0 ]; }; then
            REPLY=$(( 10#$value ))
            return 0
        fi
        say "  请输入有效序号或数字，q 返回。" "$YELLOW"
    done
    return 1
}

rank_row() {
    local number="$1" memory="$2" node="$3" key="$4" node_width="$5" width="$6" color="$7" line
    pad "$number" 3 1; line="$REPLY  "
    pad "$memory" 10 1; line+="$REPLY  "
    if [ "$node_width" -gt 0 ]; then pad "$node" "$node_width" 0; line+="$REPLY  "; fi
    pad "$key" "$(( width - 20 - node_width - 2 * (node_width > 0) ))" 0
    printf '  '
    say "$line$REPLY" "$color"
}

show_big_key_results() {
    local width psize page=0 mode=rank total start end pages i idx line choice node_width
    local total_sampled=0 failed=0 prefix_label="${prefix:-全部 Key}"
    for i in "${!nodes[@]}"; do
        total_sampled=$(( total_sampled + ${sampled[i]:-0} ))
        [ "${state[i]:-}" != '扫描失败' ] || failed=$(( failed + 1 ))
    done
    while true; do
        width=$(tty_width); psize=$(page_size 0); node_width=0
        [ "$width" -ge 64 ] && node_width=21
        if [ "$mode" = scope ]; then total=${#nodes[@]}; psize=$(( (psize + 1) / 2 ))
        else total=${#rank_order[@]}; fi
        pages=$(( (total + psize - 1) / psize ))
        [ "$pages" -gt 0 ] || pages=1
        [ "$page" -lt "$pages" ] || page=$(( pages - 1 ))
        start=$(( page * psize )); end=$(( start + psize ))
        [ "$end" -le "$total" ] || end=$total
        clear_screen
        show_header "$width"
        echo
        say "  大 Key 排行 · Top $top" "$ACCENT"
        say_fit "  前缀  $prefix_label" "$WHITE" $(( width - 1 ))
        if [ "${#nodes[@]}" -eq 1 ]; then say_fit "  节点  ${nodes[0]}" "$WHITE" $(( width - 1 )); fi
        say "  主节点 ${#nodes[@]} · 采样 $total_sampled · 已测量 ${#rank_bytes[@]}" "$GRAY"
        say_fit "  每节点最多 $sample_limit 个 / $round_limit 轮 · ${SEARCH_SECONDS} 秒" "$GRAY" $(( width - 1 ))
        [ "$failed" -eq 0 ] || say "  节点扫描失败 $failed 个 [s]" "$YELLOW"
        [ -z "$sample_stop" ] || say "  部分结果 · $sample_stop" "$YELLOW"
        echo
        if [ "$mode" = scope ]; then
            say '  采样范围 · 各主节点' "$ACCENT"
            say_fit '  SCAN 游标从 0 开始，按返回顺序取样' "$GRAY" $(( width - 1 ))
            for ((i = start; i < end; i++)); do
                say_fit "  ${nodes[$i]} · ${state[i]:-未开始}" "$WHITE" $(( width - 1 ))
                say_fit "    采样 ${sampled[i]:-0} · 已测量 ${measured[i]:-0} · SCAN ${rounds[i]:-0} 轮" "$GRAY" $(( width - 1 ))
            done
        elif [ "$total" -eq 0 ]; then
            say '  本次采样暂无可排行的 Key。' "$GRAY"
        else
            rank_row '#' 内存 节点 Key "$node_width" "$width" "$TABLE_BAND"
            for ((i = start; i < end; i++)); do
                idx=${rank_order[$i]#* }
                fmt_size "${rank_bytes[$idx]}"; line="$REPLY"
                display_rank_key "${rank_names[$idx]}"
                rank_row $(( i + 1 )) "$line" "${rank_nodes[$idx]}" "$REPLY" "$node_width" "$width" "$WHITE"
            done
        fi
        rule "$width"
        hint_line "第 $(( page + 1 )) / $pages 页" '' '<' 上页 '>' 下页
        if [ "$mode" = rank ]; then hint_line s 采样范围 序号 完整Key q 返回
        else hint_line s 返回排行 q 返回; fi
        read_line '  命令 > ' || return 0
        trim "$REPLY"; choice="$REPLY"
        case "$choice" in
            q|Q) return 0 ;;
            s|S) if [ "$mode" = rank ]; then mode=scope; else mode=rank; fi; page=0 ;;
            '<') [ "$page" -eq 0 ] || page=$(( page - 1 )) ;;
            '>') [ "$(( page + 1 ))" -ge "$pages" ] || page=$(( page + 1 )) ;;
            *)
                if [ "$mode" = rank ] && [[ "$choice" =~ ^[0-9]{1,2}$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$total" ]; then
                    idx=${rank_order[$(( 10#$choice - 1 ))]#* }
                    display_rank_key "${rank_names[$idx]}"
                    say "  Key  $REPLY" "$WHITE"
                    say "  ${rank_nodes[$idx]} · ${rank_bytes[$idx]} B" "$GRAY"
                    pause
                fi ;;
        esac
    done
}

show_big_keys() {
    local i selected prefix pattern top sample_limit sample_stop='' round_limit=50 width
    local -a primary_nodes=() nodes=() state=() rounds=() sampled=() measured=()
    local -a rank_names=() rank_nodes=() rank_bytes=() rank_order=()
    width=$(tty_width)
    clear_screen
    show_header "$width"
    echo
    say '  大 Key 排行' "$ACCENT"
    if ! with_search_budget "$SEARCH_SECONDS" read_primary_nodes; then
        say '  无法读取集群主节点。' "$RED"
        pause
        return
    fi
    mapfile -t primary_nodes < <(printf '%s\n' "${primary_nodes[@]}" | sort -u)
    say '  0) 全部主节点' "$GRAY"
    for i in "${!primary_nodes[@]}"; do say_fit "  $(( i + 1 ))) ${primary_nodes[$i]}" "$GRAY" $(( width - 1 )); done
    read_rank_number '  节点 [默认 0，q 返回] > ' 0 "${#primary_nodes[@]}" || return 0
    selected="$REPLY"
    nodes=("${primary_nodes[@]}")
    [ "$selected" -eq 0 ] || nodes=("${primary_nodes[$(( selected - 1 ))]}")
    read_line '  Key 前缀 [回车 = 全部] > ' || return 0
    prefix="$REPLY"
    literal_prefix_pattern "$prefix"; pattern="$REPLY"
    read_rank_number '  每节点样本数 [1–500，默认 100] > ' 100 500 || return 0
    sample_limit="$REPLY"
    read_rank_number '  Top N [1–50，默认 10] > ' 10 50 || return 0
    top="$REPLY"
    [ -t 0 ] && say '  按 q 停止采样' "$GRAY"
    if ! with_search_budget "$SEARCH_SECONDS" collect_big_keys "$pattern"; then
        say '  无法启动采样，请检查临时目录。' "$RED"
        pause
        return
    fi
    mapfile -t rank_order < <(
        for i in "${!rank_bytes[@]}"; do printf '%s %s\n' "${rank_bytes[$i]}" "$i"; done |
            sort -k1,1nr -k2,2n | head -n "$top"
    )
    show_big_key_results
}

# 把一条慢查询记录追加到 SL_* 数组：$1 时间戳，$2 耗时(微秒)，$3 参数（空格分隔），$4 来源客户端，$5 节点
slowlog_add() {
    local args="$3"
    local -a a=()
    # 控制字符换成 ?，免得把屏幕搅乱
    args=${args//[$'\x01'-$'\x1f'$'\x7f']/?}
    read -r -a a <<< "$args"
    SL_TS[SL_N]="$1"
    SL_DUR[SL_N]="$2"
    SL_NODE[SL_N]="$5"
    SL_CLIENT[SL_N]=$4
    SL_CMD[SL_N]=${a[0]:-}
    if [ ${#a[@]} -gt 1 ]; then SL_ARGS[SL_N]="${args#* }"; else SL_ARGS[SL_N]=''; fi
    SL_N=$(( SL_N + 1 ))
}

# 读一个节点的慢查询日志，记录追加到 SL_* 数组。$1 = 节点地址，$2 = 最多取几条
# redis-cli 在管道里按"原始格式"输出：每个元素一行。一条记录 = 编号、时间戳、耗时、若干个参数、客户端地址、客户端名称，
# 记录之间没有分隔。返回的记录按时间倒序、编号依次减 1，靠编号找到每条记录的起点
slowlog_load() {
    local addr="$1" want="$2" n i start end id expect ts last
    local -a out=() args=()
    mapfile -t out < <(rex_node "${addr%%:*}" "${addr##*:}" --raw SLOWLOG GET "$want")
    n=${#out[@]}
    [ "$n" -ge 5 ] || return 0
    start=0
    while [ "$start" -lt "$n" ]; do
        id=${out[$start]}
        [[ "$id" =~ ^[0-9]+$ ]] || break
        expect=$(( id - 1 ))
        # 下一条记录的起点：等于"编号减 1"、后面紧跟一个 10 位时间戳的那一行
        end=$n
        for ((i = start + 3; i + 1 < n; i++)); do
            if [ "${out[$i]}" = "$expect" ] && [[ "${out[$(( i + 1 ))]}" =~ ^[12][0-9]{9}$ ]]; then
                end=$i
                break
            fi
        done
        if [ $(( end - start )) -ge 5 ]; then
            ts=${out[$(( start + 1 ))]}
            last=${out[$(( end - 1 ))]}
            if [[ "$last" =~ ^[^[:space:]]+:[0-9]+$ ]]; then
                # 旧版本 Redis 的记录末尾没有"客户端名称"这一项
                args=("${out[@]:$(( start + 3 )):$(( end - start - 4 ))}")
                slowlog_add "$ts" "${out[$(( start + 2 ))]}" "${args[*]}" "$last" "$addr"
            else
                args=("${out[@]:$(( start + 3 )):$(( end - start - 5 ))}")
                slowlog_add "$ts" "${out[$(( start + 2 ))]}" "${args[*]}" "${out[$(( end - 2 ))]}" "$addr"
            fi
        fi
        start=$end
    done
}

# 慢查询日志：每个节点各自记录的、执行超过阈值的命令（存在内存里，节点重启就没有了）
show_slowlog() {
    local count=20 a node h p n i w addrw=15 showclient=1 argsw line threshold='' maxlen='' cfgtext
    local rec t d dur dcolor
    local -a lens=() probs=() recs=() cfg=()
    clear_screen
    show_header
    echo
    say '  慢查询日志' "$YELLOW"
    read_line '  每个节点显示最近多少条 (回车 = 20): ' || return 0
    a="$REPLY"
    trim "$a"; a="$REPLY"
    if [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le 128 ]; then count=$(( 10#$a )); fi
    say '  正在读取...' "$DARKGRAY"
    if ! monitor_nodes; then
        clear_screen
        show_header
        echo
        say "  × 取不到集群节点: $(node_reason "$CONFIG_HOST" "$CONFIG_PORT")" "$RED"
        echo
        pause
        return 0
    fi
    SL_N=0; SL_TS=(); SL_DUR=(); SL_NODE=(); SL_CMD=(); SL_ARGS=(); SL_CLIENT=()
    for node in "${MN_LIST[@]}"; do
        h=${node%%:*}; p=${node##*:}
        n=$(rex_node "$h" "$p" SLOWLOG LEN)
        if ! [[ "$n" =~ ^[0-9]+$ ]]; then
            probs+=("$node: $(node_reason "$h" "$p")")
            continue
        fi
        fmt_count "$n"
        lens+=("$p: $REPLY")
        [ ${#node} -gt "$addrw" ] && addrw=${#node}
        if [ -z "$threshold" ]; then
            # 阈值和保留条数是配置项；取不到（比如 CONFIG 被禁用）就标成 ?，不再重复试
            threshold='?'
            cfg=()
            mapfile -t cfg < <(rex_node "$h" "$p" CONFIG GET slowlog-log-slower-than slowlog-max-len)
            # 回复是"名字、值"交替的四行，但顺序不一定和请求的一致，按名字找
            for ((i = 0; i + 1 < ${#cfg[@]}; i += 2)); do
                case "${cfg[$i]%$'\r'}" in
                    slowlog-log-slower-than) threshold=${cfg[$(( i + 1 ))]%$'\r'} ;;
                    slowlog-max-len) maxlen=${cfg[$(( i + 1 ))]%$'\r'} ;;
                esac
            done
        fi
        slowlog_load "$node" "$count"
    done

    clear_screen
    show_header
    echo
    say '  慢查询日志' "$YELLOW"
    n=$SL_N
    fmt_count "$n"
    say "  每个节点最近 $count 条，共 $REPLY 条，新的在前" "$GRAY"
    cfgtext='记录阈值: 未知（CONFIG GET 不可用）'
    if [[ "$threshold" =~ ^-?[0-9]+$ ]]; then
        if [ "$threshold" = -1 ]; then cfgtext='当前不记录（阈值为 -1）'
        elif [ "$threshold" = 0 ]; then cfgtext='记录所有命令（阈值为 0）'
        else cfgtext="记录执行超过 $(awk -v t="$threshold" 'BEGIN { printf "%g", t / 1000 }') 毫秒的命令"
        fi
        [ -n "$maxlen" ] && cfgtext="$cfgtext，每个节点最多保留 $maxlen 条"
    fi
    say "  $cfgtext" "$GRAY"
    if [ ${#lens[@]} -gt 0 ]; then
        line="  各节点现有记录:  ${lens[0]}"
        for ((i = 1; i < ${#lens[@]}; i++)); do line+="    ${lens[$i]}"; done
        say "$line" "$GRAY"
    fi
    for line in "${probs[@]}"; do say "  × 取不到 $line" "$RED"; done
    if [ "$n" = 0 ]; then
        echo
        say '  没有慢查询记录' "$GRAY"
        echo
        pause
        return 0
    fi

    w=$(tty_width)
    # 列：时间 14 + 耗时 9 + 节点 + 命令 10 + 来源 21 + 参数（占剩下的宽度）；窗口窄时先去掉"来源"
    showclient=1
    argsw=$(( w - 1 - (2 + 14 + 2 + 9 + 2 + addrw + 2 + 10 + 2 + 21 + 2) ))
    if [ "$argsw" -lt 12 ]; then
        showclient=0
        argsw=$(( w - 1 - (2 + 14 + 2 + 9 + 2 + addrw + 2 + 10 + 2) ))
    fi
    [ "$argsw" -lt 12 ] && argsw=12
    rule "$w"
    line='  '
    pad '时间' 14 0; line+="$REPLY  "
    pad '耗时' 9 1; line+="$REPLY  "
    pad '节点' "$addrw" 0; line+="$REPLY  "
    pad '命令' 10 0; line+="$REPLY  "
    pad '参数' "$argsw" 0; line+="$REPLY"
    if [ "$showclient" = 1 ]; then line+='  '; pad '来源客户端' 21 1; line+="$REPLY"; fi
    say "$line" "$CYAN"
    # 按时间倒序：每条记录是"时间戳 + 编号"，排好序再按编号取行
    recs=()
    for ((i = 0; i < n; i++)); do recs+=("${SL_TS[$i]}"$'\001'"$i"); done
    while IFS= read -r -d '' rec; do
        i=${rec##*$'\001'}
        printf -v t '%(%m-%d %H:%M:%S)T' "${SL_TS[$i]}" 2>/dev/null || t=${SL_TS[$i]}
        d=${SL_DUR[$i]}
        dur='-'
        if [[ "$d" =~ ^[0-9]+$ ]]; then
            if [ "$d" -ge 1000000 ]; then dur="$(( d / 1000000 )).$(( (d % 1000000) / 10000 )) s"
            else dur="$(( d / 1000 )).$(( (d % 1000) / 100 )) ms"
            fi
        fi
        dcolor="$GRAY"
        [[ "$d" =~ ^[0-9]+$ ]] && [ "$d" -ge 30000 ] && dcolor="$YELLOW"
        [[ "$d" =~ ^[0-9]+$ ]] && [ "$d" -ge 100000 ] && dcolor="$RED"
        printf '  '
        pad "$t" 14 0; sayn "$REPLY" "$GRAY"; printf '  '
        pad "$dur" 9 1; sayn "$REPLY" "$dcolor"; printf '  '
        pad "${SL_NODE[$i]}" "$addrw" 0; sayn "$REPLY" "$WHITE"; printf '  '
        pad "${SL_CMD[$i]}" 10 0; sayn "$REPLY" "$CYAN"; printf '  '
        pad "${SL_ARGS[$i]}" "$argsw" 0; sayn "$REPLY" "$GRAY"
        if [ "$showclient" = 1 ]; then
            printf '  '
            pad "${SL_CLIENT[$i]}" 21 1; say "$REPLY" "$DARKGRAY"
        else
            echo
        fi
    done < <(printf '%s\0' "${recs[@]}" | sort -z -t $'\001' -k1,1nr)
    rule "$w"
    say '  耗时: 黄色 ≥ 30 毫秒，红色 ≥ 100 毫秒' "$DARKGRAY"
    say '  阻塞类命令（如 XREAD … BLOCK）等待数据的时间也算在耗时里' "$DARKGRAY"
    echo
    pause
}

# 报错代码 → 中文说明（放进 REPLY）
error_desc() {
    case "$1" in
        WRONGPASS) REPLY='密码错误' ;;
        NOAUTH) REPLY='没有认证' ;;
        NOPERM) REPLY='没有权限' ;;
        CLUSTERDOWN) REPLY='集群不可用' ;;
        MOVED) REPLY='请求发到了错误的节点' ;;
        ASK) REPLY='要求跳转到其它节点' ;;
        TRYAGAIN) REPLY='集群迁移中，需要重试' ;;
        CROSSSLOT) REPLY='Key 不在同一个槽' ;;
        READONLY) REPLY='从节点只读' ;;
        MASTERDOWN) REPLY='主节点不可用' ;;
        NOSCRIPT) REPLY='脚本还没加载' ;;
        BUSY) REPLY='脚本正在执行' ;;
        BUSYKEY) REPLY='目标 Key 已存在' ;;
        LOADING) REPLY='节点正在加载数据' ;;
        OOM) REPLY='内存不足' ;;
        EXECABORT) REPLY='事务被中止' ;;
        WRONGTYPE) REPLY='Key 类型不匹配' ;;
        NOREPLICAS) REPLY='从节点数量不足' ;;
        ERR) REPLY='其它错误' ;;
        *) REPLY='' ;;
    esac
}

# 按当前 COLS_* 画一行：参数是 "列名=内容"，只画选中的列。颜色取 ROWCOLOR
cols_row() {
    local -a c=("$@")
    local line='  ' k right v arg
    for k in "${!COLS_NAME[@]}"; do
        v=''
        for arg in "${c[@]}"; do
            if [ "${arg%%=*}" = "${COLS_NAME[$k]}" ]; then v=${arg#*=}; fi
        done
        right=0
        [ "$k" -gt 0 ] && right=1
        pad "$v" "${COLS_W[$k]}" "$right"
        line+="$REPLY  "
    done
    say "${line%  }" "${ROWCOLOR:-$WHITE}"
}

cols_header() {
    local -a h=()
    local k
    for k in "${!COLS_NAME[@]}"; do h+=("${COLS_NAME[$k]}"); done
    ROWCOLOR="$CYAN" cols_row "${h[@]}"
}

# 命令与错误统计：INFO 里的累计数，自各节点启动以来
show_stats() {
    local a node h p k name val info w samehost=1 firsthost='' addrw=15
    local line v vcolor cnt total showdesc shown avg unit num
    local -a pairs=() enames=()
    declare -A ST_OK=() ST_ROLE=() ST_LABEL=() ST_UPTIME=() ST_CMDS=() ST_CONNS=() ST_ERRREP=()
    declare -A ERRN=() ERRTOT=() ERRSEEN=() NCOLW=()
    declare -A ERRN2=() ST_OK2=() ST_ERRREP2=()
    declare -A CM_CALLS=() CM_USEC=() CM_FAIL=() CM_REJ=()
    clear_screen
    show_header
    echo
    say '  命令与错误统计' "$YELLOW"
    say '  自各节点启动以来的累计数（节点重启或执行 CONFIG RESETSTAT 后清零）' "$DARKGRAY"
    say '  正在读取...' "$DARKGRAY"
    if ! monitor_nodes; then
        clear_screen
        show_header
        echo
        say "  × 取不到集群节点: $(node_reason "$CONFIG_HOST" "$CONFIG_PORT")" "$RED"
        echo
        pause
        return 0
    fi
    # 所有节点在同一台机器上时，列标题只写端口和角色（如 2320主），节省宽度
    for node in "${MN_LIST[@]}"; do
        a=${node%%:*}
        if [ -z "$firsthost" ]; then firsthost=$a
        elif [ "$a" != "$firsthost" ]; then samehost=0
        fi
    done
    for a in "${!MN_LIST[@]}"; do
        node=${MN_LIST[$a]}
        h=${node%%:*}; p=${node##*:}
        if [ "${MN_ISMASTER[$a]}" = 1 ]; then ST_ROLE[$node]='主'; else ST_ROLE[$node]='从'; fi
        if [ "$samehost" = 1 ]; then ST_LABEL[$node]="$p${ST_ROLE[$node]}"; else ST_LABEL[$node]=$node; fi
        [ ${#node} -gt "$addrw" ] && addrw=${#node}
        info=$(rex_node "$h" "$p" INFO)
        if [[ "$info" != *redis_version:* ]]; then ST_OK[$node]=0; continue; fi
        ST_OK[$node]=1
        parse_info "$node" "$info"
        ST_UPTIME[$node]=${INFO[$node|uptime_in_seconds]:-}
        ST_CMDS[$node]=${INFO[$node|total_commands_processed]:-}
        ST_CONNS[$node]=${INFO[$node|total_connections_received]:-}
        ST_ERRREP[$node]=${INFO[$node|total_error_replies]:-}
        # 各类报错的次数（INFO 里是 "errorstat_代码:count=N"）
        for k in "${!INFO[@]}"; do
            case "$k" in
                "$node|errorstat_"*)
                    name=${k#"$node|errorstat_"}
                    val=${INFO[$k]#count=}
                    [[ "$val" =~ ^[0-9]+$ ]] || continue
                    ERRN["$node|$name"]=$val
                    ERRSEEN[$name]=1
                    ERRTOT[$name]=$(( ${ERRTOT[$name]:-0} + val ))
                    ;;
            esac
        done
        [ "${MN_ISMASTER[$a]}" = 1 ] || continue
        # INFO 不带参数时不包含"命令统计"这一段，要单独取。只合计主节点的（从节点上的主要是复制和心跳）
        info=$(rex_node "$h" "$p" INFO commandstats)
        parse_info "$node" "$info"
        for k in "${!INFO[@]}"; do
            case "$k" in
                "$node|cmdstat_"*)
                    name=${k#"$node|cmdstat_"}
                    IFS=',' read -r -a pairs <<< "${INFO[$k]}"
                    local c=0 u=0 f=0 r=0 pr
                    for pr in "${pairs[@]}"; do
                        case "$pr" in
                            calls=*) c=${pr#calls=} ;;
                            usec=*) u=${pr#usec=} ;;
                            failed_calls=*) f=${pr#failed_calls=} ;;
                            rejected_calls=*) r=${pr#rejected_calls=} ;;
                        esac
                    done
                    [[ "$c" =~ ^[0-9]+$ ]] || c=0
                    [[ "$u" =~ ^[0-9]+$ ]] || u=0
                    [[ "$f" =~ ^[0-9]+$ ]] || f=0
                    [[ "$r" =~ ^[0-9]+$ ]] || r=0
                    CM_CALLS[$name]=$(( ${CM_CALLS[$name]:-0} + c ))
                    CM_USEC[$name]=$(( ${CM_USEC[$name]:-0} + u ))
                    CM_FAIL[$name]=$(( ${CM_FAIL[$name]:-0} + f ))
                    CM_REJ[$name]=$(( ${CM_REJ[$name]:-0} + r ))
                    ;;
            esac
        done
    done

    # 第二次取样：隔 10 秒再读一遍报错计数，两次之差就是这 10 秒里新发生的
    say '  等 10 秒后取第二次样本...' "$DARKGRAY"
    sleep 10
    for node in "${MN_LIST[@]}"; do
        [ "${ST_OK[$node]:-0}" = 1 ] || continue
        info=$(rex_node "${node%%:*}" "${node##*:}" INFO)
        [[ "$info" == *redis_version:* ]] || continue
        while IFS= read -r line; do
            line=${line%$'\r'}
            case "$line" in
                total_error_replies:*) ST_ERRREP2[$node]=${line#*:} ;;
                errorstat_*)
                    name=${line#errorstat_}
                    name=${name%%:*}
                    val=${line##*:}
                    val=${val#count=}
                    [[ "$val" =~ ^[0-9]+$ ]] && ERRN2["$node|$name"]=$val
                    ;;
            esac
        done <<< "$info"
        ST_OK2[$node]=1
    done

    clear_screen
    show_header
    echo
    say '  命令与错误统计' "$YELLOW"
    say '  自各节点启动以来的累计数' "$GRAY"
    w=$(tty_width)
    MW=$w

    # ---- 表 1：各节点总量 ----
    # 窗口窄时按这个先后保留列："近10秒新增"是判断健康最关键的，排在累计数前面
    COL_PRIORITY='节点 角色 近10秒新增 错误回复 运行时间 累计命令 累计连接'
    select_cols $(( w - 3 )) "节点:$addrw" '角色:4' '运行时间:11' '累计命令:16' '累计连接:12' '错误回复:12' '近10秒新增:12'
    mout '' "$GRAY"
    mout '  各节点总量' "$CYAN"
    cols_header
    local er dtext rcolor d
    for node in "${MN_LIST[@]}"; do
        if [ "${ST_OK[$node]:-0}" = 1 ]; then
            fmt_uptime "${ST_UPTIME[$node]}"; a="$REPLY"
            fmt_count "${ST_CMDS[$node]}"; v="$REPLY"
            fmt_count "${ST_CONNS[$node]}"; cnt="$REPLY"
            # 累计数显示第二次样本（更新），和"近10秒新增"正好对得上
            er=${ST_ERRREP[$node]}
            [ "${ST_OK2[$node]:-0}" = 1 ] && [ -n "${ST_ERRREP2[$node]}" ] && er=${ST_ERRREP2[$node]}
            fmt_count "$er"; total="$REPLY"
            # 这 10 秒里新增的错误回复数（两次取样之差）
            dtext='?'
            rcolor="$WHITE"
            if [ "${ST_OK2[$node]:-0}" = 1 ] && [[ "${ST_ERRREP[$node]}" =~ ^[0-9]+$ ]] && [[ "${ST_ERRREP2[$node]}" =~ ^[0-9]+$ ]]; then
                d=$(( ST_ERRREP2[$node] - ST_ERRREP[$node] ))
                dtext='-'
                if [ "$d" -gt 0 ]; then dtext="+$d"; rcolor="$YELLOW"
                elif [ "$d" -lt 0 ]; then dtext="$d"; rcolor="$YELLOW"
                fi
            fi
            ROWCOLOR="$rcolor" cols_row "节点=$node" "角色=${ST_ROLE[$node]}" "运行时间=$a" "累计命令=$v" "累计连接=$cnt" "错误回复=$total" "近10秒新增=$dtext"
        else
            ROWCOLOR="$RED" cols_row "节点=$node" "角色=${ST_ROLE[$node]}" '运行时间=× 取不到' '累计命令=—' '累计连接=—' '错误回复=—' '近10秒新增=—'
        fi
    done

    # ---- 表 2：各类报错的次数，每个节点一列，按合计从多到少排 ----
    if [ ${#ERRTOT[@]} -gt 0 ]; then
        enames=()
        while IFS=$'\t' read -r cnt name; do enames+=("$name"); done < <(for name in "${!ERRTOT[@]}"; do printf '%s\t%s\n' "${ERRTOT[$name]}" "$name"; done | sort -t $'\t' -k1,1nr -k2,2)
        for node in "${MN_LIST[@]}"; do
            cnt=$(str_width "${ST_LABEL[$node]}")
            [ "$cnt" -lt 5 ] && cnt=5
            for name in "${enames[@]}"; do
                fmt_count "${ERRN[$node|$name]:-0}"
                [ ${#REPLY} -gt "$cnt" ] && cnt=${#REPLY}
            done
            NCOLW[$node]=$cnt
        done
        # 放不下时先去掉"说明"列
        total=$(( 2 + 16 + 2 + 12 ))
        for node in "${MN_LIST[@]}"; do total=$(( total + 2 + NCOLW[$node] )); done
        showdesc=0
        [ $(( total + 2 + 22 )) -le $(( w - 1 )) ] && showdesc=1
        local -a dlines=() parts=()
        local dknown=0 dseen=0 dsum unknown part i dcolor
        for node in "${MN_LIST[@]}"; do [ "${ST_OK2[$node]:-0}" = 1 ] && dknown=1; done
        mout '' "$GRAY"
        mout '  各类报错的次数' "$CYAN"
        line='  '
        pad '报错' 16 0; line+="$REPLY"
        if [ "$showdesc" = 1 ]; then line+='  '; pad '说明' 22 0; line+="$REPLY"; fi
        line+='  '; pad '近10秒新增' 12 1; line+="$REPLY"
        for node in "${MN_LIST[@]}"; do line+='  '; pad "${ST_LABEL[$node]}" "${NCOLW[$node]}" 1; line+="$REPLY"; done
        say "$line" "$CYAN"
        for name in "${enames[@]}"; do
            # 近 10 秒新增：每个节点两次取样之差，再合计；有变化的节点记下来
            dsum=0
            unknown=0
            parts=()
            for node in "${MN_LIST[@]}"; do
                if [ "${ST_OK2[$node]:-0}" != 1 ]; then unknown=1; continue; fi
                d=$(( ${ERRN2[$node|$name]:-0} - ${ERRN[$node|$name]:-0} ))
                dsum=$(( dsum + d ))
                if [ "$d" -gt 0 ]; then parts+=("${ST_LABEL[$node]} +$d")
                elif [ "$d" -lt 0 ]; then parts+=("${ST_LABEL[$node]} $d")
                fi
            done
            dtext='-'
            dcolor="$DARKGRAY"
            if [ "$dsum" -gt 0 ]; then dtext="+$dsum"; dcolor="$YELLOW"
            elif [ "$dsum" -lt 0 ]; then dtext="$dsum"; dcolor="$YELLOW"
            elif [ "$unknown" = 1 ]; then dtext='?'
            fi
            line='  '
            pad "$name" 16 0; line+="$REPLY"
            if [ "$showdesc" = 1 ]; then error_desc "$name"; line+='  '; pad "$REPLY" 22 0; line+="$REPLY"; fi
            sayn "$line" "$WHITE"
            printf '  '
            pad "$dtext" 12 1; sayn "$REPLY" "$dcolor"
            for node in "${MN_LIST[@]}"; do
                vcolor="$DARKGRAY"
                if [ "${ST_OK[$node]:-0}" != 1 ]; then
                    v='—'
                # 累计数显示第二次样本（更新），和"近10秒新增"正好对得上
                elif [ "${ST_OK2[$node]:-0}" = 1 ] && [ -n "${ERRN2[$node|$name]+x}" ]; then
                    vcolor="$WHITE"
                    fmt_count "${ERRN2[$node|$name]}"
                    v="$REPLY"
                elif [ -n "${ERRN[$node|$name]+x}" ]; then
                    vcolor="$WHITE"
                    fmt_count "${ERRN[$node|$name]}"
                    v="$REPLY"
                else
                    v='-'
                fi
                pad "$v" "${NCOLW[$node]}" 1
                printf '  '
                sayn "$REPLY" "$vcolor"
            done
            echo
            if [ ${#parts[@]} -gt 0 ]; then
                dseen=1
                part="${parts[0]}"
                for ((i = 1; i < ${#parts[@]}; i++)); do part+="    ${parts[$i]}"; done
                dlines+=("$name 近 10 秒新增 $dsum: $part")
            fi
        done
        # 有新增的报错列出来是哪些节点；一个都没有就说明表里的数字都是历史
        for part in "${dlines[@]}"; do say "  $part" "$YELLOW"; done
        if [ "$dseen" = 0 ] && [ "$dknown" = 1 ]; then
            say '  近 10 秒内所有节点的报错计数都没有变化，表里的数字都是历史累计' "$GRAY"
        fi
    fi

    # ---- 表 3：主节点合计的命令，按次数从多到少排 ----
    if [ ${#CM_CALLS[@]} -gt 0 ]; then
        # 列也按窗口宽度取舍
        COL_PRIORITY='命令 次数 平均耗时 失败 被拒绝'
        select_cols $(( w - 3 )) '命令:18' '次数:18' '平均耗时:12' '失败:14' '被拒绝:14'
        mout '' "$GRAY"
        mout '  主节点合计的命令（按次数排序，前 20）' "$CYAN"
        cols_header
        shown=0
        while IFS=$'\t' read -r cnt name; do
            shown=$(( shown + 1 ))
            [ "$shown" -gt 20 ] && break
            avg='-'
            ROWCOLOR="$WHITE"
            if [ "$cnt" -gt 0 ] && [[ "${CM_USEC[$name]}" =~ ^[0-9]+$ ]]; then
                avg=$(awk -v u="${CM_USEC[$name]}" -v c="$cnt" 'BEGIN { a = u / c; if (a >= 1000) printf "ms %.2f", a / 1000; else printf "us %.0f", a }')
                unit=${avg%% *}
                num=${avg#* }
                if [ "$unit" = ms ]; then avg="$num 毫秒"; ROWCOLOR="$YELLOW"; else avg="$num 微秒"; fi
            fi
            fmt_count "$cnt"; a="$REPLY"
            fmt_count "${CM_FAIL[$name]:-0}"; v="$REPLY"
            fmt_count "${CM_REJ[$name]:-0}"; total="$REPLY"
            cols_row "命令=${name//|/ }" "次数=$a" "平均耗时=$avg" "失败=$v" "被拒绝=$total"
        done < <(for name in "${!CM_CALLS[@]}"; do printf '%s\t%s\n' "${CM_CALLS[$name]}" "$name"; done | sort -t $'\t' -k1,1nr -k2,2)
        if [ ${#CM_CALLS[@]} -gt 20 ]; then mout "  ... 还有 $(( ${#CM_CALLS[@]} - 20 )) 种命令没有列出" "$DARKGRAY"; fi
    fi

    # 取不到信息的节点把原因列出来
    shown=0
    for node in "${MN_LIST[@]}"; do
        [ "${ST_OK[$node]:-0}" = 1 ] && continue
        if [ "$shown" = 0 ]; then mout '' "$GRAY"; mout '  以下节点的信息取不到:' "$RED"; fi
        shown=$(( shown + 1 ))
        mout "  × $node: $(node_reason "${node%%:*}" "${node##*:}")" "$RED"
    done

    mout '' "$GRAY"
    mout '  近10秒新增: 两次取样（间隔 10 秒）之差，为 - 表示当前没有发生' "$DARKGRAY"
    mout '  平均耗时 = 该命令的总耗时 ÷ 次数' "$DARKGRAY"
    mout '  累计数在节点重启或执行 CONFIG RESETSTAT 后清零' "$DARKGRAY"
    echo
    pause
}

# ============ 主菜单 ============
menu_item() {
    local width="$1" shortcut="$2" label="$3" detail="$4" paired="${5:-0}"
    printf '  '
    sayn "[$shortcut]" "$ACCENT"
    printf '  '
    if [ "$paired" = 1 ]; then
        pad "$label" 16 0; sayn "$REPLY" "$WHITE"
        pad "  $detail" $(( width - 23 )) 0; sayn "$REPLY" "$GRAY"
    elif [ "$width" -ge 64 ] && [ -n "$detail" ]; then
        pad "$label" 16 0; sayn "$REPLY" "$WHITE"
        say_fit "  $detail" "$GRAY" $(( width - 24 ))
    else
        say "$label" "$WHITE"
    fi
}

main_menu() {
    local choice width message='' write_label left paired i
    local -a tools=('查询单个 Key' '搜索 Key' 'Redis 监控')
    local -a descriptions=('类型、过期、大小和值' '关键词、类型和前缀' '健康状态、慢查询与错误')
    local -a session_keys=(4 5 0) session_items=()
    while true; do
        width=$(tty_width)
        clear_screen
        show_header "$width"
        echo
        write_label='开启写入'
        [ "$ALLOW_WRITES" = 1 ] && write_label='恢复只读'
        session_items=('连接配置' "$write_label" '退出')
        left=$width; paired=0
        if [ "$width" -ge 90 ]; then
            left=54; paired=1
            pad '  浏览和诊断' "$left" 0; sayn "$REPLY" "$ACCENT"
            say '  会话' "$ACCENT"
        else
            say '  浏览和诊断' "$ACCENT"
        fi
        for i in "${!tools[@]}"; do
            menu_item "$left" $(( i + 1 )) "${tools[$i]}" "${descriptions[$i]}" "$paired"
            if [ "$paired" = 1 ]; then
                menu_item $(( width - left )) "${session_keys[$i]}" "${session_items[$i]}" ''
            fi
        done
        if [ "$paired" = 0 ]; then
            echo
            say '  会话' "$ACCENT"
            for i in "${!session_items[@]}"; do
                menu_item "$width" "${session_keys[$i]}" "${session_items[$i]}" ''
            done
        fi
        echo
        [ -n "$message" ] && say "  $message" "$YELLOW"
        message=''
        read_line '  选择 [0–5] > ' || return 0
        choice="$REPLY"
        trim "$choice"; choice="$REPLY"
        case "$choice" in
            1) query_key ;;
            2) key_list '' ;;
            3) monitor_menu ;;
            4) do_login ;;
            5) toggle_write_mode ;;
            0) clear_screen; say '  再见' "$GREEN"; return 0 ;;
            *) message='请输入 0 到 5。' ;;
        esac
    done
}

# ============ 入口 ============
NKEYS=0; V_N=0
K_KEY=(); K_NODE=(); K_TYPE=(); K_TTL=(); K_SIZE=(); K_SIZETXT=(); K_PFX=()
V_ROW=(); SPECS=(); REP=(); SEARCH_WARN=(); NODES_TO_TOUCH=(); names=(); parts=()
REMOVED=0; FAILED=0; FIND_ERROR=''; SEARCH_STOP=''
NOEXPIRE=0; TYPEFILTER=""; PREFIXFILTER=""; GROUPED=1; PAGE=0; DIRTY=1; PAGE=0
MESSAGE=""; MSGCOLOR="$GRAY"; LIST_ACTION=back; TCOLOR=""; COL_PRIORITY=''
SL_N=0; SL_TS=(); SL_DUR=(); SL_NODE=(); SL_CMD=(); SL_ARGS=(); SL_CLIENT=(); ROWCOLOR="$WHITE"

main() {
    if [ "${1:-}" = --profile ]; then
        if [ "$#" -ne 2 ] || ! profile_file "$2"; then
            say '  用法: redis-tui.sh --profile "连接名"' "$YELLOW"
            exit 1
        fi
        connect_saved_profile "$REPLY" || exit 1
    elif [ "$#" -ge 2 ]; then
        CONFIG_HOST="$1"; CONFIG_PORT="$2"; CONFIG_PASS="${3:-}"
        if [ -z "$CONFIG_HOST" ]; then do_login || exit 1
        else set_login || exit 1; fi
    else
        do_login || exit 1
    fi
    main_menu
}

main "$@"
