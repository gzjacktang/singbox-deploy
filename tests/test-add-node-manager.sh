#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${1:-install-singbox-yyds.sh}"
workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT

awk '
    /^cat > .*SB_SCRIPT/ { capture=1; next }
    /^# 主循环$/ { capture=0 }
    capture { print }
' "$SCRIPT_PATH" > "$workspace/sb-functions.sh"
# shellcheck source=/dev/null
source "$workspace/sb-functions.sh"

CONFIG_PATH="$workspace/config.json"
CACHE_FILE="$workspace/cache"
PROTOCOL_FILE="$workspace/protocols"
REALITY_PUBLIC_FILE="$workspace/reality.pub"
REALITY_SID_FILE="$workspace/reality.sid"
URI_FILE="$workspace/uris.txt"

write_base_config() {
    printf '%s\n' '{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct-out"}]}' > "$CONFIG_PATH"
}

assert_node() {
    local expected_type="$1"
    jq -e --arg type "$expected_type" '
      (.inbounds | length) == 1
      and .inbounds[0].type == $type
      and .inbounds[0].listen_port == 23456
    ' "${CONFIG_PATH}.tmp" >/dev/null
}

write_base_config
append_new_node_config ss 23456 "ss-secret" "2022-blake3-aes-128-gcm"
assert_node shadowsocks
jq -e '.inbounds[0].password == "ss-secret"' "${CONFIG_PATH}.tmp" >/dev/null

write_base_config
append_new_node_config hy2 23456 "hy2-secret"
assert_node hysteria2
jq -e '.inbounds[0].tls.alpn == ["h3"]' "${CONFIG_PATH}.tmp" >/dev/null

write_base_config
append_new_node_config tuic 23456 "tuic-secret" "11111111-1111-4111-8111-111111111111"
assert_node tuic
jq -e '.inbounds[0].users[0].uuid == "11111111-1111-4111-8111-111111111111"' "${CONFIG_PATH}.tmp" >/dev/null

write_base_config
append_new_node_config vless 23456 "22222222-2222-4222-8222-222222222222" "private-key" "a1b2c3d4" "www.example.com"
assert_node vless
jq -e '
  .inbounds[0].tls.server_name == "www.example.com"
  and .inbounds[0].tls.reality.handshake.server == "www.example.com"
  and .inbounds[0].tls.reality.short_id == ["a1b2c3d4"]
' "${CONFIG_PATH}.tmp" >/dev/null

write_base_config
reality_json='{"sid":"b1c2d3e4","sni":"www.example.net"}'
append_new_node_config anytls 23456 "anytls-secret" "user01" "private-key" "$reality_json"
assert_node anytls
jq -e '
  .inbounds[0].users[0].name == "user01"
  and .inbounds[0].tls.server_name == "www.example.net"
  and .inbounds[0].tls.reality.short_id == ["b1c2d3e4"]
' "${CONFIG_PATH}.tmp" >/dev/null

cp "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
if port_is_available 23456; then
    echo "configured port should not be available" >&2
    exit 1
fi

printf '%s\n' '{"inbounds":[{"type":"vless","listen_port":24444,"tls":{"enabled":true}}]}' > "$CONFIG_PATH"
if reality_vless_inbound_exists; then
    echo "plain VLESS must not be treated as VLESS Reality" >&2
    exit 1
fi

printf '%s\n' '{"inbounds":[{"type":"vless","listen_port":24444,"tls":{"reality":{"enabled":true}}}]}' > "$CONFIG_PATH"
if ! reality_vless_inbound_exists; then
    echo "VLESS Reality inbound was not detected" >&2
    exit 1
fi

printf '%s\n' '{"inbounds":[{"type":"anytls","listen_port":25555,"tls":{"enabled":true}}]}' > "$CONFIG_PATH"
if reality_anytls_inbound_exists; then
    echo "plain AnyTLS must not be treated as AnyTLS Reality" >&2
    exit 1
fi

printf '%s\n' '{"inbounds":[{"type":"anytls","listen_port":25555,"tls":{"reality":{"enabled":true}}}]}' > "$CONFIG_PATH"
if ! reality_anytls_inbound_exists; then
    echo "AnyTLS Reality inbound was not detected" >&2
    exit 1
fi

valid_reality_sni_value "www.example.com"
if valid_reality_sni_value 'bad.example.com;touch /tmp/pwned'; then
    echo "unsafe Reality SNI was accepted" >&2
    exit 1
fi

cat > "$CONFIG_PATH" <<'JSON'
{
  "inbounds": [
    {
      "type": "vless",
      "listen_port": 11111,
      "users": [{"name": "plain", "uuid": "11111111-1111-4111-8111-111111111111"}],
      "tls": {"enabled": false}
    },
    {
      "type": "vless",
      "listen_port": 22222,
      "users": [{"name": "reality-user", "uuid": "22222222-2222-4222-8222-222222222222", "flow": "xtls-rprx-vision"}],
      "tls": {
        "server_name": "www.example.com",
        "reality": {"enabled": true, "private_key": "private-key", "short_id": ["a1b2c3d4"]}
      }
    }
  ],
  "outbounds": [{"type": "direct"}]
}
JSON
cat > "$PROTOCOL_FILE" <<'FLAGS'
ENABLE_SS=false
ENABLE_HY2=false
ENABLE_TUIC=false
ENABLE_REALITY=true
ENABLE_ANYTLS=false
FLAGS
cat > "$CACHE_FILE" <<'CACHE'
ENABLE_SS=false
ENABLE_HY2=false
ENABLE_TUIC=false
ENABLE_REALITY=true
ENABLE_ANYTLS=false
REALITY_SNI=www.example.com
CUSTOM_IP=node.example.net
CACHE
printf '%s' 'public-key' > "$REALITY_PUBLIC_FILE"
printf '%s' 'a1b2c3d4' > "$REALITY_SID_FILE"
generate_uris
grep -q 'vless://22222222-2222-4222-8222-222222222222@node.example.net:22222' "$URI_FILE"
if grep -q '11111111-1111-4111-8111-111111111111' "$URI_FILE"; then
    echo "plain VLESS user leaked into Reality links" >&2
    exit 1
fi

sing-box() { return 0; }
generate_uris() { return 0; }
service_restart() { return 1; }

write_base_config
printf '%s\n' 'ENABLE_SS=false' > "$CACHE_FILE"
printf '%s\n' 'ENABLE_SS=false' > "$PROTOCOL_FILE"
append_new_node_config ss 23456 "ss-secret" "2022-blake3-aes-128-gcm"
if commit_new_node ENABLE_SS; then
    echo "commit should fail when service restart fails" >&2
    exit 1
fi
jq -e '.inbounds | length == 0' "$CONFIG_PATH" >/dev/null
grep -qx 'ENABLE_SS=false' "$CACHE_FILE"
grep -qx 'ENABLE_SS=false' "$PROTOCOL_FILE"

service_restart() { return 0; }
append_new_node_config ss 23456 "ss-secret" "2022-blake3-aes-128-gcm"
commit_new_node ENABLE_SS
jq -e '.inbounds[0].type == "shadowsocks"' "$CONFIG_PATH" >/dev/null
grep -qx 'ENABLE_SS=true' "$CACHE_FILE"
grep -qx 'ENABLE_SS=true' "$PROTOCOL_FILE"

write_base_config
append_new_node_config vless 24567 "22222222-2222-4222-8222-222222222222" "private-key" "a1b2c3d4" "www.example.com"
commit_new_node ENABLE_REALITY "public-key" "a1b2c3d4" "www.example.com"
grep -qx 'REALITY_SNI=www.example.com' "$CACHE_FILE"
grep -qx 'public-key' "$REALITY_PUBLIC_FILE"
grep -qx 'a1b2c3d4' "$REALITY_SID_FILE"

echo "add node manager tests passed"
