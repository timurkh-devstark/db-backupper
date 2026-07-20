#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"

source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/retention.sh"

AWS_PROFILE="test"
S3_BUCKET_NAME="backup-bucket"
S3_RETENTION_KEEP_LAST="2"
PUT_LOG="$(mktemp)"

cleanup() {
    rm -f "$PUT_LOG"
}
trap cleanup EXIT

aws() {
    local operation="${2:-}"
    local key=""
    local tagging=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --key)
                key="$2"
                shift 2
                ;;
            --tagging)
                tagging="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    case "$operation" in
        list-objects-v2)
            printf '%s\t%s\t%s\t%s\t%s\n' \
                'postgres/app_20260717_010000.tar.gz' \
                'postgres/app_20260720_010000.tar.gz' \
                'postgres/app_20260718_010000.tar.gz' \
                'postgres/another_20260720_010000.tar.gz' \
                'postgres/app_20260719_010000.tar.gz'
            ;;
        get-object-tagging)
            printf '{"TagSet":[{"Key":"owner","Value":"platform"}]}'
            ;;
        put-object-tagging)
            printf '%s\t%s\n' "$key" "$tagging" >> "$PUT_LOG"
            ;;
        head-object)
            printf '6\n'
            ;;
        *)
            printf 'Unexpected aws operation: %s\n' "$operation" >&2
            return 1
            ;;
    esac
}

assert_retention_state() {
    local key="$1"
    local expected_state="$2"
    local tagging

    tagging=$(awk -F '\t' -v key="$key" '$1 == key {print $2}' "$PUT_LOG")

    jq -e \
        --arg state "$expected_state" \
        '.TagSet | any(.Key == "db-backupper-retention" and .Value == $state)' \
        <<< "$tagging" >/dev/null

    jq -e \
        '.TagSet | any(.Key == "owner" and .Value == "platform")' \
        <<< "$tagging" >/dev/null
}

apply_backup_retention "postgres/" "app"

[[ "$(wc -l < "$PUT_LOG")" -eq 4 ]]
assert_retention_state 'postgres/app_20260720_010000.tar.gz' 'active'
assert_retention_state 'postgres/app_20260719_010000.tar.gz' 'active'
assert_retention_state 'postgres/app_20260718_010000.tar.gz' 'expired'
assert_retention_state 'postgres/app_20260717_010000.tar.gz' 'expired'

archive_path=$(mktemp)
printf 'backup' > "$archive_path"
verify_s3_upload "$archive_path" 'postgres/app_20260720_010000.tar.gz'
rm -f "$archive_path"

S3_RETENTION_KEEP_LAST=""
if validate_retention_config >/dev/null 2>&1; then
    printf 'Missing retention config was accepted.\n' >&2
    exit 1
fi

S3_RETENTION_KEEP_LAST="0"
if validate_retention_config >/dev/null 2>&1; then
    printf 'Zero retention count was accepted.\n' >&2
    exit 1
fi

S3_RETENTION_KEEP_LAST="7"
validate_retention_config

printf 'Retention tests passed.\n'
