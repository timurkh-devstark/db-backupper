#!/usr/bin/env bash
# S3 backup retention functionality

RETENTION_TAG_KEY="db-backupper-retention"
RETENTION_ACTIVE_TAG_VALUE="active"
RETENTION_EXPIRED_TAG_VALUE="expired"

verify_s3_upload() {
    local local_archive_path="$1"
    local s3_key="$2"
    local local_size
    local remote_size

    local_size=$(stat -c '%s' "$local_archive_path")
    if ! remote_size=$(aws s3api head-object \
        --bucket "$S3_BUCKET_NAME" \
        --key "$s3_key" \
        --profile "$AWS_PROFILE" \
        --query 'ContentLength' \
        --output text); then
        log_error "Could not verify uploaded backup s3://${S3_BUCKET_NAME}/${s3_key}"
        return 1
    fi

    if [[ "$remote_size" != "$local_size" ]]; then
        log_error "Uploaded backup size mismatch for s3://${S3_BUCKET_NAME}/${s3_key}: local=${local_size}, remote=${remote_size}"
        return 1
    fi

    log_info "S3 upload verified: ${remote_size} bytes"
}

list_backup_keys() {
    local retention_prefix="$1"
    local database_name="$2"
    local object_prefix="${retention_prefix}${database_name}_"
    local key
    local raw_keys

    if ! raw_keys=$(aws s3api list-objects-v2 \
        --bucket "$S3_BUCKET_NAME" \
        --prefix "$object_prefix" \
        --profile "$AWS_PROFILE" \
        --query 'Contents[].Key' \
        --output text); then
        log_error "Could not list backups under s3://${S3_BUCKET_NAME}/${object_prefix}"
        return 1
    fi

    while IFS= read -r key; do
        [[ -n "$key" && "$key" != "None" ]] || continue
        if [[ "${key##*/}" =~ ^${database_name}_[0-9]{8}_[0-9]{6}\.tar\.gz$ ]]; then
            printf '%s\n' "$key"
        fi
    done <<< "$(tr '\t' '\n' <<< "$raw_keys")"
}

set_backup_retention_state() {
    local s3_key="$1"
    local retention_state="$2"
    local current_tags
    local current_state
    local updated_tags

    if ! current_tags=$(aws s3api get-object-tagging \
        --bucket "$S3_BUCKET_NAME" \
        --key "$s3_key" \
        --profile "$AWS_PROFILE" \
        --output json); then
        log_error "Could not read tags for s3://${S3_BUCKET_NAME}/${s3_key}"
        return 1
    fi

    current_state=$(jq -r \
        --arg key "$RETENTION_TAG_KEY" \
        '.TagSet[]? | select(.Key == $key) | .Value' \
        <<< "$current_tags")

    if [[ "$current_state" == "$retention_state" ]]; then
        return 0
    fi

    updated_tags=$(jq -c \
        --arg key "$RETENTION_TAG_KEY" \
        --arg value "$retention_state" \
        '{TagSet: ((.TagSet // []) | map(select(.Key != $key)) + [{Key: $key, Value: $value}])}' \
        <<< "$current_tags")

    if ! aws s3api put-object-tagging \
        --bucket "$S3_BUCKET_NAME" \
        --key "$s3_key" \
        --profile "$AWS_PROFILE" \
        --tagging "$updated_tags" \
        >/dev/null; then
        log_error "Could not update retention tag for s3://${S3_BUCKET_NAME}/${s3_key}"
        return 1
    fi

    log_info "Retention state set to '${retention_state}' for s3://${S3_BUCKET_NAME}/${s3_key}"
}

apply_backup_retention() {
    local retention_prefix="$1"
    local database_name="$2"
    local keep_last="$S3_RETENTION_KEEP_LAST"
    local index
    local retention_state
    local listed_keys
    local sorted_keys
    local backup_keys=()

    if ! listed_keys=$(list_backup_keys "$retention_prefix" "$database_name"); then
        return 1
    fi

    if [[ -n "$listed_keys" ]]; then
        sorted_keys=$(sort -r <<< "$listed_keys")
        mapfile -t backup_keys <<< "$sorted_keys"
    fi

    if [[ ${#backup_keys[@]} -eq 0 ]]; then
        log_error "No completed backups found for retention prefix s3://${S3_BUCKET_NAME}/${retention_prefix}${database_name}_"
        return 1
    fi

    log_info "Applying keep-last=${keep_last} retention to ${#backup_keys[@]} backup(s)"

    for index in "${!backup_keys[@]}"; do
        if (( index < keep_last )); then
            retention_state="$RETENTION_ACTIVE_TAG_VALUE"
        else
            retention_state="$RETENTION_EXPIRED_TAG_VALUE"
        fi

        set_backup_retention_state "${backup_keys[$index]}" "$retention_state"
    done
}
