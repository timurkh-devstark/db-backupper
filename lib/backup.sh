#!/usr/bin/env bash
# Backup functionality for db-backupper

# Sanitize S3 prefix path to prevent path traversal
sanitize_s3_prefix() {
    local prefix="$1"
    
    # Remove any path traversal attempts
    prefix="${prefix//..\/}"
    prefix="${prefix//\.\.\\}"
    
    # Remove leading slashes to prevent absolute paths
    prefix="${prefix#/}"
    
    # Remove any null bytes or control characters
    prefix="${prefix//[$'\x00'-$'\x1f\x7f']}"
    
    # Ensure it doesn't start with special AWS S3 prefixes
    if [[ "$prefix" =~ ^\.aws/ ]] || [[ "$prefix" =~ ^aws/ ]]; then
        log_error "Invalid prefix: cannot start with aws/ or .aws/"
        return 1
    fi
    
    # Validate characters - allow alphanumeric, hyphen, underscore, slash, period
    if [[ ! "$prefix" =~ ^[a-zA-Z0-9._/-]*$ ]]; then
        log_error "Invalid characters in prefix: $prefix"
        return 1
    fi
    
    echo "$prefix"
}

# Action: Backup database, compress, and upload to S3
action_backup() {
    local backup_prefix_arg="$1" # Optional prefix from command line
    if ! validate_retention_config; then
        exit 1
    fi

    local targets=()
    read -r -a targets <<< "${S3_ADDITIONAL_TARGETS:-}"
    local target
    for target in "${targets[@]}"; do
        if ! (load_s3_target "$target"); then
            exit 1
        fi
    done

    log_info "Starting database backup..."
    parse_postgres_uri "$POSTGRES_URI"

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    
    local prefix_segment=""
    if [[ -n "$backup_prefix_arg" ]]; then
        # Sanitize the prefix to prevent path traversal
        prefix_segment=$(sanitize_s3_prefix "$backup_prefix_arg")
        if [[ $? -ne 0 ]]; then
            log_error "Invalid backup prefix provided"
            exit 1
        fi
        # Add trailing slash if not present, to make it work as a directory
        if [[ -n "$prefix_segment" && ! "$prefix_segment" =~ /$ ]]; then
            prefix_segment="${prefix_segment}/"
        fi
    fi

    local dump_filename="dump_${DB_NAME}_${timestamp}.sql"
    local archive_filename="${DB_NAME}_${timestamp}.tar.gz"
    
    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf -- "$temp_dir"' EXIT # Cleanup temp dir on exit

    local local_dump_path="${temp_dir}/${dump_filename}"
    local local_archive_path="${temp_dir}/${archive_filename}"

    if ! execute_dump "$local_dump_path"; then
        exit 1
    fi
    log_info "Database dump created: $local_dump_path (original name in tar: $dump_filename)"

    log_info "Compressing dump file into $archive_filename..."
    tar -czf "$local_archive_path" -C "$temp_dir" "$dump_filename"
    log_info "Archive created: $local_archive_path"

    local failed=0
    if ! (upload_backup_target "$local_archive_path" "$archive_filename" "$prefix_segment"); then
        failed=1
    fi
    for target in "${targets[@]}"; do
        if ! (load_s3_target "$target" && upload_backup_target "$local_archive_path" "$archive_filename" "$prefix_segment"); then
            log_error "Backup target '$target' failed."
            failed=1
        fi
    done

    if [[ "$failed" -ne 0 ]]; then
        trap - EXIT
        log_error "Backup did not complete for every target. Archive retained at: $local_archive_path"
        exit 1
    fi

    log_info "Backup verified in all $((1 + ${#targets[@]})) target(s)."
    rm -rf -- "$temp_dir"
    trap - EXIT
}

upload_backup_target() {
    local local_archive_path="$1"
    local archive_filename="$2"
    local prefix_segment="$3"
    local retention_prefix="${S3_BACKUP_PATH:-}${prefix_segment}"
    local s3_key="${retention_prefix}${archive_filename}"
    local s3_full_url="s3://${S3_BUCKET_NAME}/${s3_key}"

    log_info "Uploading archive to $s3_full_url (profile: $AWS_PROFILE)"
    if ! aws s3 cp "$local_archive_path" "$s3_full_url" --profile "$AWS_PROFILE"; then
        log_error "S3 upload failed: $s3_full_url"
        return 1
    fi

    if ! verify_s3_upload "$local_archive_path" "$s3_key"; then
        log_error "S3 upload verification failed. Retention was not applied."
        return 1
    fi

    if [[ "$S3_RETENTION_KEEP_LAST" != "0" ]]; then
        if ! apply_backup_retention "$retention_prefix" "$DB_NAME"; then
            log_error "Backup was uploaded, but retention could not be applied."
            return 1
        fi
    fi

    log_info "Backup successful: $s3_full_url"
}
