#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT_FILE="${ROOT_DIR}/install-singbox-yyds.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

extract_function() {
    local name="$1"
    sed -n "/^${name}()/,/^}/p" "$SCRIPT_FILE"
}

{
    sed -n '/^REALITY_SCAN_CANDIDATES=(/,/^)/p' "$SCRIPT_FILE"
    sed -n '/^REALITY_SCAN_ATTEMPTS=/,/^REALITY_SCAN_CONCURRENCY=/p' "$SCRIPT_FILE"
    extract_function normalize_reality_host
    extract_function is_valid_reality_host
    extract_function now_millis
    extract_function reality_openssl_group_args
    extract_function reality_tls_probe_once
    extract_function median_latency
    extract_function scan_reality_candidate
    extract_function prompt_manual_reality_sni
} > "${TMP_DIR}/scanner-functions.sh"

# shellcheck disable=SC1090
source "${TMP_DIR}/scanner-functions.sh"

timeout() {
    if [[ "${TEST_OPENSSL_MODE:-}" == "timeout" ]]; then
        return 124
    fi
    shift
    "$@"
}

curl() {
    printf 'FAIL: Reality SNI 探测不应调用 curl\n' >&2
    return 99
}

# 模拟一台 OpenSSL 只支持 -curves、不支持 -groups 的机器。
# 修复前扫描器固定传入 -groups，所有候选都会被误判为超时或失败。
openssl() {
    if [[ "$*" == *"-help"* ]]; then
        printf '%s\n' 'Usage: s_client [-curves val]'
        return 0
    fi

    if [[ "$*" == *"-groups"* ]]; then
        printf '%s\n' 's_client: Unknown option: -groups' >&2
        return 1
    fi

    [[ "$*" == *"-curves X25519"* ]] || return 1
    cat <<'EOF'
Protocol  : TLSv1.3
Server Temp Key: X25519, 253 bits
ALPN protocol: h2
Verify return code: 0 (ok)
EOF
}

now_millis() {
    if [[ -z "${TEST_CLOCK_TICK:-}" ]]; then
        TEST_CLOCK_TICK=1000
    else
        TEST_CLOCK_TICK=$((TEST_CLOCK_TICK + 42))
    fi
    printf '%s\n' "$TEST_CLOCK_TICK"
}

probe_result=$(reality_tls_probe_once "www.example.com")
[[ "$probe_result" =~ ^OK\|[0-9]+$ ]] || {
    printf 'FAIL: OpenSSL -curves 兼容探测失败，实际结果: %s\n' "$probe_result" >&2
    exit 1
}

candidate_result=$(scan_reality_candidate "www.example.com")
[[ "$candidate_result" =~ ^www\.example\.com\|3\|[0-9]+\|-$ ]] || {
    printf 'FAIL: 候选扫描结果格式或延迟统计错误: %s\n' "$candidate_result" >&2
    exit 1
}

TEST_OPENSSL_MODE=timeout
export TEST_OPENSSL_MODE
timeout_result=$(scan_reality_candidate "timeout.example.com")
[[ "$timeout_result" == "timeout.example.com|0|0|TLS 握手超时" ]] || {
    printf 'FAIL: 超时原因没有正确显示: %s\n' "$timeout_result" >&2
    exit 1
}
unset TEST_OPENSSL_MODE

for candidate in "${REALITY_SCAN_CANDIDATES[@]}"; do
    [[ "$candidate" != "addons.mozilla.org" ]] || {
        printf 'FAIL: 内置候选中仍包含 addons.mozilla.org\n' >&2
        exit 1
    }
done

manual_sni=$(prompt_manual_reality_sni <<< "manual.example.com")
[[ "$manual_sni" == "manual.example.com" ]] || {
    printf 'FAIL: 扫描后手动输入 SNI 不可用\n' >&2
    exit 1
}

printf 'PASS: Reality SNI 扫描兼容性、候选列表和手动输入流程正常\n'
