#!/usr/bin/env bash
set -euo pipefail

# -----------------------
# 彩色输出函数
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

# -----------------------
# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
    else
        OS_ID=""
        OS_ID_LIKE=""
    fi

    if echo "$OS_ID $OS_ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

detect_os
info "检测到系统: $OS (${OS_ID:-unknown})"

# -----------------------
# 检查 root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        err "此脚本需要 root 权限"
        err "请使用: sudo bash -c \"\$(curl -fsSL ...)\" 或切换到 root 用户"
        exit 1
    fi
}

check_root

# -----------------------
# 安装依赖
install_deps() {
    info "安装系统依赖..."
    
    case "$OS" in
        alpine)
            apk update || { err "apk update 失败"; exit 1; }
            apk add --no-cache bash curl ca-certificates openssl openrc jq || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y || { err "apt update 失败"; exit 1; }
            apt-get install -y curl ca-certificates openssl jq || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        redhat)
            yum install -y curl ca-certificates openssl jq || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        *)
            warn "未识别的系统类型,尝试继续..."
            ;;
    esac
    
    info "依赖安装完成"
}

install_deps

# -----------------------
# 工具函数
# 生成随机端口
rand_port() {
    local port
    port=$(shuf -i 10000-60000 -n 1 2>/dev/null) || port=$((RANDOM % 50001 + 10000))
    echo "$port"
}

# 生成随机密码
rand_pass() {
    local pass
    pass=$(openssl rand -base64 16 2>/dev/null | tr -d '\n\r') || pass=$(head -c 16 /dev/urandom | base64 2>/dev/null | tr -d '\n\r')
    echo "$pass"
}

# 生成UUID
rand_uuid() {
    local uuid
    if [ -f /proc/sys/kernel/random/uuid ]; then
        uuid=$(cat /proc/sys/kernel/random/uuid)
    else
        uuid=$(openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/')
    fi
    echo "$uuid"
}

# -----------------------
# 配置节点名称后缀
echo "请输入节点名称(留空则默认议名):"
read -r user_name
if [[ -n "$user_name" ]]; then
    suffix="-${user_name}"
    echo "$suffix" > /root/node_names.txt
else
    suffix=""
fi

# -----------------------
# 选择要部署的协议
select_protocols() {
    info "=== 选择要部署的协议 ==="
    echo "1) Shadowsocks (SS)"
    echo "2) Hysteria2 (HY2)"
    echo "3) TUIC"
    echo "4) VLESS Reality"
    echo "5) AnyTLS Reality"
    echo ""
    echo "请输入要部署的协议编号(多个用空格分隔,如: 1 2 4):"
    read -r protocol_input
    
    # 使用全局变量
    ENABLE_SS=false
    ENABLE_HY2=false
    ENABLE_TUIC=false
    ENABLE_REALITY=false
    ENABLE_ANYTLS=false
    
    for num in $protocol_input; do
        case "$num" in
            1) ENABLE_SS=true ;;
            2) ENABLE_HY2=true ;;
            3) ENABLE_TUIC=true ;;
            4) ENABLE_REALITY=true ;;
            5) ENABLE_ANYTLS=true ;;
            *) warn "无效选项: $num" ;;
        esac
    done
    
    if ! $ENABLE_SS && ! $ENABLE_HY2 && ! $ENABLE_TUIC && ! $ENABLE_REALITY && ! $ENABLE_ANYTLS; then
        err "未选择任何协议,退出安装"
        exit 1
    fi
    
    # 保存协议选择到文件（确保持久化）
    mkdir -p /etc/sing-box
    cat > /etc/sing-box/.protocols <<EOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
ENABLE_ANYTLS=$ENABLE_ANYTLS
EOF
    
    info "已选择协议:"
    $ENABLE_SS && echo "  - Shadowsocks"
    $ENABLE_HY2 && echo "  - Hysteria2"
    $ENABLE_TUIC && echo "  - TUIC"
    $ENABLE_REALITY && echo "  - VLESS Reality"
    $ENABLE_ANYTLS && echo "  - AnyTLS Reality"
    
    # 导出为全局变量（确保后续脚本可以访问）
    export ENABLE_SS
    export ENABLE_HY2
    export ENABLE_TUIC
    export ENABLE_REALITY
    export ENABLE_ANYTLS
}

# 创建配置目录
mkdir -p /etc/sing-box
select_protocols

# -----------------------
# 选择SS加密方式（新增）
select_ss_method() {
    if ! $ENABLE_SS; then
        SS_METHOD="2022-blake3-aes-128-gcm"
        return 0
    fi
    
    info "=== 选择 Shadowsocks 加密方式 ==="
    echo "1) 2022-blake3-aes-128-gcm (推荐)"
    echo "2) aes-128-gcm"
    echo ""
    echo "请输入选择(默认为 1):"
    read -r ss_method_choice
    
    case "${ss_method_choice:-1}" in
        1) SS_METHOD="2022-blake3-aes-128-gcm" ;;
        2) SS_METHOD="aes-128-gcm" ;;
        *) 
            warn "无效选择，使用默认方式: 2022-blake3-aes-128-gcm"
            SS_METHOD="2022-blake3-aes-128-gcm"
            ;;
    esac
    
    info "已选择加密方式: $SS_METHOD"
    export SS_METHOD
}

select_ss_method

# -----------------------
# Reality 目标发现与优选
REALITY_SCAN_CANDIDATES=(
    "www.cloudflare.com"
    "www.microsoft.com"
    "www.amazon.com"
    "aws.amazon.com"
    "www.samsung.com"
    "www.nvidia.com"
    "www.amd.com"
    "www.intel.com"
    "www.sony.com"
    "dl.google.com"
)
REALITY_SCAN_ATTEMPTS=3
REALITY_SCAN_TIMEOUT=10
REALITY_SCAN_MAX_IMPORT=50
REALITY_SCAN_CONCURRENCY=5

normalize_reality_host() {
    local host="${1:-}"
    host="$(printf '%s' "$host" | tr -d '\r' | xargs 2>/dev/null || true)"
    host="${host#https://}"
    host="${host#http://}"
    host="${host%%/*}"
    host="${host%%:*}"
    host="${host#.}"
    printf '%s' "$host" | tr '[:upper:]' '[:lower:]'
}

is_valid_reality_host() {
    local host
    host="$(normalize_reality_host "${1:-}")"
    [[ -n "$host" && "$host" != \*.* && "$host" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$host" == *.* ]]
}

reality_tls_probe_once() {
    local host="$1"
    local output status=0 start_ms end_ms latency_ms group_option
    local -a group_args=()

    group_option="$(reality_openssl_group_args)" || {
        printf '%s\n' "ERR|当前 OpenSSL 不支持 X25519 参数"
        return 1
    }
    read -r -a group_args <<< "$group_option"
    start_ms="$(now_millis)"
    output=$(printf '\n' | timeout "$REALITY_SCAN_TIMEOUT" openssl s_client \
        -connect "${host}:443" \
        -servername "$host" \
        -tls1_3 \
        -alpn h2 \
        "${group_args[@]}" \
        -verify_hostname "$host" \
        -verify_return_error 2>&1 | tr -d '\000') || status=$?
    end_ms="$(now_millis)"

    if (( status != 0 )); then
        if (( status == 124 || status == 137 )); then
            printf '%s\n' "ERR|TLS 握手超时"
        elif grep -Eqi 'unknown option|unrecognized option|unknown cipher|no groups' <<< "$output"; then
            printf '%s\n' "ERR|OpenSSL 参数不兼容"
        else
            printf '%s\n' "ERR|TLS 握手失败"
        fi
        return 1
    fi

    if ! grep -Eq 'Protocol *: TLSv1\.3|Protocol version: TLSv1\.3|New, TLSv1\.3' <<< "$output"; then
        printf '%s\n' "ERR|不支持 TLS 1.3"
        return 1
    fi
    if ! grep -Eqi 'ALPN protocol: h2|Negotiated ALPN protocol: h2' <<< "$output"; then
        printf '%s\n' "ERR|未协商 h2"
        return 1
    fi
    if ! grep -Eq 'Verify return code: 0 \(ok\)|Verification: OK' <<< "$output"; then
        printf '%s\n' "ERR|证书校验失败"
        return 1
    fi

    latency_ms=$((end_ms - start_ms))
    (( latency_ms > 0 )) || latency_ms=1
    printf '%s\n' "OK|$latency_ms"
}

now_millis() {
    local value
    value="$(date +%s%3N 2>/dev/null || true)"
    if [[ "$value" =~ ^[0-9]{13,}$ ]]; then
        printf '%s\n' "$value"
    else
        printf '%s\n' "$(( $(date +%s) * 1000 ))"
    fi
}

reality_openssl_group_args() {
    local help
    if [[ -n "${REALITY_OPENSSL_GROUP_OPTION:-}" ]]; then
        printf '%s\n' "$REALITY_OPENSSL_GROUP_OPTION"
        return 0
    fi
    help="$(openssl s_client -help 2>&1 || true)"
    if grep -q -- '-groups' <<< "$help"; then
        printf '%s\n' '-groups X25519'
    elif grep -q -- '-curves' <<< "$help"; then
        printf '%s\n' '-curves X25519'
    else
        return 1
    fi
}

median_latency() {
    printf '%s\n' "$@" | sort -n | awk '{ values[NR]=$1 } END { if (NR) print values[int((NR+1)/2)] }'
}

scan_reality_candidate() {
    local host="$1"
    local attempt probe latency successes=0 last_reason="未知错误"
    local -a latencies=()

    for ((attempt=1; attempt<=REALITY_SCAN_ATTEMPTS; attempt++)); do
        if probe=$(reality_tls_probe_once "$host"); then
            latency="${probe#OK|}"
            latencies+=("$latency")
            successes=$((successes + 1))
        else
            last_reason="${probe#ERR|}"
        fi
    done

    if (( successes > 0 )); then
        printf '%s|%s|%s|-\n' "$host" "$successes" "$(median_latency "${latencies[@]}")"
    else
        printf '%s|0|0|%s\n' "$host" "$last_reason"
    fi
}

scan_reality_candidates() {
    local results_file="$1"
    shift
    local host jobs_dir index=0 active=0 job_file
    local -A seen=()
    : > "$results_file"
    jobs_dir="${results_file}.jobs"
    mkdir -p "$jobs_dir"
    if REALITY_OPENSSL_GROUP_OPTION="$(reality_openssl_group_args)"; then
        export REALITY_OPENSSL_GROUP_OPTION
    fi

    for host in "$@"; do
        host="$(normalize_reality_host "$host")"
        if ! is_valid_reality_host "$host" || [[ -n "${seen[$host]:-}" ]]; then
            continue
        fi
        seen[$host]=1
        info "检测 Reality 目标: $host (共 $REALITY_SCAN_ATTEMPTS 次)" >&2
        index=$((index + 1))
        job_file="$jobs_dir/$index"
        scan_reality_candidate "$host" > "$job_file" &
        active=$((active + 1))
        if (( active >= REALITY_SCAN_CONCURRENCY )); then
            wait
            active=0
        fi
    done
    wait
    for job_file in "$jobs_dir"/*; do
        [[ -f "$job_file" ]] && cat "$job_file" >> "$results_file"
    done
    rm -f "$jobs_dir"/*
    rmdir "$jobs_dir" 2>/dev/null || true

    sort -t'|' -k2,2nr -k3,3n "$results_file" -o "$results_file"
}

extract_realitlscanner_candidates() {
    local csv_file="$1"
    awk -F',' -v limit="$REALITY_SCAN_MAX_IMPORT" '
        function clean(v) {
            gsub(/^\xef\xbb\xbf/, "", v)
            gsub(/^"|"$/, "", v)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            return tolower(v)
        }
        NR == 1 {
            for (i=1; i<=NF; i++) {
                h=clean($i)
                if (h == "origin") origin=i
                if (h == "cert_domain") cert=i
            }
            next
        }
        {
            if (origin) print clean($origin)
            if (cert) print clean($cert)
        }
    ' "$csv_file" | sed '/^\*\./d; /^$/d' | awk '!seen[$0]++' | head -n "$REALITY_SCAN_MAX_IMPORT"
}

show_and_pick_reality_result() {
    local results_file="$1"
    local host successes latency reason choice
    local -a selectable=()

    echo ""
    printf '%-4s %-30s %-8s %-8s %s\n' "序号" "Reality 目标" "成功率" "延迟" "状态/原因"
    while IFS='|' read -r host successes latency reason; do
        [[ -n "$host" ]] || continue
        if (( successes >= 2 )); then
            selectable+=("$host")
            printf '%-4s %-30s %s/%s    %-7s %s\n' "${#selectable[@]}" "$host" "$successes" "$REALITY_SCAN_ATTEMPTS" "${latency}ms" "可用"
        else
            printf '%-4s %-30s %s/%s    %-7s %s\n' "-" "$host" "$successes" "$REALITY_SCAN_ATTEMPTS" "${latency:-0}ms" "${reason:-淘汰}"
        fi
    done < "$results_file"

    if (( ${#selectable[@]} == 0 )); then
        warn "没有候选目标通过至少 2/$REALITY_SCAN_ATTEMPTS 次严格检测"
        REALITY_SNI="$(prompt_manual_reality_sni)" || return 1
        return 0
    fi

    echo ""
    echo "m) 手动输入其他 SNI"
    read -r -p "请选择目标 [默认 1]: " choice
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[Mm]$ ]]; then
        REALITY_SNI="$(prompt_manual_reality_sni)" || return 1
        return 0
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#selectable[@]} )); then
        err "选择无效"
        return 1
    fi
    REALITY_SNI="${selectable[$((choice - 1))]}"
    return 0
}

prompt_manual_reality_sni() {
    local manual
    while true; do
        read -r -p "请输入 Reality 的 SNI: " manual || return 1
        manual="$(normalize_reality_host "$manual")"
        if is_valid_reality_host "$manual"; then
            printf '%s\n' "$manual"
            return 0
        fi
        warn "域名格式无效，请重新输入" >&2
    done
}

run_installed_realitlscanner() {
    local scanner="" target output_file="$1"
    if command -v RealiTLScanner >/dev/null 2>&1; then
        scanner="$(command -v RealiTLScanner)"
    elif command -v realitlscanner >/dev/null 2>&1; then
        scanner="$(command -v realitlscanner)"
    fi
    if [[ -z "$scanner" ]]; then
        warn "未找到 RealiTLScanner，可先在本地运行后使用 CSV 导入"
        return 1
    fi

    read -r -p "请输入要交给 RealiTLScanner 的 IP、CIDR 或域名: " target
    [[ -n "$target" ]] || return 1
    warn "上游建议不要在云服务器进行大范围扫描，以免触发服务商风控"
    read -r -p "确认从当前 VPS 扫描该目标？(y/N): " confirm_scan
    [[ "$confirm_scan" =~ ^[Yy]$ ]] || return 1

    "$scanner" -addr "$target" -thread 4 -timeout 5 -out "$output_file"
    [[ -s "$output_file" ]]
}

create_reality_scan_workspace() {
    local workspace=""

    # `mktemp` implementations differ on whether a suffix after XXXXXX is
    # accepted. Prefer the implementation's default directory template, then
    # fall back to a template whose XXXXXX sequence is at the very end.
    if workspace="$(TMPDIR=/tmp mktemp -d 2>/dev/null)" && [[ -d "$workspace" ]]; then
        printf '%s\n' "$workspace"
        return 0
    fi
    if workspace="$(mktemp -d /tmp/singbox-reality.XXXXXX 2>/dev/null)" && [[ -d "$workspace" ]]; then
        printf '%s\n' "$workspace"
        return 0
    fi
    return 1
}

cleanup_reality_scan_workspace() {
    local workspace="${1:-}"
    [[ -n "$workspace" && -d "$workspace" ]] || return 0
    rm -f "$workspace/results.tsv" "$workspace/scanner.csv"
    rmdir "$workspace" 2>/dev/null || true
}

select_reality_sni() {
    local choice manual csv_file scanner_csv results_file workspace
    local -a candidates=()
    if ! workspace="$(create_reality_scan_workspace)"; then
        warn "无法创建 Reality 扫描临时目录，请手动输入"
        REALITY_SNI="$(prompt_manual_reality_sni)"
        return
    fi
    results_file="$workspace/results.tsv"
    scanner_csv="$workspace/scanner.csv"

    echo ""
    info "=== Reality 目标站优选 ==="
    echo "1) 快速优选常用目标（推荐）"
    echo "2) 导入 RealiTLScanner CSV 后严格复检"
    echo "3) 调用已安装的 RealiTLScanner，再严格复检"
    echo "4) 严格验证手动输入的域名"
    echo "5) 直接手动输入，不检测"
    read -r -p "请选择 [默认 1]: " choice

    case "${choice:-1}" in
        1)
            candidates=("${REALITY_SCAN_CANDIDATES[@]}")
            ;;
        2)
            read -r -p "请输入 RealiTLScanner CSV 文件路径: " csv_file
            if [[ ! -r "$csv_file" ]]; then
                warn "CSV 文件不可读，改用快速优选"
                candidates=("${REALITY_SCAN_CANDIDATES[@]}")
            else
                mapfile -t candidates < <(extract_realitlscanner_candidates "$csv_file")
            fi
            ;;
        3)
            if run_installed_realitlscanner "$scanner_csv"; then
                mapfile -t candidates < <(extract_realitlscanner_candidates "$scanner_csv")
            else
                candidates=("${REALITY_SCAN_CANDIDATES[@]}")
            fi
            ;;
        4)
            read -r -p "请输入要验证的 Reality 域名: " manual
            candidates=("$manual")
            ;;
        5)
            REALITY_SNI="$(prompt_manual_reality_sni)" || {
                cleanup_reality_scan_workspace "$workspace"
                return 1
            }
            cleanup_reality_scan_workspace "$workspace"
            return 0
            ;;
        *)
            warn "选择无效，改用快速优选"
            candidates=("${REALITY_SCAN_CANDIDATES[@]}")
            ;;
    esac

    if (( ${#candidates[@]} == 0 )); then
        warn "没有读取到候选域名，改用快速优选"
        candidates=("${REALITY_SCAN_CANDIDATES[@]}")
    fi
    scan_reality_candidates "$results_file" "${candidates[@]}"
    if ! show_and_pick_reality_result "$results_file"; then
        cleanup_reality_scan_workspace "$workspace"
        return 1
    fi
    cleanup_reality_scan_workspace "$workspace"
}

# -----------------------
# 在获取公网 IP 之前，询问连接ip和sni配置
echo ""
echo "请输入节点连接 IP 或 DDNS域名(留空默认出口IP):"
read -r CUSTOM_IP
CUSTOM_IP="$(echo "$CUSTOM_IP" | tr -d '[:space:]')"

# 如果用户选择了 Reality 协议，询问 server_name(SNI)
REALITY_SNI=""
if $ENABLE_REALITY || $ENABLE_ANYTLS; then
    select_reality_sni
    info "已选择 Reality SNI: $REALITY_SNI"
else
    REALITY_SNI=""
fi

# 将用户选择写入缓存
mkdir -p /etc/sing-box
# preserve existing cache if any (append/overwrite relevant keys)
# 最简单直接：在后面 create_config 也会写入 .config_cache，先写初始值以便中间步骤可读取
echo "CUSTOM_IP=$CUSTOM_IP" > /etc/sing-box/.config_cache.tmp || true
echo "REALITY_SNI=$REALITY_SNI" >> /etc/sing-box/.config_cache.tmp || true
# 保留其他可能已有的缓存条目（若存在老的 .config_cache），把新临时与旧文件合并（保新值覆盖旧值）
if [ -f /etc/sing-box/.config_cache ]; then
    # 将旧文件中不在新文件内的行追加
    awk 'FNR==NR{a[$1]=1;next} {split($0,k,"="); if(!(k[1] in a)) print $0}' /etc/sing-box/.config_cache.tmp /etc/sing-box/.config_cache >> /etc/sing-box/.config_cache.tmp2 || true
    mv /etc/sing-box/.config_cache.tmp2 /etc/sing-box/.config_cache.tmp || true
fi
mv /etc/sing-box/.config_cache.tmp /etc/sing-box/.config_cache || true

# -----------------------
# 生成随机端口
rand_port() {
    shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000))
}

# 生成随机密码
rand_pass() {
    openssl rand -base64 16 | tr -d '\n\r' || head -c 16 /dev/urandom | base64 | tr -d '\n\r'
}

# 生成UUID
rand_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# -----------------------
# 配置端口和密码
get_config() {
    info "开始配置端口和密码..."
    
    if $ENABLE_SS; then
        info "=== 配置 Shadowsocks (SS) ==="
        if [ -n "${SINGBOX_PORT_SS:-}" ]; then
            PORT_SS="$SINGBOX_PORT_SS"
        else
            read -p "请输入 SS 端口(留空则随机 10000-60000): " USER_PORT_SS
            PORT_SS="${USER_PORT_SS:-$(rand_port)}"
        fi
        PSK_SS=$(rand_pass)
        info "SS 端口: $PORT_SS"
        info "SS 加密方式: $SS_METHOD"
        info "SS 密码已自动生成"
    fi

    if $ENABLE_HY2; then
        info "=== 配置 Hysteria2 (HY2) ==="
        if [ -n "${SINGBOX_PORT_HY2:-}" ]; then
            PORT_HY2="$SINGBOX_PORT_HY2"
        else
            read -p "请输入 HY2 端口(留空则随机 10000-60000): " USER_PORT_HY2
            PORT_HY2="${USER_PORT_HY2:-$(rand_port)}"
        fi
        PSK_HY2=$(rand_pass)
        info "HY2 端口: $PORT_HY2"
        info "HY2 密码已自动生成"
    fi

    if $ENABLE_TUIC; then
        info "=== 配置 TUIC ==="
        if [ -n "${SINGBOX_PORT_TUIC:-}" ]; then
            PORT_TUIC="$SINGBOX_PORT_TUIC"
        else
            read -p "请输入 TUIC 端口(留空则随机 10000-60000): " USER_PORT_TUIC
            PORT_TUIC="${USER_PORT_TUIC:-$(rand_port)}"
        fi
        PSK_TUIC=$(rand_pass)
        UUID_TUIC=$(rand_uuid)
        info "TUIC 端口: $PORT_TUIC"
        info "TUIC UUID 和密码已自动生成"
    fi

    if $ENABLE_REALITY; then
        info "=== 配置 VLESS Reality ==="
        if [ -n "${SINGBOX_PORT_REALITY:-}" ]; then
            PORT_REALITY="$SINGBOX_PORT_REALITY"
        else
            read -p "请输入 VLESS Reality 端口(留空则随机 10000-60000): " USER_PORT_REALITY
            PORT_REALITY="${USER_PORT_REALITY:-$(rand_port)}"
        fi
        UUID=$(rand_uuid)
        info "VLESS Reality 端口: $PORT_REALITY"
        info "VLESS Reality UUID 已自动生成"
    fi
    
    if $ENABLE_ANYTLS; then
    info "=== 配置 AnyTLS Reality ==="
    if [ -n "${SINGBOX_PORT_ANYTLS:-}" ]; then
        PORT_ANYTLS="$SINGBOX_PORT_ANYTLS"
    else
        read -p "请输入 AnyTLS Reality 端口(留空则随机 10000-60000): " USER_PORT_ANYTLS
        PORT_ANYTLS="${USER_PORT_ANYTLS:-$(rand_port)}"
    fi

    ANYTLS_USER=$(openssl rand -hex 4)
    ANYTLS_PSK=$(openssl rand -base64 16)

    info "AnyTLS Reality 端口: $PORT_ANYTLS"
    info "AnyTLS Reality 用户名: $ANYTLS_USER"
    info "AnyTLS Reality 密码已自动生成"
    fi

    info "配置完成，继续安装..."
}

get_config

# -----------------------
# 安装 sing-box
install_singbox() {
    info "开始安装 sing-box..."

    if command -v sing-box >/dev/null 2>&1; then
        CURRENT_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
        warn "检测到已安装 sing-box: $CURRENT_VERSION"
        read -p "是否重新安装?(y/N): " REINSTALL
        if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
            info "跳过 sing-box 安装"
            return 0
        fi
    fi

    case "$OS" in
        alpine)
            info "使用 Edge 仓库安装 sing-box"
            apk update || { err "apk update 失败"; exit 1; }
            apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box || {
                err "sing-box 安装失败"
                exit 1
            }
            ;;
        debian|redhat)
            bash <(curl -fsSL https://sing-box.app/install.sh) || {
                err "sing-box 安装失败"
                exit 1
            }
            ;;
        *)
            err "未支持的系统,无法安装 sing-box"
            exit 1
            ;;
    esac

    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 安装后未找到可执行文件"
        exit 1
    fi

    INSTALLED_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
    info "sing-box 安装成功: $INSTALLED_VERSION"
}

install_singbox

# -----------------------
# 生成 Reality 密钥对（必须在 sing-box 安装之后）
generate_reality_keys() {
    if ! $ENABLE_REALITY && ! $ENABLE_ANYTLS; then
        info "跳过 Reality 密钥生成（未选择 Reality 协议）"
        return 0
    fi
    
    info "生成 Reality 密钥对..."
    
    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 未安装，无法生成 Reality 密钥"
        exit 1
    fi
    
    REALITY_KEYS=$(sing-box generate reality-keypair 2>&1) || {
        err "生成 Reality 密钥失败"
        exit 1
    }
    
    REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_SID=$(sing-box generate rand 8 --hex 2>&1) || {
        err "生成 Reality ShortID 失败"
        exit 1
    }
    
    if [ -z "$REALITY_PK" ] || [ -z "$REALITY_PUB" ] || [ -z "$REALITY_SID" ]; then
        err "Reality 密钥生成结果为空"
        exit 1
    fi
    
    mkdir -p /etc/sing-box
    echo -n "$REALITY_PUB" > /etc/sing-box/.reality_pub
    echo -n "$REALITY_SID" > /etc/sing-box/.reality_sid
    
    info "Reality 密钥已生成"
}

generate_reality_keys

# -----------------------
# 生成 HY2/TUIC 自签证书(仅在需要时)
generate_cert() {
    if ! $ENABLE_HY2 && ! $ENABLE_TUIC; then
        info "跳过证书生成(未选择 HY2 或 TUIC)"
        return 0
    fi
    
    info "生成 HY2/TUIC 自签证书..."
    mkdir -p /etc/sing-box/certs
    
    if [ ! -f /etc/sing-box/certs/fullchain.pem ] || [ ! -f /etc/sing-box/certs/privkey.pem ]; then
        openssl req -x509 -newkey rsa:2048 -nodes \
          -keyout /etc/sing-box/certs/privkey.pem \
          -out /etc/sing-box/certs/fullchain.pem \
          -days 3650 \
          -subj "/CN=www.bing.com" || {
            err "证书生成失败"
            exit 1
        }
        info "证书已生成"
    else
        info "证书已存在"
    fi
}

generate_cert

# -----------------------
# 生成配置文件
CONFIG_PATH="/etc/sing-box/config.json"

create_config() {
    info "生成配置文件: $CONFIG_PATH"

    mkdir -p "$(dirname "$CONFIG_PATH")"

    # 构建 inbounds 内容（使用临时文件避免字符串处理问题）
    local TEMP_INBOUNDS="/tmp/singbox_inbounds_$.json"
    > "$TEMP_INBOUNDS"
    
    local need_comma=false
    
    if $ENABLE_SS; then
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_SS'
    {
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": PORT_SS_PLACEHOLDER,
      "method": "METHOD_SS_PLACEHOLDER",
      "password": "PSK_SS_PLACEHOLDER",
      "tag": "ss-in"
    }
INBOUND_SS
        sed -i "s|PORT_SS_PLACEHOLDER|$PORT_SS|g" "$TEMP_INBOUNDS"
        sed -i "s|METHOD_SS_PLACEHOLDER|$SS_METHOD|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_SS_PLACEHOLDER|$PSK_SS|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi
    
    if $ENABLE_HY2; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_HY2'
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": PORT_HY2_PLACEHOLDER,
      "users": [
        {
          "password": "PSK_HY2_PLACEHOLDER"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/privkey.pem"
      }
    }
INBOUND_HY2
        sed -i "s|PORT_HY2_PLACEHOLDER|$PORT_HY2|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_HY2_PLACEHOLDER|$PSK_HY2|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi
    
    if $ENABLE_TUIC; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_TUIC'
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": PORT_TUIC_PLACEHOLDER,
      "users": [
        {
          "uuid": "UUID_TUIC_PLACEHOLDER",
          "password": "PSK_TUIC_PLACEHOLDER"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/privkey.pem"
      }
    }
INBOUND_TUIC
        sed -i "s|PORT_TUIC_PLACEHOLDER|$PORT_TUIC|g" "$TEMP_INBOUNDS"
        sed -i "s|UUID_TUIC_PLACEHOLDER|$UUID_TUIC|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_TUIC_PLACEHOLDER|$PSK_TUIC|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi
    
    if $ENABLE_REALITY; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_REALITY'
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": PORT_REALITY_PLACEHOLDER,
      "users": [
        {
          "name": "default",
          "uuid": "UUID_REALITY_PLACEHOLDER",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "REALITY_SNI_PLACEHOLDER",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "REALITY_SNI_PLACEHOLDER",
            "server_port": 443
          },
          "private_key": "REALITY_PK_PLACEHOLDER",
          "short_id": ["REALITY_SID_PLACEHOLDER"]
        }
      }
    }
INBOUND_REALITY
        sed -i "s|PORT_REALITY_PLACEHOLDER|$PORT_REALITY|g" "$TEMP_INBOUNDS"
        sed -i "s|UUID_REALITY_PLACEHOLDER|$UUID|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_PK_PLACEHOLDER|$REALITY_PK|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_SID_PLACEHOLDER|$REALITY_SID|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_SNI_PLACEHOLDER|$REALITY_SNI|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi

    if $ENABLE_ANYTLS; then
    $need_comma && echo "," >> "$TEMP_INBOUNDS"
    cat >> "$TEMP_INBOUNDS" <<'INBOUND_ANYTLS'
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": PORT_ANYTLS_PLACEHOLDER,
      "users": [
        {
          "name": "ANYTLS_USER_PLACEHOLDER",
          "password": "ANYTLS_PSK_PLACEHOLDER"
        }
      ],
      "padding_scheme": [],
      "tls": {
        "enabled": true,
        "server_name": "REALITY_SNI_PLACEHOLDER",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "REALITY_SNI_PLACEHOLDER",
            "server_port": 443
          },
          "private_key": "REALITY_PK_PLACEHOLDER",
          "short_id": [
            "REALITY_SID_PLACEHOLDER"
          ]
        }
      }
    }
INBOUND_ANYTLS

    sed -i "s|PORT_ANYTLS_PLACEHOLDER|$PORT_ANYTLS|g" "$TEMP_INBOUNDS"
    sed -i "s|ANYTLS_USER_PLACEHOLDER|$ANYTLS_USER|g" "$TEMP_INBOUNDS"
    sed -i "s|ANYTLS_PSK_PLACEHOLDER|$ANYTLS_PSK|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_PK_PLACEHOLDER|$REALITY_PK|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_SID_PLACEHOLDER|$REALITY_SID|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_SNI_PLACEHOLDER|$REALITY_SNI|g" "$TEMP_INBOUNDS"

    need_comma=true
    fi

    # 生成最终配置
    cat > "$CONFIG_PATH" <<'CONFIG_HEAD'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "30m"
  },
  "inbounds": [
CONFIG_HEAD
    
    cat "$TEMP_INBOUNDS" >> "$CONFIG_PATH"
    
    cat >> "$CONFIG_PATH" <<'CONFIG_TAIL'
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out"
    }
  ]
}
CONFIG_TAIL

    rm -f "$TEMP_INBOUNDS"

    sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1 \
       && info "配置文件验证通过" \
       || warn "配置文件验证失败,但继续执行"

    # 保存配置缓存（追加/覆盖）
    cat > /etc/sing-box/.config_cache <<CACHEEOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
ENABLE_ANYTLS=$ENABLE_ANYTLS
CACHEEOF

    $ENABLE_SS && cat >> /etc/sing-box/.config_cache <<CACHEEOF
SS_PORT=$PORT_SS
SS_PSK=$PSK_SS
SS_METHOD=$SS_METHOD
CACHEEOF

    $ENABLE_HY2 && cat >> /etc/sing-box/.config_cache <<CACHEEOF
HY2_PORT=$PORT_HY2
HY2_PSK=$PSK_HY2
CACHEEOF

    $ENABLE_TUIC && cat >> /etc/sing-box/.config_cache <<CACHEEOF
TUIC_PORT=$PORT_TUIC
TUIC_UUID=$UUID_TUIC
TUIC_PSK=$PSK_TUIC
CACHEEOF

    $ENABLE_REALITY && cat >> /etc/sing-box/.config_cache <<CACHEEOF
REALITY_PORT=$PORT_REALITY
REALITY_UUID=$UUID
REALITY_PK=$REALITY_PK
REALITY_SID=$REALITY_SID
REALITY_PUB=$REALITY_PUB
REALITY_SNI=$REALITY_SNI
CACHEEOF

    $ENABLE_ANYTLS && cat >> /etc/sing-box/.config_cache <<CACHEEOF
ANYTLS_PORT=$PORT_ANYTLS
ANYTLS_USER=$ANYTLS_USER
ANYTLS_PSK=$ANYTLS_PSK
CACHEEOF

    # 全局写入 CUSTOM_IP（哪怕为空也写）
    echo "CUSTOM_IP=$CUSTOM_IP" >> /etc/sing-box/.config_cache

    info "配置缓存已保存到 /etc/sing-box/.config_cache"
}

# 调用配置生成
create_config

info "配置生成完成，准备设置服务..."

# -----------------------
# 设置服务
setup_service() {
    info "配置系统服务..."
    
    if [ "$OS" = "alpine" ]; then
        SERVICE_PATH="/etc/init.d/sing-box"
        
        cat > "$SERVICE_PATH" <<'OPENRC'
#!/sbin/openrc-run

name="sing-box"
description="Sing-box Proxy Server"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
pidfile="/run/${RC_SVCNAME}.pid"
command_background="yes"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"
# 自动拉起（程序崩溃、OOM、被 kill 后自动恢复）
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    checkpath --directory --mode 0755 /run
}
OPENRC
        
        chmod +x "$SERVICE_PATH"
        rc-update add sing-box default >/dev/null 2>&1 || warn "添加开机自启失败"
        rc-service sing-box restart || {
            err "服务启动失败"
            tail -20 /var/log/sing-box.err 2>/dev/null || tail -20 /var/log/sing-box.log 2>/dev/null || true
            exit 1
        }
        
        sleep 2
        if rc-service sing-box status >/dev/null 2>&1; then
            info "✅ OpenRC 服务已启动"
        else
            err "服务状态异常"
            exit 1
        fi
        
    else
        SERVICE_PATH="/etc/systemd/system/sing-box.service"
        
        cat > "$SERVICE_PATH" <<'SYSTEMD'
[Unit]
Description=Sing-box Proxy Server
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/sing-box
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SYSTEMD
        
        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box || {
            err "服务启动失败"
            journalctl -u sing-box -n 30 --no-pager
            exit 1
        }
        
        sleep 2
        if systemctl is-active sing-box >/dev/null 2>&1; then
            info "✅ Systemd 服务已启动"
        else
            err "服务状态异常"
            exit 1
        fi
    fi
    
    info "服务配置完成: $SERVICE_PATH"
}

setup_service

# -----------------------
# 获取公网 IP
get_public_ip() {
    local ip=""
    for url in \
        "https://api.ipify.org" \
        "https://ipinfo.io/ip" \
        "https://ifconfig.me" \
        "https://icanhazip.com" \
        "https://ipecho.net/plain"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# 如果用户提供了 CUSTOM_IP，则优先使用；否则自动检测出口 IP
if [ -n "${CUSTOM_IP:-}" ]; then
    PUB_IP="$CUSTOM_IP"
    info "使用用户提供的连接IP或ddns域名 : $PUB_IP"
else
    PUB_IP=$(get_public_ip || echo "YOUR_SERVER_IP")
    if [ "$PUB_IP" = "YOUR_SERVER_IP" ]; then
        warn "无法获取公网 IP,请手动替换"
    else
        info "检测到公网 IP: $PUB_IP"
    fi
fi

# -----------------------
# 生成链接(仅生成已选择的协议)
generate_uris() {
    local host="$PUB_IP"
    
    if $ENABLE_SS; then
        local ss_userinfo="${SS_METHOD}:${PSK_SS}"
        ss_encoded=$(printf "%s" "$ss_userinfo" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        ss_b64=$(printf "%s" "$ss_userinfo" | base64 -w0 2>/dev/null || printf "%s" "$ss_userinfo" | base64 | tr -d '\n')

        echo "=== Shadowsocks (SS) ==="
        echo "ss://${ss_encoded}@${host}:${PORT_SS}#ss${suffix}"
        echo "ss://${ss_b64}@${host}:${PORT_SS}#ss${suffix}"
        echo ""
    fi
    
    if $ENABLE_HY2; then
        hy2_encoded=$(printf "%s" "$PSK_HY2" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        echo "=== Hysteria2 (HY2) ==="
        echo "hy2://${hy2_encoded}@${host}:${PORT_HY2}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${suffix}"
        echo ""
    fi

    if $ENABLE_TUIC; then
        tuic_encoded=$(printf "%s" "$PSK_TUIC" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        echo "=== TUIC ==="
        echo "tuic://${UUID_TUIC}:${tuic_encoded}@${host}:${PORT_TUIC}/?congestion_control=bbr&alpn=h3&sni=www.bing.com&insecure=1#tuic${suffix}"
        echo ""
    fi
    
    if $ENABLE_REALITY; then
        echo "=== VLESS Reality ==="
        echo "vless://${UUID}@${host}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${suffix}"
        echo ""
    fi

    if $ENABLE_ANYTLS; then
        anytls_user_encoded=$(printf "%s" "$ANYTLS_USER" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        anytls_pass_encoded=$(printf "%s" "$ANYTLS_PSK" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        echo "=== AnyTLS Reality ==="
        echo "anytls://${anytls_pass_encoded}@${host}:${PORT_ANYTLS}/?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#anytls${suffix}"
        echo ""
    fi
}

# -----------------------
# 最终输出
echo ""
echo "=========================================="
info "🎉 Sing-box 部署完成!"
echo "=========================================="
echo ""
info "📋 配置信息:"
$ENABLE_SS && echo "   SS 端口: $PORT_SS | 密码: $PSK_SS | 加密: $SS_METHOD"
$ENABLE_HY2 && echo "   HY2 端口: $PORT_HY2 | 密码: $PSK_HY2"
$ENABLE_TUIC && echo "   TUIC 端口: $PORT_TUIC | UUID: $UUID_TUIC | 密码: $PSK_TUIC"
$ENABLE_REALITY && echo "   Reality 端口: $PORT_REALITY | UUID: $UUID"
$ENABLE_ANYTLS && echo "   AnyTLS 端口: $PORT_ANYTLS | 用户: $ANYTLS_USER | 密码: $ANYTLS_PSK"
echo "   服务器: $PUB_IP"
echo "   Reality server_name(SNI): ${REALITY_SNI:-未配置}"
echo ""
info "📂 文件位置:"
echo "   配置: $CONFIG_PATH"
($ENABLE_HY2 || $ENABLE_TUIC) && echo "   证书: /etc/sing-box/certs/"
echo "   服务: $SERVICE_PATH"
echo ""
info "📜 客户端链接:"
generate_uris | while IFS= read -r line; do
    echo "   $line"
done
echo ""
info "🔧 管理命令:"
if [ "$OS" = "alpine" ]; then
    echo "   启动: rc-service sing-box start"
    echo "   停止: rc-service sing-box stop"
    echo "   重启: rc-service sing-box restart"
    echo "   状态: rc-service sing-box status"
    echo "   日志: tail -f /var/log/sing-box.log"
else
    echo "   启动: systemctl start sing-box"
    echo "   停止: systemctl stop sing-box"
    echo "   重启: systemctl restart sing-box"
    echo "   状态: systemctl status sing-box"
    echo "   日志: journalctl -u sing-box -f"
fi
echo ""
echo "=========================================="

# -----------------------
# 创建 sb 管理脚本
SB_PATH="/usr/local/bin/sb"
REALITY_HELPER_PATH="/usr/local/lib/sing-box/reality-sni-tools.sh"
info "正在创建 sb 管理面板: $SB_PATH"

mkdir -p "$(dirname "$REALITY_HELPER_PATH")"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'REALITY_SCAN_CANDIDATES=("www.cloudflare.com" "www.microsoft.com" "www.amazon.com" "aws.amazon.com" "www.samsung.com" "www.nvidia.com" "www.amd.com" "www.intel.com" "www.sony.com" "dl.google.com")'
    printf '%s\n' 'REALITY_SCAN_ATTEMPTS=3' 'REALITY_SCAN_TIMEOUT=10' 'REALITY_SCAN_MAX_IMPORT=50' 'REALITY_SCAN_CONCURRENCY=5'
    declare -f normalize_reality_host is_valid_reality_host now_millis reality_openssl_group_args reality_tls_probe_once median_latency
    declare -f scan_reality_candidate scan_reality_candidates extract_realitlscanner_candidates
    declare -f prompt_manual_reality_sni show_and_pick_reality_result run_installed_realitlscanner
    declare -f create_reality_scan_workspace cleanup_reality_scan_workspace select_reality_sni
} > "$REALITY_HELPER_PATH"
chmod 755 "$REALITY_HELPER_PATH"

cat > "$SB_PATH" <<'SB_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

CONFIG_PATH="/etc/sing-box/config.json"
CACHE_FILE="/etc/sing-box/.config_cache"
PROTOCOL_FILE="/etc/sing-box/.protocols"
REALITY_PUBLIC_FILE="/etc/sing-box/.reality_pub"
REALITY_SID_FILE="/etc/sing-box/.reality_sid"
URI_FILE="/etc/sing-box/uris.txt"
REALITY_HELPER_PATH="/usr/local/lib/sing-box/reality-sni-tools.sh"
SERVICE_NAME="sing-box"

# 检测系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        ID="${ID:-}"
        ID_LIKE="${ID_LIKE:-}"
    else
        ID=""
        ID_LIKE=""
    fi

    if echo "$ID $ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$ID $ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$ID $ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

detect_os

# 服务控制
service_start() {
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" start || systemctl start "$SERVICE_NAME"
}
service_stop() {
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" stop || systemctl stop "$SERVICE_NAME"
}
service_restart() {
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" restart || systemctl restart "$SERVICE_NAME"
}
service_status() {
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" status || systemctl status "$SERVICE_NAME" --no-pager
}

# 生成随机值
rand_port() { shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000)); }
rand_pass() { openssl rand -base64 16 | tr -d '\n\r' || head -c 16 /dev/urandom | base64 | tr -d '\n\r'; }
rand_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/'; }

# URL 编码
url_encode() {
    printf "%s" "$1" | sed -e 's/%/%25/g' -e 's/:/%3A/g' -e 's/+/%2B/g' -e 's/\//%2F/g' -e 's/=/%3D/g'
}

# 读取配置
read_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        err "未找到配置文件: $CONFIG_PATH"
        return 1
    fi
    
    # 优先加载 .protocols 文件（确认协议标记）
    if [ -f "$PROTOCOL_FILE" ]; then
        . "$PROTOCOL_FILE"
    fi
    
    # 加载缓存文件（包含端口密码等详细配置）
    if [ -f "$CACHE_FILE" ]; then
        . "$CACHE_FILE"
    fi
    
    # 配置文件是 SNI 的唯一真实来源，避免缓存与实际入站不一致。
    local configured_reality_sni
    configured_reality_sni=$(jq -r '
        .inbounds[]?
        | select(.tls.reality.enabled == true)
        | .tls.server_name // .tls.reality.handshake.server // empty
    ' "$CONFIG_PATH" | head -n1)
    REALITY_SNI="${configured_reality_sni:-${REALITY_SNI:-}}"
    REALITY_PUB="${REALITY_PUB:-}"
    REALITY_SID="${REALITY_SID:-}"
    ENABLE_ANYTLS="${ENABLE_ANYTLS:-false}"
    CUSTOM_IP="${CUSTOM_IP:-}"

    # 读取各协议配置
    if [ "${ENABLE_SS:-false}" = "true" ]; then
        SS_PORT=$(jq -r '.inbounds[] | select(.type=="shadowsocks") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        SS_PSK=$(jq -r '.inbounds[] | select(.type=="shadowsocks") | .password // empty' "$CONFIG_PATH" | head -n1)
        SS_METHOD=$(jq -r '.inbounds[] | select(.type=="shadowsocks") | .method // empty' "$CONFIG_PATH" | head -n1)
    fi
    
    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        HY2_PORT=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        HY2_PSK=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .users[0].password // empty' "$CONFIG_PATH" | head -n1)
    fi
    
    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        TUIC_PORT=$(jq -r '.inbounds[] | select(.type=="tuic") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        TUIC_UUID=$(jq -r '.inbounds[] | select(.type=="tuic") | .users[0].uuid // empty' "$CONFIG_PATH" | head -n1)
        TUIC_PSK=$(jq -r '.inbounds[] | select(.type=="tuic") | .users[0].password // empty' "$CONFIG_PATH" | head -n1)
    fi
    
# Reality 公共参数（Reality / AnyTLS 共用）
if [ "${ENABLE_REALITY:-false}" = "true" ] || [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
    REALITY_SID=$(jq -r '
        .inbounds[]
        | select(.tls.reality.enabled == true)
        | .tls.reality.short_id[0] // empty
    ' "$CONFIG_PATH" | head -n1)

    [ -f "$REALITY_PUBLIC_FILE" ] && REALITY_PUB=$(cat "$REALITY_PUBLIC_FILE")
fi

# VLESS Reality 专属参数
    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        REALITY_PORT=$(jq -r '.inbounds[] | select(.type=="vless" and .tls.reality.enabled==true) | .listen_port // empty' "$CONFIG_PATH" | head -n1)

        REALITY_PK=$(jq -r '.inbounds[] | select(.type=="vless" and .tls.reality.enabled==true) | .tls.reality.private_key // empty' "$CONFIG_PATH" | head -n1)
fi

if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
    ANYTLS_PORT=$(jq -r '.inbounds[] | select(.type=="anytls" and .tls.reality.enabled==true) | .listen_port // empty' "$CONFIG_PATH" | head -n1)
    ANYTLS_USER=$(jq -r '.inbounds[] | select(.type=="anytls" and .tls.reality.enabled==true) | .users[0].name // empty' "$CONFIG_PATH" | head -n1)
    ANYTLS_PSK=$(jq -r '.inbounds[] | select(.type=="anytls" and .tls.reality.enabled==true) | .users[0].password // empty' "$CONFIG_PATH" | head -n1)
fi
}

# 获取公网IP（原始方法）
get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ipinfo.io/ip" "https://ifconfig.me"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        [ -n "$ip" ] && echo "$ip" && return 0
    done
    echo "YOUR_SERVER_IP"
}

# 生成并保存URI
generate_uris() {
    read_config || return 1

    # 优先使用用户自定义入口 IP
    if [ -n "${CUSTOM_IP:-}" ]; then
        PUBLIC_IP="$CUSTOM_IP"
    else
        PUBLIC_IP=$(get_public_ip)
    fi

    node_suffix=$(cat /root/node_names.txt 2>/dev/null || echo "")
    
    > "$URI_FILE"
    
    if [ "${ENABLE_SS:-false}" = "true" ]; then
        ss_userinfo="${SS_METHOD}:${SS_PSK}"
        ss_encoded=$(url_encode "$ss_userinfo")
        ss_b64=$(printf "%s" "$ss_userinfo" | base64 -w0 2>/dev/null || printf "%s" "$ss_userinfo" | base64 | tr -d '\n')
        
        echo "=== Shadowsocks (SS) ===" >> "$URI_FILE"
        echo "ss://${ss_encoded}@${PUBLIC_IP}:${SS_PORT}#ss${node_suffix}" >> "$URI_FILE"
        echo "ss://${ss_b64}@${PUBLIC_IP}:${SS_PORT}#ss${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        hy2_encoded=$(url_encode "$HY2_PSK")
        echo "=== Hysteria2 (HY2) ===" >> "$URI_FILE"
        echo "hy2://${hy2_encoded}@${PUBLIC_IP}:${HY2_PORT}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        tuic_encoded=$(url_encode "$TUIC_PSK")
        echo "=== TUIC ===" >> "$URI_FILE"
        echo "tuic://${TUIC_UUID}:${tuic_encoded}@${PUBLIC_IP}:${TUIC_PORT}/?congestion_control=bbr&alpn=h3&sni=www.bing.com&insecure=1#tuic${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        if [ -z "${REALITY_SNI:-}" ]; then
            err "Reality 配置缺少 SNI，无法生成客户端链接"
            return 1
        fi
        echo "=== VLESS Reality ===" >> "$URI_FILE"
        while IFS=$'\t' read -r client_name client_uuid; do
            [ -n "$client_uuid" ] || continue
            client_name="${client_name:-reality}"
            client_label=$(url_encode "${client_name}${node_suffix}")
            echo "vless://${client_uuid}@${PUBLIC_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#${client_label}" >> "$URI_FILE"
        done < <(jq -r '.inbounds[] | select(.type=="vless" and .tls.reality.enabled==true) | .users[] | [(.name // "reality"), .uuid] | @tsv' "$CONFIG_PATH")
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        anytls_user_encoded=$(url_encode "$ANYTLS_USER")
        anytls_pass_encoded=$(url_encode "$ANYTLS_PSK")
        echo "=== AnyTLS Reality ===" >> "$URI_FILE"
        echo "anytls://${anytls_pass_encoded}@${PUBLIC_IP}:${ANYTLS_PORT}/?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#anytls${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi

    info "URI 已保存到: $URI_FILE"
}

# 查看URI
action_view_uri() {
    info "正在生成并显示 URI..."
    generate_uris || { err "生成 URI 失败"; return 1; }
    echo ""
    cat /etc/sing-box/uris.txt
}

# 查看配置文件路径
action_view_config() {
    echo "$CONFIG_PATH"
}

# 编辑配置
action_edit_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        err "配置文件不存在: $CONFIG_PATH"
        return 1
    fi
    
    ${EDITOR:-nano} "$CONFIG_PATH" 2>/dev/null || ${EDITOR:-vi} "$CONFIG_PATH"
    
    if command -v sing-box >/dev/null 2>&1; then
        if sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
            info "配置校验通过,已重启服务"
            service_restart || warn "重启失败"
            generate_uris || true
        else
            warn "配置校验失败,服务未重启"
        fi
    fi
}

set_config_kv() {
    local file="$1" key="$2" value="$3"
    touch "$file"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        awk -F= -v key="$key" -v value="$value" '
          $1 == key { print key "=" value; next }
          { print }
        ' "$file" > "${file}.kv.tmp"
        mv "${file}.kv.tmp" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

protocol_inbound_exists() {
    local type="$1"
    jq -e --arg type "$type" '.inbounds[]? | select(.type == $type)' "$CONFIG_PATH" >/dev/null
}

reality_vless_inbound_exists() {
    jq -e '.inbounds[]? | select(.type == "vless" and .tls.reality.enabled == true)' "$CONFIG_PATH" >/dev/null
}

reality_anytls_inbound_exists() {
    jq -e '.inbounds[]? | select(.type == "anytls" and .tls.reality.enabled == true)' "$CONFIG_PATH" >/dev/null
}

port_is_available() {
    local port="$1" port_hex
    if jq -e --argjson port "$port" '.inbounds[]? | select(.listen_port == $port)' "$CONFIG_PATH" >/dev/null; then
        return 1
    fi
    if command -v ss >/dev/null 2>&1; then
        if ss -H -lntu 2>/dev/null | awk -v suffix=":${port}" '$5 ~ (suffix "$") { found=1 } END { exit !found }'; then
            return 1
        fi
    else
        # Minimal containers may not ship iproute2/ss. Linux exposes bound
        # sockets in /proc; TCP LISTEN is state 0A and UDP bound is state 07.
        port_hex=$(printf '%04X' "$port")
        if awk -v suffix=":${port_hex}" '
          $2 ~ (suffix "$") && ($4 == "0A" || $4 == "07") { found=1 }
          END { exit !found }
        ' /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6 2>/dev/null; then
            return 1
        fi
    fi
    return 0
}

prompt_new_node_port() {
    local label="$1" requested port attempts=0
    read -r -p "请输入 ${label} 端口（留空自动选择）: " requested
    if [[ -n "$requested" ]]; then
        if ! [[ "$requested" =~ ^[0-9]+$ ]] || (( requested < 1 || requested > 65535 )); then
            err "端口必须是 1-65535 的数字"
            return 1
        fi
        if ! port_is_available "$requested"; then
            err "端口 $requested 已被配置或占用"
            return 1
        fi
        printf '%s\n' "$requested"
        return 0
    fi

    while (( attempts < 100 )); do
        port="$(rand_port)"
        if port_is_available "$port"; then
            printf '%s\n' "$port"
            return 0
        fi
        attempts=$((attempts + 1))
    done
    err "无法找到可用随机端口"
    return 1
}

ensure_shared_tls_certificate() {
    local cert_dir="/etc/sing-box/certs"
    if [[ -s "$cert_dir/fullchain.pem" && -s "$cert_dir/privkey.pem" ]]; then
        return 0
    fi
    info "生成 HY2/TUIC 共用自签证书..."
    mkdir -p "$cert_dir"
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$cert_dir/privkey.pem" \
        -out "$cert_dir/fullchain.pem" \
        -days 3650 \
        -subj "/CN=www.bing.com" >/dev/null 2>&1 || {
        err "证书生成失败"
        return 1
    }
    chmod 600 "$cert_dir/privkey.pem"
    chmod 644 "$cert_dir/fullchain.pem"
}

valid_reality_sni_value() {
    local value="${1:-}"
    [[
        -n "$value"
        && ${#value} -le 253
        && "$value" != \*.*
        && "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$
        && "$value" == *.*
    ]]
}

normalize_new_reality_sni() {
    NEW_REALITY_SNI=$(printf '%s' "${NEW_REALITY_SNI:-}" | tr '[:upper:]' '[:lower:]')
    if ! valid_reality_sni_value "$NEW_REALITY_SNI"; then
        err "Reality SNI 格式无效"
        return 1
    fi
}

load_or_create_reality_material() {
    NEW_REALITY_PRIVATE=$(jq -r '.inbounds[]? | select(.tls.reality.enabled == true) | .tls.reality.private_key // empty' "$CONFIG_PATH" | head -n1)
    NEW_REALITY_SID=$(jq -r '.inbounds[]? | select(.tls.reality.enabled == true) | .tls.reality.short_id[0] // empty' "$CONFIG_PATH" | head -n1)
    NEW_REALITY_SNI=$(jq -r '.inbounds[]? | select(.tls.reality.enabled == true) | .tls.server_name // empty' "$CONFIG_PATH" | head -n1)
    NEW_REALITY_PUBLIC=$(cat "$REALITY_PUBLIC_FILE" 2>/dev/null || true)

    if [[ -n "$NEW_REALITY_PRIVATE" ]]; then
        if [[ -z "$NEW_REALITY_PUBLIC" || -z "$NEW_REALITY_SID" ]]; then
            err "已有 Reality 入站，但公共密钥或 Short ID 文件缺失，无法安全复用"
            return 1
        fi
        NEW_REALITY_SNI="${NEW_REALITY_SNI:-${REALITY_SNI:-}}"
        if [[ -z "$NEW_REALITY_SNI" ]]; then
            err "已有 Reality 入站缺少 SNI"
            return 1
        fi
        normalize_new_reality_sni || return 1
        return 0
    fi

    local keys
    keys=$(sing-box generate reality-keypair 2>&1) || {
        err "Reality 密钥生成失败"
        return 1
    }
    NEW_REALITY_PRIVATE=$(printf '%s\n' "$keys" | awk '/PrivateKey/ {print $NF; exit}' | tr -d '\r')
    NEW_REALITY_PUBLIC=$(printf '%s\n' "$keys" | awk '/PublicKey/ {print $NF; exit}' | tr -d '\r')
    NEW_REALITY_SID=$(sing-box generate rand 8 --hex 2>/dev/null) || return 1
    if [[ -z "$NEW_REALITY_PRIVATE" || -z "$NEW_REALITY_PUBLIC" || -z "$NEW_REALITY_SID" ]]; then
        err "Reality 密钥生成结果为空"
        return 1
    fi

    if [[ -r "$REALITY_HELPER_PATH" ]]; then
        # shellcheck source=/usr/local/lib/sing-box/reality-sni-tools.sh
        . "$REALITY_HELPER_PATH"
        select_reality_sni
        NEW_REALITY_SNI="$REALITY_SNI"
    else
        while true; do
            read -r -p "请输入 Reality SNI: " NEW_REALITY_SNI || return 1
            normalize_new_reality_sni && break
        done
    fi
    normalize_new_reality_sni
}

append_new_node_config() {
    local protocol="$1" port="$2" secret="$3" extra1="${4:-}" extra2="${5:-}" extra3="${6:-}"
    case "$protocol" in
        ss)
            jq --argjson port "$port" --arg password "$secret" --arg method "$extra1" '
              .inbounds += [{
                "type": "shadowsocks", "tag": "ss-in", "listen": "::",
                "listen_port": $port, "method": $method, "password": $password
              }]
            ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp"
            ;;
        hy2)
            jq --argjson port "$port" --arg password "$secret" '
              .inbounds += [{
                "type": "hysteria2", "tag": "hy2-in", "listen": "::",
                "listen_port": $port, "users": [{"password": $password}],
                "tls": {
                  "enabled": true, "alpn": ["h3"],
                  "certificate_path": "/etc/sing-box/certs/fullchain.pem",
                  "key_path": "/etc/sing-box/certs/privkey.pem"
                }
              }]
            ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp"
            ;;
        tuic)
            jq --argjson port "$port" --arg password "$secret" --arg uuid "$extra1" '
              .inbounds += [{
                "type": "tuic", "tag": "tuic-in", "listen": "::",
                "listen_port": $port,
                "users": [{"uuid": $uuid, "password": $password}],
                "congestion_control": "bbr",
                "tls": {
                  "enabled": true, "alpn": ["h3"],
                  "certificate_path": "/etc/sing-box/certs/fullchain.pem",
                  "key_path": "/etc/sing-box/certs/privkey.pem"
                }
              }]
            ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp"
            ;;
        vless)
            jq --argjson port "$port" --arg uuid "$secret" --arg private "$extra1" --arg sid "$extra2" --arg sni "$extra3" '
              .inbounds += [{
                "type": "vless", "tag": "vless-in", "listen": "::",
                "listen_port": $port,
                "users": [{"name": "default", "uuid": $uuid, "flow": "xtls-rprx-vision"}],
                "tls": {
                  "enabled": true, "server_name": $sni,
                  "reality": {
                    "enabled": true,
                    "handshake": {"server": $sni, "server_port": 443},
                    "private_key": $private, "short_id": [$sid]
                  }
                }
              }]
            ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp"
            ;;
        anytls)
            jq --argjson port "$port" --arg password "$secret" --arg user "$extra1" --arg private "$extra2" --argjson reality "$extra3" '
              .inbounds += [{
                "type": "anytls", "tag": "anytls-in", "listen": "::",
                "listen_port": $port,
                "users": [{"name": $user, "password": $password}],
                "padding_scheme": [],
                "tls": {
                  "enabled": true, "server_name": $reality.sni,
                  "reality": {
                    "enabled": true,
                    "handshake": {"server": $reality.sni, "server_port": 443},
                    "private_key": $private, "short_id": [$reality.sid]
                  }
                }
              }]
            ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp"
            ;;
        *)
            return 1
            ;;
    esac
}

commit_new_node() {
    local enable_key="$1"
    local reality_public="${2:-}" reality_sid="${3:-}" reality_sni="${4:-}"
    local protocol_file="$PROTOCOL_FILE"
    local public_file="$REALITY_PUBLIC_FILE"
    local sid_file="$REALITY_SID_FILE"
    local had_cache=false had_protocols=false had_public=false had_sid=false
    if ! sing-box check -c "${CONFIG_PATH}.tmp" >/dev/null 2>&1; then
        rm -f "${CONFIG_PATH}.tmp"
        err "新增节点配置校验失败，原配置未修改"
        return 1
    fi

    [[ -f "$CACHE_FILE" ]] && had_cache=true
    [[ -f "$protocol_file" ]] && had_protocols=true
    [[ -f "$public_file" ]] && had_public=true
    [[ -f "$sid_file" ]] && had_sid=true

    # Build every auxiliary file off to the side before replacing live state.
    if [[ -f "$CACHE_FILE" ]]; then
        cp "$CACHE_FILE" "${CACHE_FILE}.node.tmp"
    else
        : > "${CACHE_FILE}.node.tmp"
    fi
    if [[ -f "$protocol_file" ]]; then
        cp "$protocol_file" "${protocol_file}.node.tmp"
    else
        : > "${protocol_file}.node.tmp"
    fi
    set_config_kv "${CACHE_FILE}.node.tmp" "$enable_key" "true"
    set_config_kv "${protocol_file}.node.tmp" "$enable_key" "true"
    if [[ -n "$reality_public" ]]; then
        printf '%s' "$reality_public" > "${public_file}.node.tmp"
        printf '%s' "$reality_sid" > "${sid_file}.node.tmp"
        set_config_kv "${CACHE_FILE}.node.tmp" REALITY_SNI "$reality_sni"
    fi

    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    rm -f "${CACHE_FILE}.bak" "${protocol_file}.bak" "${public_file}.bak" "${sid_file}.bak"
    $had_cache && cp "$CACHE_FILE" "${CACHE_FILE}.bak"
    $had_protocols && cp "$protocol_file" "${protocol_file}.bak"
    $had_public && cp "$public_file" "${public_file}.bak"
    $had_sid && cp "$sid_file" "${sid_file}.bak"

    mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    mv "${CACHE_FILE}.node.tmp" "$CACHE_FILE"
    mv "${protocol_file}.node.tmp" "$protocol_file"
    if [[ -n "$reality_public" ]]; then
        mv "${public_file}.node.tmp" "$public_file"
        mv "${sid_file}.node.tmp" "$sid_file"
    fi

    if ! service_restart; then
        cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"
        if $had_cache; then
            cp "${CACHE_FILE}.bak" "$CACHE_FILE"
        else
            rm -f "$CACHE_FILE"
        fi
        if $had_protocols; then
            cp "${protocol_file}.bak" "$protocol_file"
        else
            rm -f "$protocol_file"
        fi
        if $had_public; then
            cp "${public_file}.bak" "$public_file"
        else
            rm -f "$public_file"
        fi
        if $had_sid; then
            cp "${sid_file}.bak" "$sid_file"
        else
            rm -f "$sid_file"
        fi
        service_restart || true
        err "服务启动失败，已恢复新增前配置"
        return 1
    fi
    generate_uris || warn "节点已创建，但链接重新生成失败"
}

add_ss_node() {
    protocol_inbound_exists "shadowsocks" && { warn "Shadowsocks 节点已存在"; return 0; }
    local port password method_choice method
    port="$(prompt_new_node_port "SS")" || return 1
    echo "1) 2022-blake3-aes-128-gcm（推荐）"
    echo "2) aes-128-gcm"
    read -r -p "请选择加密方式 [默认 1]: " method_choice
    [[ "${method_choice:-1}" == "2" ]] && method="aes-128-gcm" || method="2022-blake3-aes-128-gcm"
    password="$(rand_pass)"
    append_new_node_config ss "$port" "$password" "$method"
    if commit_new_node ENABLE_SS; then
        info "Shadowsocks 节点创建成功，端口: $port"
        cat /etc/sing-box/uris.txt
    fi
}

add_hy2_node() {
    protocol_inbound_exists "hysteria2" && { warn "Hysteria2 节点已存在"; return 0; }
    local port password
    port="$(prompt_new_node_port "HY2")" || return 1
    ensure_shared_tls_certificate || return 1
    password="$(rand_pass)"
    append_new_node_config hy2 "$port" "$password"
    if commit_new_node ENABLE_HY2; then
        info "Hysteria2 节点创建成功，端口: $port"
        cat /etc/sing-box/uris.txt
    fi
}

add_tuic_node() {
    protocol_inbound_exists "tuic" && { warn "TUIC 节点已存在"; return 0; }
    local port password uuid
    port="$(prompt_new_node_port "TUIC")" || return 1
    ensure_shared_tls_certificate || return 1
    password="$(rand_pass)"
    uuid="$(rand_uuid)"
    append_new_node_config tuic "$port" "$password" "$uuid"
    if commit_new_node ENABLE_TUIC; then
        info "TUIC 节点创建成功，端口: $port"
        cat /etc/sing-box/uris.txt
    fi
}

add_vless_reality_node() {
    reality_vless_inbound_exists && { warn "VLESS Reality 节点已存在，请使用客户端管理新增 UUID"; return 0; }
    local port uuid
    port="$(prompt_new_node_port "VLESS Reality")" || return 1
    load_or_create_reality_material || return 1
    uuid="$(rand_uuid)"
    append_new_node_config vless "$port" "$uuid" "$NEW_REALITY_PRIVATE" "$NEW_REALITY_SID" "$NEW_REALITY_SNI"
    if commit_new_node ENABLE_REALITY "$NEW_REALITY_PUBLIC" "$NEW_REALITY_SID" "$NEW_REALITY_SNI"; then
        info "VLESS Reality 节点创建成功，端口: $port"
        cat /etc/sing-box/uris.txt
    fi
}

add_anytls_reality_node() {
    reality_anytls_inbound_exists && { warn "AnyTLS Reality 节点已存在"; return 0; }
    local port password user reality_json
    port="$(prompt_new_node_port "AnyTLS Reality")" || return 1
    load_or_create_reality_material || return 1
    password="$(rand_pass)"
    user="$(openssl rand -hex 4)"
    reality_json=$(jq -nc --arg sid "$NEW_REALITY_SID" --arg sni "$NEW_REALITY_SNI" '{sid:$sid,sni:$sni}')
    append_new_node_config anytls "$port" "$password" "$user" "$NEW_REALITY_PRIVATE" "$reality_json"
    if commit_new_node ENABLE_ANYTLS "$NEW_REALITY_PUBLIC" "$NEW_REALITY_SID" "$NEW_REALITY_SNI"; then
        info "AnyTLS Reality 节点创建成功，端口: $port"
        cat /etc/sing-box/uris.txt
    fi
}

action_add_node() {
    read_config || return 1
    echo ""
    echo "=== 新建节点 ==="
    echo "1) Shadowsocks (SS)"
    echo "2) Hysteria2 (HY2)"
    echo "3) TUIC"
    echo "4) VLESS Reality"
    echo "5) AnyTLS Reality"
    echo "0) 返回"
    read -r -p "请选择: " node_choice
    case "$node_choice" in
        1) add_ss_node ;;
        2) add_hy2_node ;;
        3) add_tuic_node ;;
        4) add_vless_reality_node ;;
        5) add_anytls_reality_node ;;
        0) return 0 ;;
        *) warn "无效选项" ;;
    esac
}

# 重置SS端口
action_reset_ss() {
    read_config || return 1
    
    if [ "${ENABLE_SS:-false}" != "true" ]; then
        err "SS 协议未启用"
        return 1
    fi
    
    read -p "输入新的 SS 端口(回车保持 $SS_PORT): " new_port
    new_port="${new_port:-$SS_PORT}"
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="shadowsocks" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 SS 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置HY2端口
action_reset_hy2() {
    read_config || return 1
    
    if [ "${ENABLE_HY2:-false}" != "true" ]; then
        err "HY2 协议未启用"
        return 1
    fi
    
    read -p "输入新的 HY2 端口(回车保持 $HY2_PORT): " new_port
    new_port="${new_port:-$HY2_PORT}"
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="hysteria2" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 HY2 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置TUIC端口
action_reset_tuic() {
    read_config || return 1
    
    if [ "${ENABLE_TUIC:-false}" != "true" ]; then
        err "TUIC 协议未启用"
        return 1
    fi
    
    read -p "输入新的 TUIC 端口(回车保持 $TUIC_PORT): " new_port
    new_port="${new_port:-$TUIC_PORT}"
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="tuic" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 TUIC 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置Vless Reality端口
action_reset_reality() {
    read_config || return 1
    
    if [ "${ENABLE_REALITY:-false}" != "true" ]; then
        err "Vless Reality 协议未启用"
        return 1
    fi
    
    read -p "输入新的 Vless Reality 端口(回车保持 $REALITY_PORT): " new_port
    new_port="${new_port:-$REALITY_PORT}"
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="vless" and .tls.reality.enabled==true then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 Vless Reality 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

reality_clients_enabled() {
    read_config || return 1
    if [ "${ENABLE_REALITY:-false}" != "true" ]; then
        err "VLESS Reality 协议未启用"
        return 1
    fi
}

list_reality_clients() {
    reality_clients_enabled || return 1
    echo ""
    printf '%-5s %-24s %s\n' "序号" "名称" "UUID"
    jq -r '
      .inbounds[] | select(.type=="vless" and .tls.reality.enabled==true)
      | .users | to_entries[]
      | [(.key + 1), (.value.name // ("reality-" + ((.key + 1) | tostring))), .value.uuid]
      | @tsv
    ' "$CONFIG_PATH" | while IFS=$'\t' read -r number name uuid; do
        printf '%-5s %-24s %s\n' "$number" "$name" "$uuid"
    done
}

commit_reality_clients_config() {
    local first_uuid
    if ! sing-box check -c "${CONFIG_PATH}.tmp" >/dev/null 2>&1; then
        rm -f "${CONFIG_PATH}.tmp"
        err "客户端配置校验失败，未修改当前配置"
        return 1
    fi
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    first_uuid=$(jq -r '.inbounds[] | select(.type=="vless" and .tls.reality.enabled==true) | .users[0].uuid' "$CONFIG_PATH" | head -n1)
    if grep -q '^REALITY_UUID=' "$CACHE_FILE" 2>/dev/null; then
        sed -i "s|^REALITY_UUID=.*|REALITY_UUID=$first_uuid|" "$CACHE_FILE"
    else
        printf 'REALITY_UUID=%s\n' "$first_uuid" >> "$CACHE_FILE"
    fi
    service_restart
    generate_uris || warn "客户端链接重新生成失败"
}

valid_client_name() {
    [[ "${1:-}" =~ ^[A-Za-z0-9._-]{1,32}$ ]]
}

valid_uuid() {
    [[ "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

add_reality_client() {
    reality_clients_enabled || return 1
    local name uuid
    read -r -p "客户端名称（字母、数字、点、下划线或横线）: " name
    if ! valid_client_name "$name"; then
        err "名称格式无效，长度需为 1-32"
        return 1
    fi
    if jq -e --arg name "$name" '.inbounds[] | select(.type=="vless" and .tls.reality.enabled==true) | .users[] | select((.name // "") == $name)' "$CONFIG_PATH" >/dev/null; then
        err "客户端名称已存在: $name"
        return 1
    fi
    read -r -p "UUID（留空自动随机生成）: " uuid
    uuid="${uuid:-$(rand_uuid)}"
    if ! valid_uuid "$uuid"; then
        err "UUID 格式无效"
        return 1
    fi
    if jq -e --arg uuid "$uuid" '.inbounds[] | select(.type=="vless" and .tls.reality.enabled==true) | .users[] | select(.uuid == $uuid)' "$CONFIG_PATH" >/dev/null; then
        err "UUID 已存在"
        return 1
    fi

    jq --arg name "$name" --arg uuid "$uuid" '
      .inbounds |= map(
        if .type=="vless" and .tls.reality.enabled==true then
          .users += [{"name": $name, "uuid": $uuid, "flow": "xtls-rprx-vision"}]
        else . end
      )
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp"
    commit_reality_clients_config && info "已新增客户端: $name"
}

batch_add_reality_clients() {
    reality_clients_enabled || return 1
    local count prefix i name uuid existing
    read -r -p "生成数量（1-20）: " count
    if ! [[ "$count" =~ ^[0-9]+$ ]] || (( count < 1 || count > 20 )); then
        err "数量必须在 1-20 之间"
        return 1
    fi
    read -r -p "名称前缀 [默认 device]: " prefix
    prefix="${prefix:-device}"
    if ! valid_client_name "$prefix"; then
        err "名称前缀格式无效"
        return 1
    fi

    cp "$CONFIG_PATH" "${CONFIG_PATH}.tmp"
    for ((i=1; i<=count; i++)); do
        name=$(printf '%s-%02d' "$prefix" "$i")
        existing=$(jq -r --arg name "$name" '[.inbounds[] | select(.type=="vless" and .tls.reality.enabled==true) | .users[] | select((.name // "") == $name)] | length' "${CONFIG_PATH}.tmp")
        if (( existing > 0 )); then
            warn "跳过已存在的名称: $name"
            continue
        fi
        uuid="$(rand_uuid)"
        jq --arg name "$name" --arg uuid "$uuid" '
          .inbounds |= map(
            if .type=="vless" and .tls.reality.enabled==true then
              .users += [{"name": $name, "uuid": $uuid, "flow": "xtls-rprx-vision"}]
            else . end
          )
        ' "${CONFIG_PATH}.tmp" > "${CONFIG_PATH}.next"
        mv "${CONFIG_PATH}.next" "${CONFIG_PATH}.tmp"
    done
    commit_reality_clients_config && info "批量客户端生成完成"
}

delete_reality_client() {
    reality_clients_enabled || return 1
    local count number index name
    count=$(jq -r '[.inbounds[] | select(.type=="vless" and .tls.reality.enabled==true) | .users[]] | length' "$CONFIG_PATH")
    if (( count <= 1 )); then
        err "至少需要保留一个 Reality 客户端"
        return 1
    fi
    list_reality_clients
    read -r -p "请输入要删除的序号: " number
    if ! [[ "$number" =~ ^[0-9]+$ ]] || (( number < 1 || number > count )); then
        err "序号无效"
        return 1
    fi
    index=$((number - 1))
    name=$(jq -r --argjson index "$index" '.inbounds[] | select(.type=="vless" and .tls.reality.enabled==true) | .users[$index].name // ("reality-" + (($index + 1) | tostring))' "$CONFIG_PATH")
    read -r -p "确认删除客户端 $name？(y/N): " confirm_delete
    [[ "$confirm_delete" =~ ^[Yy]$ ]] || return 0

    jq --argjson index "$index" '
      .inbounds |= map(
        if .type=="vless" and .tls.reality.enabled==true then del(.users[$index]) else . end
      )
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp"
    commit_reality_clients_config && info "已删除客户端: $name"
}

reset_reality_client_uuid() {
    reality_clients_enabled || return 1
    local count number index name uuid
    count=$(jq -r '[.inbounds[] | select(.type=="vless" and .tls.reality.enabled==true) | .users[]] | length' "$CONFIG_PATH")
    list_reality_clients
    read -r -p "请输入要重置 UUID 的序号: " number
    if ! [[ "$number" =~ ^[0-9]+$ ]] || (( number < 1 || number > count )); then
        err "序号无效"
        return 1
    fi
    index=$((number - 1))
    name=$(jq -r --argjson index "$index" '.inbounds[] | select(.type=="vless" and .tls.reality.enabled==true) | .users[$index].name // "reality"' "$CONFIG_PATH")
    uuid="$(rand_uuid)"
    jq --argjson index "$index" --arg uuid "$uuid" '
      .inbounds |= map(
        if .type=="vless" and .tls.reality.enabled==true then .users[$index].uuid = $uuid else . end
      )
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp"
    commit_reality_clients_config && info "已重置 $name 的 UUID"
}

action_reality_client_manager() {
    reality_clients_enabled || return 1
    echo ""
    echo "=== Reality 客户端管理 ==="
    echo "1) 查看全部客户端"
    echo "2) 新增客户端"
    echo "3) 批量生成客户端"
    echo "4) 删除客户端"
    echo "5) 重置客户端 UUID"
    echo "6) 重新生成分享链接"
    echo "0) 返回"
    read -r -p "请选择: " client_action
    case "$client_action" in
        1) list_reality_clients ;;
        2) add_reality_client ;;
        3) batch_add_reality_clients ;;
        4) delete_reality_client ;;
        5) reset_reality_client_uuid ;;
        6) generate_uris && cat /etc/sing-box/uris.txt ;;
        0) return 0 ;;
        *) warn "无效选项" ;;
    esac
}

# 重置AnyTLS Reality端口
action_reset_anytls() {
    read_config || return 1

    if [ "${ENABLE_ANYTLS:-false}" != "true" ]; then
        err "AnyTLS Reality 协议未启用"
        return 1
    fi

    read -p "输入新的 AnyTLS Reality 端口(回车保持 $ANYTLS_PORT): " new_port
    new_port="${new_port:-$ANYTLS_PORT}"

    info "正在停止服务..."
    service_stop || warn "停止服务失败"

    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"

    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="anytls" and .tls.reality.enabled==true then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    info "已启动服务并更新 AnyTLS Reality 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重新优选并应用 Reality SNI
action_change_reality_sni() {
    read_config || return 1
    if [ "${ENABLE_REALITY:-false}" != "true" ] && [ "${ENABLE_ANYTLS:-false}" != "true" ]; then
        err "未启用 Reality 协议"
        return 1
    fi
    if [ ! -r "$REALITY_HELPER_PATH" ]; then
        err "未找到 Reality 优选组件: $REALITY_HELPER_PATH"
        return 1
    fi

    local old_sni="$REALITY_SNI"
    # shellcheck source=/usr/local/lib/sing-box/reality-sni-tools.sh
    . "$REALITY_HELPER_PATH"
    select_reality_sni
    local new_sni="$REALITY_SNI"
    if [ "$new_sni" = "$old_sni" ]; then
        info "Reality SNI 未变化: $new_sni"
        return 0
    fi

    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    cp "$CACHE_FILE" "${CACHE_FILE}.bak" 2>/dev/null || true
    jq --arg sni "$new_sni" '
      .inbounds |= map(
        if .tls.reality.enabled == true then
          .tls.server_name = $sni
          | .tls.reality.handshake.server = $sni
        else . end
      )
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp"

    if ! sing-box check -c "${CONFIG_PATH}.tmp" >/dev/null 2>&1; then
        rm -f "${CONFIG_PATH}.tmp"
        err "新配置校验失败，已保留原 SNI: $old_sni"
        return 1
    fi
    mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    set_config_kv "$CACHE_FILE" REALITY_SNI "$new_sni"

    local saved_snis
    saved_snis=$(jq -r '
      [.inbounds[]? | select(.tls.reality.enabled == true)] as $all
      | [$all[] | select(.tls.server_name == $sni and .tls.reality.handshake.server == $sni)] as $matching
      | select(($all | length) > 0 and ($all | length) == ($matching | length))
      | $matching | length
    ' --arg sni "$new_sni" "$CONFIG_PATH")
    if [[ -z "$saved_snis" || "$saved_snis" -lt 1 ]]; then
        cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"
        [ -f "${CACHE_FILE}.bak" ] && cp "${CACHE_FILE}.bak" "$CACHE_FILE"
        err "SNI 未成功写入 Reality 配置，已恢复原配置"
        return 1
    fi

    if ! service_restart; then
        cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"
        [ -f "${CACHE_FILE}.bak" ] && cp "${CACHE_FILE}.bak" "$CACHE_FILE"
        service_restart || true
        err "服务重启失败，已恢复原 SNI: $old_sni"
        return 1
    fi
    generate_uris || warn "客户端链接重新生成失败"
    info "Reality SNI 已从 $old_sni 更新为 $new_sni"
}

show_bbr_status() {
    local current_cc current_qdisc available module_state
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "不可读取")
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "不可读取")
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "不可读取")
    if lsmod 2>/dev/null | awk '{print $1}' | grep -qx tcp_bbr; then
        module_state="已加载"
    elif [ -d /sys/module/tcp_bbr ]; then
        module_state="已加载"
    else
        module_state="未加载或已编入内核"
    fi

    echo ""
    echo "=== BBR 状态 ==="
    echo "内核版本: $(uname -r)"
    echo "当前拥塞控制: $current_cc"
    echo "默认队列规则: $current_qdisc"
    echo "可用拥塞控制: $available"
    echo "tcp_bbr 模块: $module_state"
    if [ "$current_cc" = "bbr" ]; then
        info "BBR 已启用"
    elif [[ " $available " == *" bbr "* ]]; then
        warn "内核支持 BBR，但当前未启用"
    else
        warn "当前内核未提供 BBR，或 VPS 容器未开放该能力"
    fi
}

enable_bbr() {
    local available current_cc current_qdisc old_cc old_qdisc bbr_config
    bbr_config="/etc/sysctl.d/99-singbox-bbr.conf"
    old_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    old_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)

    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if [[ " $available " != *" bbr "* ]]; then
        if command -v modprobe >/dev/null 2>&1; then
            info "尝试加载 tcp_bbr 内核模块..."
            modprobe tcp_bbr 2>/dev/null || true
        fi
        available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    fi

    if [[ " $available " != *" bbr "* ]]; then
        err "当前内核或虚拟化环境不支持 BBR，未修改系统配置"
        return 1
    fi

    cat > "$bbr_config" <<'BBR_CONFIG'
# Managed by the sing-box sb panel.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
BBR_CONFIG

    if ! sysctl -p "$bbr_config" >/dev/null; then
        rm -f "$bbr_config"
        [ -n "$old_qdisc" ] && sysctl -w "net.core.default_qdisc=$old_qdisc" >/dev/null 2>&1 || true
        [ -n "$old_cc" ] && sysctl -w "net.ipv4.tcp_congestion_control=$old_cc" >/dev/null 2>&1 || true
        err "内核拒绝应用 BBR 参数；可能是容器权限受限"
        return 1
    fi

    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
    if [ "$current_cc" != "bbr" ] || [ "$current_qdisc" != "fq" ]; then
        rm -f "$bbr_config"
        [ -n "$old_qdisc" ] && sysctl -w "net.core.default_qdisc=$old_qdisc" >/dev/null 2>&1 || true
        [ -n "$old_cc" ] && sysctl -w "net.ipv4.tcp_congestion_control=$old_cc" >/dev/null 2>&1 || true
        err "参数已写入，但当前拥塞控制仍为 ${current_cc:-未知}"
        return 1
    fi
    info "BBR 已启用并持久化到 $bbr_config"
    show_bbr_status
}

action_bbr_manager() {
    echo ""
    echo "=== BBR 管理 ==="
    echo "1) 查看 BBR 状态"
    echo "2) 启用 BBR"
    echo "0) 返回"
    read -r -p "请选择: " bbr_action
    case "$bbr_action" in
        1) show_bbr_status ;;
        2)
            warn "BBR 仅影响 TCP；Hysteria2/TUIC 等 UDP 协议不会直接受益"
            read -r -p "确认启用并持久化 BBR？(y/N): " confirm_bbr
            [[ "$confirm_bbr" =~ ^[Yy]$ ]] && enable_bbr
            ;;
        0) return 0 ;;
        *) warn "无效选项" ;;
    esac
}

# 更新sing-box
action_update() {
    info "开始更新 sing-box..."
    if [ "$OS" = "alpine" ]; then
        apk update && apk upgrade sing-box || bash <(curl -fsSL https://sing-box.app/install.sh)
    else
        bash <(curl -fsSL https://sing-box.app/install.sh)
    fi
    
    info "更新完成,已重启服务..."
    if command -v sing-box >/dev/null 2>&1; then
        NEW_VER=$(sing-box version 2>/dev/null | head -n1)
        info "当前版本: $NEW_VER"
        service_restart || warn "重启失败"
    fi
}

# 卸载
action_uninstall() {
    read -p "确认卸载 sing-box?(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && info "已取消" && return 0
    
    info "正在卸载..."
    service_stop || true
    if [ "$OS" = "alpine" ]; then
        rc-update del sing-box default 2>/dev/null || true
        rm -f /etc/init.d/sing-box
        apk del sing-box 2>/dev/null || true
    else
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload 2>/dev/null || true
        apt purge -y sing-box >/dev/null 2>&1 || true
    fi
    rm -rf /etc/sing-box /var/log/sing-box* /usr/local/bin/sb /usr/bin/sb \
        /usr/local/lib/sing-box/reality-sni-tools.sh /usr/bin/sing-box /root/node_names.txt 2>/dev/null || true
    info "卸载完成"
}

# 生成线路机脚本
action_generate_relay() {
    read_config || return 1
    
    # 检查是否启用了SS
    if [ "${ENABLE_SS:-false}" != "true" ]; then
        warn "未检测到 SS 协议,需要先部署 SS 作为入站"
        read -p "是否现在部署 SS 协议?(y/N): " deploy_ss
        if [[ "$deploy_ss" =~ ^[Yy]$ ]]; then
            info "开始部署 SS 协议..."
            
            # 让用户选择端口
            read -p "请输入 SS 端口(留空则随机 10000-60000): " USER_SS_PORT
            SS_PORT="${USER_SS_PORT:-$(rand_port)}"
            SS_PSK=$(rand_pass)
            SS_METHOD="aes-128-gcm"
            
            info "SS 端口: $SS_PORT | 密码已自动生成"
            
            info "正在停止服务..."
            service_stop || warn "停止服务失败"
            
            cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
            
            # 添加 SS inbound
            jq --argjson port "$SS_PORT" --arg psk "$SS_PSK" '
            .inbounds += [{
              "type": "shadowsocks",
              "listen": "::",
              "listen_port": $port,
              "method": "aes-128-gcm",
              "password": $psk,
              "tag": "ss-in"
            }]
            ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            
            # 更新缓存和协议标记
            sed -i 's/ENABLE_SS=false/ENABLE_SS=true/' "$CACHE_FILE" 2>/dev/null || echo "ENABLE_SS=true" >> "$CACHE_FILE"
            echo "SS_PORT=$SS_PORT" >> "$CACHE_FILE"
            echo "SS_PSK=$SS_PSK" >> "$CACHE_FILE"
            echo "SS_METHOD=$SS_METHOD" >> "$CACHE_FILE"
            
            # 同步更新协议标记文件
            PROTOCOL_FILE="/etc/sing-box/.protocols"
            if [ -f "$PROTOCOL_FILE" ]; then
                sed -i 's/ENABLE_SS=false/ENABLE_SS=true/' "$PROTOCOL_FILE"
            else
                echo "ENABLE_SS=true" >> "$PROTOCOL_FILE"
            fi
            
            # 更新当前会话变量
            ENABLE_SS=true
            
            info "SS 已部署 - 端口: $SS_PORT"
            service_start || warn "启动服务失败"
            sleep 1
            
            # 重新读取配置
            read_config
        else
            err "取消生成线路机脚本"
            return 1
        fi
    fi
    
    # 线路机模板使用 CUSTOM_IP（若设置）或当前公共 IP
    if [ -n "${CUSTOM_IP:-}" ]; then
        INBOUND_IP="${CUSTOM_IP}"
    else
        INBOUND_IP="$(get_public_ip)"
    fi

    PUBLIC_IP="$INBOUND_IP"
    RELAY_SCRIPT="/tmp/relay-install.sh"
    
    info "正在生成线路机脚本: $RELAY_SCRIPT"
    
    cat > "$RELAY_SCRIPT" <<'RELAY_EOF'
#!/usr/bin/env bash
set -euo pipefail

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

[ "$(id -u)" != "0" ] && err "必须以 root 运行" && exit 1

detect_os(){
    . /etc/os-release 2>/dev/null || true
    case "${ID:-}" in
        alpine) OS=alpine ;;
        debian|ubuntu) OS=debian ;;
        centos|rhel|fedora) OS=redhat ;;
        *) OS=unknown ;;
    esac
}
detect_os

info "安装依赖..."
case "$OS" in
    alpine) apk update; apk add --no-cache curl jq bash openssl ca-certificates ;;
    debian) apt-get update -y; apt-get install -y curl jq bash openssl ca-certificates ;;
    redhat) yum install -y curl jq bash openssl ca-certificates ;;
esac

info "安装 sing-box..."
case "$OS" in
    alpine) apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box ;;
    *) bash <(curl -fsSL https://sing-box.app/install.sh) ;;
esac

UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "00000000-0000-0000-0000-000000000000")

info "生成 Reality 密钥对"
REALITY_KEYS=$(sing-box generate reality-keypair 2>/dev/null || echo "")
REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r' || echo "")
REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r' || echo "")
REALITY_SID=$(sing-box generate rand 8 --hex 2>/dev/null || echo "0123456789abcdef")

read -p "请输入线路机监听端口(留空随机 20000-65000): " USER_PORT
LISTEN_PORT="${USER_PORT:-$(shuf -i 20000-65000 -n 1 2>/dev/null || echo 20443)}"

mkdir -p /etc/sing-box

cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $LISTEN_PORT,
      "users": [{ "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "__REALITY_SNI__",
        "reality": {
          "enabled": true,
          "handshake": { "server": "__REALITY_SNI__", "server_port": 443 },
          "private_key": "$REALITY_PK",
          "short_id": ["$REALITY_SID"]
        }
      },
      "tag": "vless-in"
    }
  ],
  "outbounds": [
    {
      "type": "shadowsocks",
      "server": "__INBOUND_IP__",
      "server_port": __INBOUND_PORT__,
      "method": "__INBOUND_METHOD__",
      "password": "__INBOUND_PASSWORD__",
      "tag": "relay-out"
    },
    { "type": "direct", "tag": "direct-out" }
  ],
  "route": { "rules": [{ "inbound": "vless-in", "outbound": "relay-out" }] }
}
EOF

if [ "$OS" = "alpine" ]; then
    cat > /etc/init.d/sing-box <<'SVC'
#!/sbin/openrc-run
name="sing-box"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() { need net; }
SVC
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default
    rc-service sing-box restart
else
    cat > /etc/systemd/system/sing-box.service <<'SYSTEMD'
[Unit]
Description=Sing-box Relay
After=network.target
[Service]
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
[Install]
WantedBy=multi-user.target
SYSTEMD
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box
fi

PUB_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "YOUR_RELAY_IP")

# 生成并保存链接
RELAY_URI="vless://$UUID@$PUB_IP:$LISTEN_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=__REALITY_SNI__&fp=chrome&pbk=$REALITY_PUB&sid=$REALITY_SID#relay"

mkdir -p /etc/sing-box
echo "$RELAY_URI" > /etc/sing-box/relay_uri.txt

echo ""
info "✅ 安装完成"
echo "=============== 中转节点 Reality 链接 ==============="
echo "$RELAY_URI"
echo "===================================================="
echo ""
info "💡 链接已保存到: /etc/sing-box/relay_uri.txt"
info "💡 查看链接命令: cat /etc/sing-box/relay_uri.txt"
RELAY_EOF

    # 替换占位符（INBOUND_IP/PORT/METHOD/PASSWORD 同时替换 REALITY_SNI）
    sed -i "s|__INBOUND_IP__|$INBOUND_IP|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_PORT__|$SS_PORT|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_METHOD__|$SS_METHOD|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_PASSWORD__|$SS_PSK|g" "$RELAY_SCRIPT"
    if [[ -z "${REALITY_SNI:-}" ]]; then
        err "Reality SNI 为空，无法生成线路机脚本"
        return 1
    fi
    sed -i "s|__REALITY_SNI__|$REALITY_SNI|g" "$RELAY_SCRIPT"
    
    chmod +x "$RELAY_SCRIPT"
    
    info "✅ 线路机脚本已生成: $RELAY_SCRIPT"
    echo ""
    info "请复制以下内容到线路机执行:"
    echo "----------------------------------------"
    cat "$RELAY_SCRIPT"
    echo "----------------------------------------"
    echo ""
    info "在线路机执行命令示例："
    echo "   nano /tmp/relay-install.sh 保存后执行"
    echo "   chmod +x /tmp/relay-install.sh && bash /tmp/relay-install.sh"
    echo ""
    info "复制执行完成后，即可在线路机完成 sing-box 中转节点部署。"
}

# 动态生成菜单
show_menu() {
    read_config 2>/dev/null || true
    
    cat <<'MENU'

==========================
 Sing-box 管理面板 (快速指令sb)
==========================
1) 查看协议链接
2) 查看配置文件路径
3) 编辑配置文件
MENU

    # 构建协议重置选项映射
    declare -g -A MENU_MAP
    local option=4

    echo "$option) 新建节点"
    MENU_MAP[$option]="add_node"
    option=$((option + 1))
    
    if [ "${ENABLE_SS:-false}" = "true" ]; then
        echo "$option) 重置 SS 端口"
        MENU_MAP[$option]="reset_ss"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        echo "$option) 重置 HY2 端口"
        MENU_MAP[$option]="reset_hy2"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        echo "$option) 重置 TUIC 端口"
        MENU_MAP[$option]="reset_tuic"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        echo "$option) 重置 Vless Reality 端口"
        MENU_MAP[$option]="reset_reality"
        option=$((option + 1))

        echo "$option) Reality 客户端管理"
        MENU_MAP[$option]="reality_clients"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        echo "$option) 重置 AnyTLS Reality 端口"
        MENU_MAP[$option]="reset_anytls"
        option=$((option + 1))
    fi

    if [ "${ENABLE_REALITY:-false}" = "true" ] || [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        echo "$option) 重新优选 Reality SNI"
        MENU_MAP[$option]="change_reality_sni"
        option=$((option + 1))
    fi

    # 固定功能选项
    MENU_MAP[$option]="start"
    echo "$option) 启动服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="stop"
    echo "$((option))) 停止服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="restart"
    echo "$((option))) 重启服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="status"
    echo "$((option))) 查看状态"
    option=$((option + 1))

    MENU_MAP[$option]="bbr"
    echo "$((option))) BBR 管理"
    option=$((option + 1))
    
    MENU_MAP[$option]="update"
    echo "$((option))) 更新 sing-box"
    option=$((option + 1))
    
    MENU_MAP[$option]="relay"
    echo "$((option))) 生成线路机脚本(出口为本机ss协议)"
    option=$((option + 1))
    
    MENU_MAP[$option]="uninstall"
    echo "$((option))) 卸载 sing-box"
    
    cat <<MENU2
0) 退出
==========================
MENU2
}

# 主循环
while true; do
    show_menu
    read -p "请输入选项: " opt
    
    # 处理退出
    if [ "$opt" = "0" ]; then
        exit 0
    fi
    
    # 处理固定选项
    case "$opt" in
        1) action_view_uri ;;
        2) action_view_config ;;
        3) action_edit_config ;;
        *)
            # 处理动态选项
            action="${MENU_MAP[$opt]:-}"
            case "$action" in
                add_node) action_add_node ;;
                reset_ss) action_reset_ss ;;
                reset_hy2) action_reset_hy2 ;;
                reset_tuic) action_reset_tuic ;;
                reset_reality) action_reset_reality ;;
                reality_clients) action_reality_client_manager ;;
                reset_anytls) action_reset_anytls ;;
                change_reality_sni) action_change_reality_sni ;;
                start) service_start && info "已启动" ;;
                stop) service_stop && info "已停止" ;;
                restart) service_restart && info "已重启" ;;
                status) service_status ;;
                bbr) action_bbr_manager ;;
                update) action_update ;;
                relay) action_generate_relay ;;
                uninstall) action_uninstall; exit 0 ;;
                *) warn "无效选项: $opt" ;;
            esac
            ;;
    esac
    
    echo ""
done
SB_SCRIPT

chmod +x "$SB_PATH"
ln -sf /usr/local/bin/sb /usr/bin/sb
info "✅ 管理面板已创建,可输入 sb 打开管理面板"
