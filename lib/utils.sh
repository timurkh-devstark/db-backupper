#!/usr/bin/env bash
# Utility functions for db-backupper

# Logging functions
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_warning() {
    echo "[WARNING] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

# Check for required commands
check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "Command '$1' not found. Please install it and ensure it's in your PATH."
        exit 1
    fi
}

append_path_if_missing() {
    local path_entry="$1"

    [[ -n "$path_entry" ]] || return 0
    case ":$PATH:" in
        *":$path_entry:"*) ;;
        *)
            if [[ -n "${PATH:-}" ]]; then
                PATH="${PATH}:$path_entry"
            else
                PATH="$path_entry"
            fi
            ;;
    esac
}

prepend_path_if_missing() {
    local path_entry="$1"

    [[ -n "$path_entry" ]] || return 0
    case ":$PATH:" in
        *":$path_entry:"*) ;;
        *)
            if [[ -n "${PATH:-}" ]]; then
                PATH="$path_entry:${PATH}"
            else
                PATH="$path_entry"
            fi
            ;;
    esac
}

# Set up robust PATH for cron environments
setup_path() {
    # Preserve existing PATH precedence and only add standard locations if missing.
    append_path_if_missing "/usr/local/bin"
    append_path_if_missing "/usr/bin"
    append_path_if_missing "/bin"
    append_path_if_missing "/usr/local/sbin"
    append_path_if_missing "/usr/sbin"
    append_path_if_missing "/sbin"
    
    # Add user's local bin if it exists
    if [[ -d "$HOME/.local/bin" ]]; then
        prepend_path_if_missing "$HOME/.local/bin"
    fi
    
    # Add snap bin if it exists (common on Ubuntu)
    if [[ -d "/snap/bin" ]]; then
        append_path_if_missing "/snap/bin"
    fi

    export PATH
}

# Check all required commands
check_all_commands() {
    check_command "aws"
    check_command "docker"
    check_command "tar"
    check_command "find"
    check_command "sed"
    check_command "tr"
    check_command "sort"
    check_command "stat"
    check_command "jq"
    # pg_dump and psql are run inside docker, so not checked on host
}

# Find the script directory (works even when installed globally)
get_script_dir() {
    local source="${BASH_SOURCE[0]}"
    
    while [[ -h "$source" ]]; do # resolve $source until the file is no longer a symlink
        local dir="$(cd -P "$(dirname "$source")" && pwd 2>&1)"
        source="$(readlink "$source" 2>&1)"
        [[ $source != /* ]] && source="$dir/$source" # if $source was a relative symlink, we need to resolve it relative to the path where the symlink file was located
    done
    local dir="$(cd -P "$(dirname "$source")" && pwd 2>&1)"
    
    # If we're installed globally, user-scoped config lives under ~/.config/db-backupper
    if [[ "$dir" == "/usr/local/bin" ]] || [[ "$dir" == "/usr/bin" ]]; then
        if [[ -f "$HOME/.config/db-backupper/backup.conf" ]]; then
            echo "$HOME/.config/db-backupper"
        else
            echo "$(pwd)"
        fi
    else
        # We're running from the source directory
        echo "$dir/.."
    fi
}

# Check available disk space (in bytes)
check_disk_space() {
    local required_bytes="$1"
    local target_dir="${2:-/tmp}"
    
    local available_bytes
    available_bytes=$(df "$target_dir" | awk 'NR==2 {print $4}')
    available_bytes=$((available_bytes * 1024)) # Convert KB to bytes
    
    if [[ $available_bytes -lt $required_bytes ]]; then
        log_error "Insufficient disk space. Required: $(numfmt --to=iec $required_bytes), Available: $(numfmt --to=iec $available_bytes)"
        return 1
    fi
    
    log_info "Disk space check passed. Available: $(numfmt --to=iec $available_bytes)"
    return 0
}

# Get current memory usage in MB
get_memory_usage() {
    local pid="${1:-$$}"
    local mem_kb
    mem_kb=$(ps -o rss= -p "$pid" 2>/dev/null || echo "0")
    echo $((mem_kb / 1024))
}

# Check if memory usage is within limits
check_memory_limit() {
    local max_memory_mb="$1"
    local current_memory_mb
    current_memory_mb=$(get_memory_usage)
    
    if [[ $current_memory_mb -gt $max_memory_mb ]]; then
        log_error "Memory limit exceeded: ${current_memory_mb}MB > ${max_memory_mb}MB"
        return 1
    fi
    
    return 0
}

# Execute command with timeout
execute_with_timeout() {
    local timeout_seconds="$1"
    local description="$2"
    shift 2
    local cmd=("$@")
    
    log_info "Starting $description (timeout: ${timeout_seconds}s)"
    
    # Start command in background
    "${cmd[@]}" &
    local cmd_pid=$!
    
    # Start timeout monitor
    (
        sleep "$timeout_seconds"
        if kill -0 "$cmd_pid" 2>/dev/null; then
            log_error "$description timed out after ${timeout_seconds}s"
            kill -TERM "$cmd_pid" 2>/dev/null
            sleep 5
            kill -KILL "$cmd_pid" 2>/dev/null
        fi
    ) &
    local timeout_pid=$!
    
    # Wait for command completion
    local exit_code=0
    wait "$cmd_pid" || exit_code=$?
    
    # Clean up timeout monitor
    kill "$timeout_pid" 2>/dev/null || true
    wait "$timeout_pid" 2>/dev/null || true
    
    return $exit_code
}

quote_for_sh() {
    local value="$1"
    printf "'%s'" "${value//\'/\'\"\'\"\'}"
}

get_cron_path() {
    echo "${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin:/snap/bin"
}

get_db_backupper_script_path() {
    local resolved_path=""

    if [[ "$0" == */* ]]; then
        resolved_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
        if [[ -x "$resolved_path" ]]; then
            echo "$resolved_path"
            return 0
        fi
    fi

    if command -v "$0" &> /dev/null; then
        resolved_path="$(command -v "$0")"
        if [[ -x "$resolved_path" ]]; then
            echo "$resolved_path"
            return 0
        fi
    fi

    if command -v db-backupper &> /dev/null; then
        resolved_path="$(command -v db-backupper)"
        if [[ -x "$resolved_path" ]]; then
            echo "$resolved_path"
            return 0
        fi
    fi

    resolved_path="$(cd "$(dirname "${BASH_SOURCE[-1]}")" && pwd)/db-backupper"
    if [[ -x "$resolved_path" ]]; then
        echo "$resolved_path"
        return 0
    fi

    return 1
}

get_active_config_path() {
    if [[ -n "${ACTIVE_PROJECT_NAME:-}" ]]; then
        echo "${HOME}/.config/db-backupper/projects/${ACTIVE_PROJECT_NAME}.conf"
    else
        echo "${HOME}/.config/db-backupper/backup.conf"
    fi
}

get_default_log_dir() {
    echo "${HOME}/.local/log/db-backupper"
}

get_safe_db_name() {
    if [[ -n "${POSTGRES_URI:-}" ]]; then
        parse_postgres_uri "$POSTGRES_URI"
    fi

    if [[ -n "${DB_NAME:-}" ]]; then
        echo "$DB_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_-'
    else
        echo "database"
    fi
}

get_default_log_file() {
    local db_name_safe=""
    db_name_safe="$(get_safe_db_name)"
    echo "$(get_default_log_dir)/${db_name_safe}_backup.log"
}

ensure_writable_parent_dir() {
    local target_path="$1"
    local nearest_existing_dir=""

    nearest_existing_dir="$(dirname "$target_path")"
    while [[ ! -d "$nearest_existing_dir" ]]; do
        nearest_existing_dir="$(dirname "$nearest_existing_dir")"
    done

    if [[ ! -w "$nearest_existing_dir" ]]; then
        log_error "Target path is not writable: $target_path"
        log_error "Nearest existing directory without write access: $nearest_existing_dir"
        return 1
    fi

    return 0
}

ensure_log_file_writable() {
    local log_file="$1"
    local log_dir=""

    log_dir="$(dirname "$log_file")"
    if ! ensure_writable_parent_dir "$log_dir"; then
        return 1
    fi

    mkdir -p "$log_dir"

    if [[ ! -d "$log_dir" ]]; then
        log_error "Log directory could not be created: $log_dir"
        return 1
    fi

    if [[ ! -w "$log_dir" ]]; then
        log_error "Log directory is not writable: $log_dir"
        return 1
    fi

    if [[ -d "$log_file" ]]; then
        log_error "Log file path points to a directory: $log_file"
        return 1
    fi

    if [[ -e "$log_file" && ! -w "$log_file" ]]; then
        log_error "Log file is not writable: $log_file"
        return 1
    fi

    return 0
}

validate_cron_schedule() {
    local schedule="$1"

    if [[ ! "$schedule" =~ ^([[:alnum:]*/,\-]+[[:space:]]+){4}[[:alnum:]*/,\-]+$ ]]; then
        log_error "Invalid cron schedule: $schedule"
        log_error "Expected 5 fields, for example: 0 2 * * *"
        return 1
    fi

    return 0
}

get_cron_job_marker() {
    if [[ -n "${ACTIVE_PROJECT_NAME:-}" ]]; then
        echo "# db-backupper managed job: project:${ACTIVE_PROJECT_NAME}"
    else
        echo "# db-backupper managed job: legacy"
    fi
}

build_cron_command_line() {
    local schedule="$1"
    local prefix="${2:-}"
    local log_file="${3:-}"
    local script_path=""
    local cron_path=""
    local command_line=""

    if [[ -z "$log_file" ]]; then
        log_file="$(get_default_log_file)"
    fi

    script_path="$(get_db_backupper_script_path)" || return 1
    cron_path="$(get_cron_path)"

    command_line="${schedule} HOME=$(quote_for_sh "$HOME") PATH=$(quote_for_sh "$cron_path") $(quote_for_sh "$script_path")"
    if [[ -n "${ACTIVE_PROJECT_NAME:-}" ]]; then
        command_line="${command_line} --project $(quote_for_sh "$ACTIVE_PROJECT_NAME")"
    fi
    command_line="${command_line} backup"
    if [[ -n "$prefix" ]]; then
        command_line="${command_line} --prefix $(quote_for_sh "$prefix")"
    fi
    command_line="${command_line} >> $(quote_for_sh "$log_file") 2>&1"

    echo "$command_line"
}

run_cron_self_check() {
    local log_file="$1"
    local script_path=""
    local cron_check_cmd=()

    script_path="$(get_db_backupper_script_path)" || {
        log_error "Could not resolve db-backupper executable path."
        return 1
    }

    cron_check_cmd=("$script_path")
    if [[ -n "${ACTIVE_PROJECT_NAME:-}" ]]; then
        cron_check_cmd+=("--project" "$ACTIVE_PROJECT_NAME")
    fi
    cron_check_cmd+=("check-cron" "--log-file" "$log_file")

    env -i \
        HOME="$HOME" \
        USER="${USER:-$(id -un)}" \
        LOGNAME="${LOGNAME:-${USER:-$(id -un)}}" \
        SHELL="/bin/sh" \
        PATH="/usr/bin:/bin" \
        "${cron_check_cmd[@]}"
}

action_check_cron() {
    local log_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --log-file)
                if [[ -z "${2:-}" ]]; then
                    log_error "ERROR: --log-file requires an argument."
                    return 1
                fi
                log_file="$2"
                shift 2
                ;;
            *)
                log_error "ERROR: Unknown option for check-cron: $1"
                return 1
                ;;
        esac
    done

    local script_path=""
    local active_config_path=""

    script_path="$(get_db_backupper_script_path)" || {
        log_error "Could not resolve db-backupper executable path."
        return 1
    }
    active_config_path="$(get_active_config_path)"
    log_file="${log_file:-$(get_default_log_file)}"

    check_command "bash"

    if [[ ! -r "$active_config_path" ]]; then
        log_error "Active config is not readable: $active_config_path"
        return 1
    fi

    if [[ ! -x "$script_path" ]]; then
        log_error "db-backupper executable is not executable: $script_path"
        return 1
    fi

    if ! ensure_log_file_writable "$log_file"; then
        return 1
    fi

    log_info "Cron readiness check passed."
    log_info "Active config: $active_config_path"
    log_info "Executable: $script_path"
    log_info "Log file: $log_file"
}

action_install_cron() {
    local schedule=""
    local prefix=""
    local log_file=""
    local sanitized_prefix=""
    local crontab_file=""
    local merged_file=""
    local marker=""
    local cron_line=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --schedule)
                if [[ -z "${2:-}" ]]; then
                    log_error "ERROR: --schedule requires an argument."
                    return 1
                fi
                schedule="$2"
                shift 2
                ;;
            --prefix)
                if [[ -z "${2:-}" ]]; then
                    log_error "ERROR: --prefix requires an argument."
                    return 1
                fi
                prefix="$2"
                shift 2
                ;;
            --log-file)
                if [[ -z "${2:-}" ]]; then
                    log_error "ERROR: --log-file requires an argument."
                    return 1
                fi
                log_file="$2"
                shift 2
                ;;
            *)
                log_error "ERROR: Unknown option for install-cron: $1"
                return 1
                ;;
        esac
    done

    if [[ -z "$schedule" ]]; then
        log_error "ERROR: --schedule is required."
        return 1
    fi

    if ! validate_cron_schedule "$schedule"; then
        return 1
    fi

    if [[ -n "$prefix" ]]; then
        sanitized_prefix="$(sanitize_s3_prefix "$prefix")" || return 1
        prefix="$sanitized_prefix"
    fi

    log_file="${log_file:-$(get_default_log_file)}"

    check_command "crontab"

    if ! run_cron_self_check "$log_file"; then
        log_error "Cron self-check failed. Refusing to install cron job."
        return 1
    fi

    crontab_file="$(mktemp)"
    merged_file="$(mktemp)"
    marker="$(get_cron_job_marker)"
    cron_line="$(build_cron_command_line "$schedule" "$prefix" "$log_file")" || {
        rm -f "$crontab_file" "$merged_file"
        return 1
    }

    if ! crontab -l > "$crontab_file" 2>/dev/null; then
        : > "$crontab_file"
    fi

    awk -v marker="$marker" '
        skip_next == 1 { skip_next = 0; next }
        $0 == marker { skip_next = 1; next }
        { print }
    ' "$crontab_file" > "$merged_file"

    {
        cat "$merged_file"
        echo "$marker"
        echo "$cron_line"
    } > "${merged_file}.new"
    mv "${merged_file}.new" "$merged_file"

    crontab "$merged_file"
    rm -f "$crontab_file" "$merged_file"

    log_info "Installed cron job successfully."
    echo "$marker"
    echo "$cron_line"
}

# Generate crontab examples for automated backups
action_crontab() {
    local script_path=""
    local log_dir=""
    local db_name_safe=""
    local daily_line=""
    local weekly_line=""
    local monthly_line=""
    local staging_line=""

    script_path="$(get_db_backupper_script_path)" || {
        log_error "Could not resolve db-backupper executable path."
        return 1
    }
    log_dir="$(get_default_log_dir)"
    db_name_safe="$(get_safe_db_name)"
    daily_line="$(build_cron_command_line "0 2 * * *" "production/" "${log_dir}/${db_name_safe}_backup.log")"
    weekly_line="$(build_cron_command_line "0 3 * * 0" "weekly/" "${log_dir}/${db_name_safe}_weekly.log")"
    monthly_line="$(build_cron_command_line "0 4 1 * *" "monthly/" "${log_dir}/${db_name_safe}_monthly.log")"
    staging_line="$(build_cron_command_line "0 1 * * *" "staging/" "${log_dir}/${db_name_safe}_staging.log")"
    
    echo "========================================="
    echo "DB-BACKUPPER CRONTAB EXAMPLES"
    echo "========================================="
    echo
    
    # Warning section
    log_warning "IMPORTANT: Always use --prefix to separate different environments!"
    log_warning "Examples: --prefix 'production/', --prefix 'staging/', --prefix 'development/'"
    echo
    
    echo "Detected script path: $script_path"
    echo "Recommended log directory: $log_dir"
    if [[ -n "${ACTIVE_PROJECT_NAME:-}" ]]; then
        echo "Active project: ${ACTIVE_PROJECT_NAME}"
    else
        echo "Active mode: legacy backup.conf"
    fi
    echo
    
    # Try to create log directory
    if [[ ! -d "$log_dir" ]]; then
        if mkdir -p "$log_dir" 2>/dev/null; then
            log_info "Created log directory: $log_dir"
        else
            log_warning "Could not create log directory: $log_dir"
            echo "Please create it manually with: sudo mkdir -p '$log_dir' && sudo chown \$(id -u):\$(id -g) '$log_dir'"
        fi
    else
        log_info "Log directory exists: $log_dir"
    fi
    
    echo
    echo "CRONTAB EXAMPLES:"
    echo "=================="
    echo
    
    echo "# Install a managed cron job with:"
    echo "# ${script_path} install-cron --schedule '0 2 * * *' --prefix 'production/'"
    echo
    echo "# Or add these lines to your crontab manually with: crontab -e"
    echo
    
    echo "# Daily backup at 2:00 AM (production environment)"
    echo "$daily_line"
    echo
    
    echo "# Weekly backup on Sunday at 3:00 AM"
    echo "$weekly_line"
    echo
    
    echo "# Monthly backup on the 1st at 4:00 AM"
    echo "$monthly_line"
    echo
    
    echo "# Staging environment backup (daily at 1:00 AM)"
    echo "$staging_line"
    echo
    
    echo "CRONTAB TIME FORMAT:"
    echo "==================="
    echo "# ┌───────────── minute (0 - 59)"
    echo "# │ ┌───────────── hour (0 - 23)"
    echo "# │ │ ┌───────────── day of the month (1 - 31)"
    echo "# │ │ │ ┌───────────── month (1 - 12)"
    echo "# │ │ │ │ ┌───────────── day of the week (0 - 6) (Sunday to Saturday)"
    echo "# │ │ │ │ │"
    echo "# │ │ │ │ │"
    echo "# * * * * * command to execute"
    echo
    
    echo "LOG MANAGEMENT RECOMMENDATIONS:"
    echo "==============================="
    echo "# Use your preferred user-level log rotation strategy for:"
    echo "# $log_dir/*.log"
    echo "# Example approaches:"
    echo "# 1. rotate or truncate these files with a periodic user cron job"
    echo "# 2. integrate them with your existing per-user log management tooling"
    echo
    
    echo "TESTING YOUR CRONTAB:"
    echo "===================="
    echo "# Test the backup command manually first:"
    if [[ -n "${ACTIVE_PROJECT_NAME:-}" ]]; then
        echo "$script_path --project ${ACTIVE_PROJECT_NAME} check-cron"
        echo "$script_path --project ${ACTIVE_PROJECT_NAME} backup --prefix \"test/\""
    else
        echo "$script_path check-cron"
        echo "$script_path backup --prefix \"test/\""
    fi
    echo
    echo "# Monitor the log files:"
    echo "tail -f $log_dir/${db_name_safe}_backup.log"
    echo
    
    log_info "Crontab examples generated successfully!"
}
