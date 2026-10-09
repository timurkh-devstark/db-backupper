#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "$LIB_DIR/config.sh"
source "$LIB_DIR/retention.sh"
source "$LIB_DIR/backup.sh"

test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
log_info() { :; }
log_error() { printf '%s\n' "$*" >&2; }

printf 'AWS_PROFILE="r2"\nS3_BUCKET_NAME="private-backups"\nS3_RETENTION_KEEP_LAST="0"\n' > "$test_dir/target.conf"
load_config_secure "$test_dir/target.conf" target
[[ "$AWS_PROFILE" == r2 && "$S3_BUCKET_NAME" == private-backups ]]
validate_retention_config
printf 'POSTGRES_URI="must-not-override-database"\n' > "$test_dir/invalid.conf"
if (load_config_secure "$test_dir/invalid.conf" target) 2>/dev/null; then
    printf 'Target accepted database settings\n' >&2
    exit 1
fi
if load_s3_target '../escape' 2>/dev/null; then
    printf 'Target accepted path traversal\n' >&2
    exit 1
fi

parse_postgres_uri() { DB_NAME=app; }
execute_dump() { printf 'dump\n' >> "$test_dir/dumps"; printf 'test data' > "$1"; }
load_s3_target() {
    [[ "$1" != invalid ]] || return 1
    AWS_PROFILE="$1"
    S3_BUCKET_NAME="bucket-$1"
    S3_BACKUP_PATH="copies/"
    S3_RETENTION_KEEP_LAST=0
}
aws() {
    local archive="$3" profile="${@: -1}"
    [[ -f "$archive" ]]
    printf '%s\t%s\n' "$profile" "$archive" >> "$test_dir/uploads"
    [[ "$profile" != "$fail_profile" ]]
}
verify_s3_upload() {
    printf '%s\n' "$AWS_PROFILE" >> "$test_dir/verifications"
    [[ "$AWS_PROFILE" != "$fail_verification" ]]
}
apply_backup_retention() {
    printf '%s\n' "$AWS_PROFILE" >> "$test_dir/retention"
    [[ "$AWS_PROFILE" != "$fail_retention" ]]
}

run_case() {
    local expected_status="$1"
    local extras="$2"
    local expected_uploads="$3"
    local status=0 archive
    : > "$test_dir/dumps"
    : > "$test_dir/uploads"
    : > "$test_dir/verifications"
    : > "$test_dir/retention"
    AWS_PROFILE=primary
    S3_BUCKET_NAME=bucket-primary
    S3_BACKUP_PATH=postgres/
    S3_RETENTION_KEEP_LAST=7
    S3_ADDITIONAL_TARGETS="$extras"
    POSTGRES_URI=postgresql://unused/app
    (action_backup 'scheduled/') > "$test_dir/output" 2>&1 || status=$?
    [[ "$status" == "$expected_status" ]]
    [[ $(wc -l < "$test_dir/dumps") -eq 1 ]]
    [[ $(wc -l < "$test_dir/uploads") -eq "$expected_uploads" ]]
    [[ $(cut -f2 "$test_dir/uploads" | sort -u | wc -l) -eq 1 ]]
    archive=$(cut -f2 "$test_dir/uploads" | head -1)
    if [[ "$expected_status" == 0 ]]; then
        [[ ! -e "$archive" ]]
    else
        [[ -s "$archive" ]]
        grep -q 'Archive retained at:' "$test_dir/output"
        # Keep test artifacts under the test directory for its cleanup.
        mv "$(dirname "$archive")" "$test_dir/retained-$case_number"
    fi
    case_number=$((case_number + 1))
}

case_number=1
fail_profile=none fail_verification=none fail_retention=none
run_case 0 '' 1
run_case 0 'r2 third' 3
[[ $(cat "$test_dir/retention") == primary ]]
[[ $(wc -l < "$test_dir/verifications") -eq 3 ]]

fail_profile=primary
run_case 1 'r2 third' 3
[[ $(cat "$test_dir/verifications") == $'r2\nthird' ]]

fail_profile=r2
run_case 1 'r2 third' 3
[[ $(cat "$test_dir/verifications") == $'primary\nthird' ]]

fail_profile=none fail_verification=primary
run_case 1 'r2' 2
[[ ! -s "$test_dir/retention" ]]

fail_verification=none fail_retention=primary
run_case 1 'r2' 2

: > "$test_dir/dumps"
S3_ADDITIONAL_TARGETS=invalid
if (action_backup 'scheduled/') >/dev/null 2>&1; then
    printf 'Invalid target did not fail before dumping\n' >&2
    exit 1
fi
[[ ! -s "$test_dir/dumps" ]]
printf 'Multiple-target tests passed.\n'
