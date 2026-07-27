#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${1:-install-singbox-yyds.sh}"

eval "$(
    awk '
        /^# Reality 目标发现与优选$/ { capture=1 }
        /^# 在获取公网 IP 之前/ { capture=0 }
        capture { print }
    ' "$SCRIPT_PATH"
)"

info() { :; }
warn() { :; }

real_mktemp="$(command -v mktemp)"
mktemp() {
    case "${1:-}" in
        -d)
            "$real_mktemp" -d
            ;;
        -d\ *.XXXXXX)
            "$real_mktemp" ${1}
            ;;
        *.XXXXXX)
            "$real_mktemp" "$1"
            ;;
        *)
            echo "mktemp: '.': Invalid argument" >&2
            return 1
            ;;
    esac
}

REALITY_SNI=""
select_reality_sni <<< $'5\nmanual.example.com'

if [[ "$REALITY_SNI" != "manual.example.com" ]]; then
    echo "expected manual.example.com, got: $REALITY_SNI" >&2
    exit 1
fi

echo "mktemp compatibility test passed"
