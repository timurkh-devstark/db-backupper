#!/usr/bin/env bash
# Setup wizard and migration helpers for db-backupper

find_configured_legacy_config_for_setup() {
    local config_locations=(
        "${HOME}/.config/db-backupper/backup.conf"
        "/etc/db-backupper/backup.conf"
        "./backup.conf"
    )
    local legacy_config=""
    local config_status=""

    for legacy_config in "${config_locations[@]}"; do
        [[ -f "$legacy_config" ]] || continue
        config_status="$(classify_legacy_config_for_setup "$legacy_config")"
        if [[ "$config_status" == "configured" ]]; then
            echo "$legacy_config"
            return 0
        fi
    done

    return 1
}

find_active_legacy_config_for_setup() {
    local config_locations=(
        "${HOME}/.config/db-backupper/backup.conf"
        "/etc/db-backupper/backup.conf"
        "./backup.conf"
    )
    local legacy_config=""
    local placeholder_config=""
    local config_status=""

    for legacy_config in "${config_locations[@]}"; do
        [[ -f "$legacy_config" ]] || continue

        config_status="$(classify_legacy_config_for_setup "$legacy_config")"

        case "$config_status" in
            configured)
                echo "$legacy_config"
                return 0
                ;;
            template)
                if [[ -z "$placeholder_config" ]]; then
                    placeholder_config="$legacy_config"
                fi
                ;;
            invalid)
                log_warning "Skipping invalid legacy config during setup: ${legacy_config}"
                ;;
        esac
    done

    if [[ -n "$placeholder_config" ]]; then
        log_error "Found only an unconfigured legacy template at: ${placeholder_config}"
        log_error "Edit backup.conf with real values first or create a named config from project.conf.example."
        return 1
    fi

    log_error "Legacy configuration file not found."
    log_error "Expected one of:"
    log_error "  - ${HOME}/.config/db-backupper/backup.conf"
    log_error "  - /etc/db-backupper/backup.conf"
    log_error "  - ./backup.conf"
    return 1
}

get_legacy_template_source_path() {
    local candidate_paths=(
        "${SCRIPT_DIR}/backup.conf.example"
        "${HOME}/.config/db-backupper/backup.conf"
        "/etc/db-backupper/backup.conf"
        "./backup.conf"
    )
    local candidate_path=""
    local config_status=""

    for candidate_path in "${candidate_paths[@]}"; do
        [[ -f "$candidate_path" ]] || continue
        config_status="$(classify_legacy_config_for_setup "$candidate_path")"
        if [[ "$config_status" == "template" ]]; then
            echo "$candidate_path"
            return 0
        fi
    done

    return 1
}

get_project_template_source_path() {
    local candidate_paths=(
        "${SCRIPT_DIR}/project.conf.example"
        "${HOME}/.config/db-backupper/projects/example.conf"
        "/etc/db-backupper/projects/example.conf"
    )
    local candidate_path=""

    for candidate_path in "${candidate_paths[@]}"; do
        if [[ -f "$candidate_path" ]]; then
            echo "$candidate_path"
            return 0
        fi
    done

    return 1
}

write_embedded_legacy_template() {
    local target_path="$1"

    cat > "$target_path" << 'EOF'
# Configuration for the PostgreSQL Backup Tool

# --- AWS Configuration ---
AWS_PROFILE="default"
S3_BUCKET_NAME="your-s3-bucket-name"
S3_BACKUP_PATH="postgres_dumps/"
S3_RETENTION_KEEP_LAST="7"


# --- PostgreSQL Configuration ---
POSTGRES_URI="postgresql://user:password@localhost:5432/dbname"
DOCKER_CONTAINER_NAME="your_postgres_container_name"
EOF
}

write_embedded_project_template() {
    local target_path="$1"

    cat > "$target_path" << 'EOF'
# Configuration for a named db-backupper project

# --- AWS Configuration ---
AWS_PROFILE="default"
S3_BUCKET_NAME="your-s3-bucket-name"
S3_BACKUP_PATH="postgres_dumps/your-project/"
S3_RETENTION_KEEP_LAST="7"


# --- PostgreSQL Configuration ---
POSTGRES_URI="postgresql://user:password@localhost:5432/dbname"
DOCKER_CONTAINER_NAME="your_postgres_container_name"
EOF
}

create_config_from_template() {
    local target_path="$1"
    local template_path="${2:-}"
    local template_kind="$3"

    mkdir -p "$(dirname "$target_path")"

    if [[ -n "$template_path" ]]; then
        cp "$template_path" "$target_path"
    else
        case "$template_kind" in
            legacy)
                write_embedded_legacy_template "$target_path"
                ;;
            project)
                write_embedded_project_template "$target_path"
                ;;
            *)
                log_error "Unknown template kind: $template_kind"
                return 1
                ;;
        esac
    fi

    chmod 600 "$target_path"
}

classify_legacy_config_for_setup() {
    local config_file="$1"
    local inspection_output=""
    local -a inspection_lines=()
    local s3_bucket=""
    local postgres_uri=""
    local docker_container=""

    if ! inspection_output="$(
        reset_config_vars
        load_config_secure "$config_file" >/dev/null 2>&1
        validate_config >/dev/null 2>&1
        printf '%s\n%s\n%s\n' "${S3_BUCKET_NAME:-}" "${POSTGRES_URI:-}" "${DOCKER_CONTAINER_NAME:-}"
    )"; then
        echo "invalid"
        return 0
    fi

    mapfile -t inspection_lines <<< "$inspection_output"
    s3_bucket="${inspection_lines[0]:-}"
    postgres_uri="${inspection_lines[1]:-}"
    docker_container="${inspection_lines[2]:-}"

    if [[ "$s3_bucket" == "your-s3-bucket-name" ]] || [[ "$postgres_uri" == "postgresql://user:password@localhost:5432/dbname" ]] || [[ "$docker_container" == "your_postgres_container_name" ]]; then
        echo "template"
        return 0
    fi

    echo "configured"
}

ensure_project_config_target_writable() {
    local project_config_path="$1"
    local project_config_dir=""
    local nearest_existing_dir=""

    project_config_dir="$(dirname "$project_config_path")"
    nearest_existing_dir="$project_config_dir"

    while [[ ! -d "$nearest_existing_dir" ]]; do
        nearest_existing_dir="$(dirname "$nearest_existing_dir")"
    done

    if [[ ! -w "$nearest_existing_dir" ]]; then
        log_error "Project config target is not writable: ${project_config_path}"
        log_error "Nearest existing directory without write access: ${nearest_existing_dir}"
        return 1
    fi

    return 0
}

ensure_legacy_config_target_writable() {
    local legacy_config_path="$1"
    local legacy_config_dir=""
    local nearest_existing_dir=""

    legacy_config_dir="$(dirname "$legacy_config_path")"
    nearest_existing_dir="$legacy_config_dir"

    while [[ ! -d "$nearest_existing_dir" ]]; do
        nearest_existing_dir="$(dirname "$nearest_existing_dir")"
    done

    if [[ ! -w "$nearest_existing_dir" ]]; then
        log_error "Legacy config target is not writable: ${legacy_config_path}"
        log_error "Nearest existing directory without write access: ${nearest_existing_dir}"
        return 1
    fi

    return 0
}

get_project_config_target_path() {
    local project_name="$1"

    echo "${HOME}/.config/db-backupper/projects/${project_name}.conf"
}

get_user_legacy_config_target_path() {
    echo "${HOME}/.config/db-backupper/backup.conf"
}

print_setup_usage() {
    echo "Usage: db-backupper setup [--mode legacy|project] [--name <project-name>]"
    echo ""
    echo "Examples:"
    echo "  db-backupper setup"
    echo "  db-backupper setup --mode legacy"
    echo "  db-backupper setup --mode project --name app-prod"
}

prompt_setup_mode() {
    local legacy_config_path="${1:-}"

    if [[ -n "$legacy_config_path" ]]; then
        echo "Configured legacy configuration found at: ${legacy_config_path}"
        echo ""
        echo "Choose setup mode:"
        echo "1. Use user-scoped legacy mode"
        echo "2. Create named project in ~/.config/db-backupper/projects"
        echo "3. Cancel"
    else
        echo "No configured legacy config found."
        echo "Starting fresh setup in ~/.config/db-backupper."
        echo ""
        echo "Choose setup mode:"
        echo "1. Create user-scoped legacy config"
        echo "2. Create named project config"
        echo "3. Cancel"
    fi

    while true; do
        printf "Enter choice [1-3]: "
        read -r setup_choice

        case "$setup_choice" in
            1)
                SETUP_SELECTED_MODE="legacy"
                return 0
                ;;
            2)
                SETUP_SELECTED_MODE="project"
                return 0
                ;;
            3)
                SETUP_SELECTED_MODE="cancel"
                return 0
                ;;
            *)
                log_warning "Invalid choice. Please enter 1, 2, or 3."
                ;;
        esac
    done
}

prompt_project_name() {
    local project_name=""

    while true; do
        printf "Enter project name: "
        read -r project_name

        if [[ -z "$project_name" ]]; then
            log_warning "Project name cannot be empty."
            continue
        fi

        if validate_project_name "$project_name" >/dev/null 2>&1; then
            SETUP_SELECTED_PROJECT_NAME="$project_name"
            return 0
        fi

        log_warning "Invalid project name. Use only letters, numbers, dots, underscores, and hyphens."
    done
}

print_setup_next_steps() {
    local mode="$1"
    local legacy_config_path="${2:-}"
    local project_name="${3:-}"
    local project_config_path="${4:-}"
    local setup_origin="${5:-migration}"

    echo ""
    echo "Setup summary:"

    case "$mode" in
        legacy)
            echo "1. Active mode: user-scoped legacy"
            echo "2. Active legacy config: ${legacy_config_path}"
            echo "3. Edit this file with your real values if needed."
            echo "4. Commands to use:"
            echo "   db-backupper backup"
            echo "   db-backupper install-cron --schedule '0 2 * * *' --prefix 'production/'"
            ;;
        project)
            echo "1. Active mode: project"
            if [[ "$setup_origin" == "migration" ]]; then
                echo "2. Source legacy config: ${legacy_config_path}"
                echo "3. Project name: ${project_name}"
                echo "4. Project config: ${project_config_path}"
                echo "5. Edit this file if needed."
                echo "6. Next commands to use:"
                echo "   db-backupper --project ${project_name} backup"
                echo "   db-backupper --project ${project_name} install-cron --schedule '0 2 * * *' --prefix 'production/'"
                echo "7. Source legacy config was not removed."
            else
                echo "2. Project name: ${project_name}"
                echo "3. Project config: ${project_config_path}"
                echo "4. Edit this file with your real values."
                echo "5. Next commands to use:"
                echo "   db-backupper --project ${project_name} backup"
                echo "   db-backupper --project ${project_name} install-cron --schedule '0 2 * * *' --prefix 'production/'"
            fi
            ;;
    esac
}

migrate_legacy_to_project() {
    local project_name="$1"
    local legacy_config_path=""
    local project_config_path=""
    local project_config_dir=""
    local existing_project_config=""

    if ! validate_project_name "$project_name"; then
        return 1
    fi

    if ! legacy_config_path="$(find_configured_legacy_config_for_setup)"; then
        return 1
    fi

    if existing_project_config="$(find_project_config_file "$project_name")"; then
        log_error "Project config '${project_name}' already exists at: ${existing_project_config}"
        return 1
    fi

    project_config_path="$(get_project_config_target_path "$project_name")"

    if ! ensure_project_config_target_writable "$project_config_path"; then
        return 1
    fi

    project_config_dir="$(dirname "$project_config_path")"
    mkdir -p "$project_config_dir"

    cp "$legacy_config_path" "$project_config_path"
    chmod 600 "$project_config_path"

    if ! (reset_config_vars; load_config_secure "$project_config_path" >/dev/null 2>&1; validate_config >/dev/null 2>&1); then
        rm -f "$project_config_path"
        log_error "Created project config failed validation and was removed: ${project_config_path}"
        return 1
    fi

    log_info "Created project config: ${project_config_path}"
    print_setup_next_steps "project" "$legacy_config_path" "$project_name" "$project_config_path" "migration"
}

ensure_user_legacy_config() {
    local legacy_config_path=""
    local target_legacy_config_path=""

    if ! legacy_config_path="$(find_configured_legacy_config_for_setup)"; then
        return 1
    fi

    target_legacy_config_path="$(get_user_legacy_config_target_path)"

    if [[ "$legacy_config_path" != "$target_legacy_config_path" ]]; then
        if [[ -f "$target_legacy_config_path" ]]; then
            log_error "User-scoped legacy config already exists at: ${target_legacy_config_path}"
            return 1
        fi

        if ! ensure_legacy_config_target_writable "$target_legacy_config_path"; then
            return 1
        fi

        mkdir -p "$(dirname "$target_legacy_config_path")"
        cp "$legacy_config_path" "$target_legacy_config_path"
        chmod 600 "$target_legacy_config_path"

        if ! (reset_config_vars; load_config_secure "$target_legacy_config_path" >/dev/null 2>&1; validate_config >/dev/null 2>&1); then
            rm -f "$target_legacy_config_path"
            log_error "Created user-scoped legacy config failed validation and was removed: ${target_legacy_config_path}"
            return 1
        fi

        log_info "Created user-scoped legacy config: ${target_legacy_config_path}"
    fi

    SETUP_SELECTED_LEGACY_CONFIG_PATH="$target_legacy_config_path"
}

ensure_fresh_legacy_template() {
    local target_legacy_config_path=""
    local template_source_path=""
    local existing_status=""

    target_legacy_config_path="$(get_user_legacy_config_target_path)"

    if [[ -f "$target_legacy_config_path" ]]; then
        existing_status="$(classify_legacy_config_for_setup "$target_legacy_config_path")"
        case "$existing_status" in
            configured|template)
                log_info "Using existing user-scoped legacy config: ${target_legacy_config_path}"
                SETUP_SELECTED_LEGACY_CONFIG_PATH="$target_legacy_config_path"
                return 0
                ;;
            *)
                log_error "User-scoped legacy config already exists but is invalid: ${target_legacy_config_path}"
                return 1
                ;;
        esac
    fi

    if ! ensure_legacy_config_target_writable "$target_legacy_config_path"; then
        return 1
    fi

    template_source_path="$(get_legacy_template_source_path || true)"
    create_config_from_template "$target_legacy_config_path" "$template_source_path" "legacy" || return 1

    log_info "Created user-scoped legacy config template: ${target_legacy_config_path}"
    SETUP_SELECTED_LEGACY_CONFIG_PATH="$target_legacy_config_path"
}

ensure_fresh_project_template() {
    local project_name="$1"
    local project_config_path=""
    local template_source_path=""

    if ! validate_project_name "$project_name"; then
        return 1
    fi

    project_config_path="$(get_project_config_target_path "$project_name")"

    if [[ -f "$project_config_path" ]]; then
        log_error "Project config '${project_name}' already exists at: ${project_config_path}"
        return 1
    fi

    if ! ensure_project_config_target_writable "$project_config_path"; then
        return 1
    fi

    template_source_path="$(get_project_template_source_path || true)"
    create_config_from_template "$project_config_path" "$template_source_path" "project" || return 1

    log_info "Created project config template: ${project_config_path}"
    print_setup_next_steps "project" "" "$project_name" "$project_config_path" "fresh"
}

action_setup_keep_legacy() {
    if ! ensure_user_legacy_config; then
        return 1
    fi

    log_info "Using user-scoped legacy configuration mode."
    print_setup_next_steps "legacy" "$SETUP_SELECTED_LEGACY_CONFIG_PATH"
}

action_setup_fresh_legacy() {
    if ! ensure_fresh_legacy_template; then
        return 1
    fi

    log_info "Created fresh user-scoped legacy setup."
    print_setup_next_steps "legacy" "$SETUP_SELECTED_LEGACY_CONFIG_PATH"
}

action_setup_fresh_project() {
    local project_name="$1"

    ensure_fresh_project_template "$project_name"
}

action_setup() {
    local setup_mode=""
    local project_name=""
    local legacy_config_path=""
    local has_configured_legacy=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                if [[ -z "${2:-}" ]]; then
                    log_error "ERROR: --mode requires an argument."
                    print_setup_usage
                    return 1
                fi
                setup_mode="$2"
                shift 2
                ;;
            --name)
                if [[ -z "${2:-}" ]]; then
                    log_error "ERROR: --name requires an argument."
                    print_setup_usage
                    return 1
                fi
                project_name="$2"
                shift 2
                ;;
            --help|-h)
                print_setup_usage
                return 0
                ;;
            *)
                log_error "ERROR: Unknown option for setup: $1"
                print_setup_usage
                return 1
                ;;
        esac
    done

    if [[ -n "$project_name" && "$setup_mode" == "legacy" ]]; then
        log_error "ERROR: --name can only be used with --mode project."
        return 1
    fi

    if legacy_config_path="$(find_configured_legacy_config_for_setup 2>/dev/null)"; then
        has_configured_legacy=1
    fi

    if [[ -z "$setup_mode" ]]; then
        prompt_setup_mode "$legacy_config_path"
        setup_mode="$SETUP_SELECTED_MODE"

        if [[ "$setup_mode" == "cancel" ]]; then
            log_info "Setup cancelled."
            return 0
        fi
    fi

    case "$setup_mode" in
        legacy)
            if [[ "$has_configured_legacy" -eq 1 ]]; then
                action_setup_keep_legacy
            else
                action_setup_fresh_legacy
            fi
            ;;
        project)
            if [[ -z "$project_name" ]]; then
                prompt_project_name
                project_name="$SETUP_SELECTED_PROJECT_NAME"
            fi
            if [[ "$has_configured_legacy" -eq 1 ]]; then
                migrate_legacy_to_project "$project_name"
            else
                action_setup_fresh_project "$project_name"
            fi
            ;;
        *)
            log_error "ERROR: Invalid setup mode '${setup_mode}'. Expected 'legacy' or 'project'."
            return 1
            ;;
    esac
}
