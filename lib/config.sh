#!/usr/bin/env bash
# Configuration loading and validation for db-backupper

reset_config_vars() {
    unset AWS_PROFILE
    unset S3_BUCKET_NAME
    unset S3_BACKUP_PATH
    unset S3_RETENTION_KEEP_LAST
    unset POSTGRES_URI
    unset DOCKER_CONTAINER_NAME
}

validate_project_name() {
    local project_name="$1"

    if [[ ! "$project_name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "Invalid project name: $project_name"
        return 1
    fi

    return 0
}

# Securely load configuration without executing arbitrary code
load_config_secure() {
    local config_file="$1"
    local line_num=0
    
    log_info "Loading configuration from: $config_file"
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_num=$((line_num + 1))
        
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        
        # Parse key=value pairs
        if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            
            # Validate against whitelist
            case "$key" in
                AWS_PROFILE|S3_BUCKET_NAME|S3_BACKUP_PATH|S3_RETENTION_KEEP_LAST|POSTGRES_URI|DOCKER_CONTAINER_NAME)
                    # Remove quotes if present
                    value="${value%\"}"
                    value="${value#\"}"
                    value="${value%\'}"
                    value="${value#\'}"
                    
                    # Set variable safely
                    declare -g "$key=$value"
                    log_info "Loaded config: $key=[REDACTED]"
                    ;;
                *)
                    log_error "Unknown configuration variable '$key' at line $line_num"
                    log_error "Valid variables are: AWS_PROFILE, S3_BUCKET_NAME, S3_BACKUP_PATH, S3_RETENTION_KEEP_LAST, POSTGRES_URI, DOCKER_CONTAINER_NAME"
                    exit 1
                    ;;
            esac
        else
            log_error "Invalid configuration syntax at line $line_num: $line"
            exit 1
        fi
    done < "$config_file"
    
    log_info "Configuration file parsing completed"
}

find_legacy_config_file() {
    local config_locations=(
        "${HOME}/.config/db-backupper/backup.conf"
    )
    local location

    for location in "${config_locations[@]}"; do
        if [[ -f "$location" ]]; then
            echo "$location"
            return 0
        fi
    done

    return 1
}

find_project_config_file() {
    local project_name="$1"
    local config_locations=(
        "${HOME}/.config/db-backupper/projects/${project_name}.conf"
    )
    local location

    for location in "${config_locations[@]}"; do
        if [[ -f "$location" ]]; then
            echo "$location"
            return 0
        fi
    done

    return 1
}

list_project_configs() {
    local project_dirs=(
        "${HOME}/.config/db-backupper/projects"
    )
    local dir
    local config_path
    local project_name
    local found=1
    local nullglob_was_set=0
    declare -A seen_projects=()

    if shopt -q nullglob; then
        nullglob_was_set=1
    else
        shopt -s nullglob
    fi

    for dir in "${project_dirs[@]}"; do
        [[ -d "$dir" ]] || continue

        for config_path in "$dir"/*.conf; do
            [[ -f "$config_path" ]] || continue
            project_name="$(basename "$config_path" .conf)"

            if ! validate_project_name "$project_name" >/dev/null 2>&1; then
                continue
            fi

            if [[ -n "${seen_projects[$project_name]:-}" ]]; then
                continue
            fi

            seen_projects["$project_name"]="$config_path"
            printf '%s\t%s\n' "$project_name" "$config_path"
            found=0
        done
    done

    if [[ "$nullglob_was_set" -eq 0 ]]; then
        shopt -u nullglob
    fi

    return "$found"
}

action_list_projects() {
    local project_lines=""
    local project_dirs=(
        "${HOME}/.config/db-backupper/projects"
    )
    local line_number=1
    local project_name
    local config_path
    local search_dir

    if ! project_lines="$(list_project_configs)"; then
        echo "No project configurations found."
        echo "Searched in:"
        for search_dir in "${project_dirs[@]}"; do
            echo "  $search_dir"
        done
        return 0
    fi

    echo "Available project configurations:"
    while IFS=$'\t' read -r project_name config_path; do
        echo "${line_number}. ${project_name} -> ${config_path}"
        line_number=$((line_number + 1))
    done <<< "$project_lines"
}

load_legacy_config() {
    local config_file=""
    local config_locations=(
        "${HOME}/.config/db-backupper/backup.conf"
    )
    local location

    if ! config_file=$(find_legacy_config_file); then
        log_error "Legacy configuration file not found in any of these locations:"
        for location in "${config_locations[@]}"; do
            log_error "  - $location"
        done
        log_error "Please copy backup.conf.example to one of these locations and fill in your details."
        exit 1
    fi

    reset_config_vars
    log_info "Using legacy configuration file: $config_file"
    load_config_secure "$config_file"
    validate_config
}

load_project_config() {
    local project_name="$1"
    local config_file=""
    local config_locations=(
        "${HOME}/.config/db-backupper/projects/${project_name}.conf"
    )
    local location

    if ! validate_project_name "$project_name"; then
        exit 1
    fi

    if ! config_file=$(find_project_config_file "$project_name"); then
        log_error "Project configuration for '$project_name' not found in any of these locations:"
        for location in "${config_locations[@]}"; do
            log_error "  - $location"
        done
        exit 1
    fi

    reset_config_vars
    log_info "Using project configuration '$project_name': $config_file"
    load_config_secure "$config_file"
    validate_config
}

# Load configuration from backup.conf or a named project config
load_config() {
    local project_name="${1:-}"

    if [[ -n "$project_name" ]]; then
        load_project_config "$project_name"
        return 0
    fi

    load_legacy_config
}

# Validate required configuration variables
validate_config() {
    local required_vars=(AWS_PROFILE S3_BUCKET_NAME POSTGRES_URI DOCKER_CONTAINER_NAME)
    local missing_vars=0
    
    log_info "Starting configuration validation..."
    
    for var_name in "${required_vars[@]}"; do
        local var_value="${!var_name}"
        if [[ -z "$var_value" ]]; then
            log_error "Required configuration variable '$var_name' is not set in the active config."
            missing_vars=1
        else
            log_info "✓ $var_name is set"
        fi
    done
    
    if [[ "$missing_vars" -eq 1 ]]; then
        log_error "Configuration validation failed. Please check the active config file."
        exit 1
    fi

    log_info "Configuration validation passed successfully."
}

validate_retention_config() {
    if [[ -z "${S3_RETENTION_KEEP_LAST:-}" ]]; then
        log_error "S3_RETENTION_KEEP_LAST is required for backups."
        return 1
    fi

    if [[ ! "$S3_RETENTION_KEEP_LAST" =~ ^[1-9][0-9]*$ ]]; then
        log_error "S3_RETENTION_KEEP_LAST must be a positive integer."
        return 1
    fi
}
