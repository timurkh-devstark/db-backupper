#!/usr/bin/env bash
# Setup wizard and migration helpers for db-backupper

find_active_legacy_config_for_setup() {
    local legacy_config=""

    if ! legacy_config="$(find_legacy_config_file)"; then
        log_error "Legacy configuration file not found."
        log_error "Expected one of:"
        log_error "  - ./backup.conf"
        log_error "  - ${HOME}/.config/db-backupper/backup.conf"
        log_error "  - /etc/db-backupper/backup.conf"
        return 1
    fi

    echo "$legacy_config"
}

get_project_config_target_path() {
    local project_name="$1"
    local legacy_config_path="$2"

    case "$legacy_config_path" in
        "./backup.conf")
            echo "./.db-backupper/projects/${project_name}.conf"
            ;;
        "${HOME}/.config/db-backupper/backup.conf")
            echo "${HOME}/.config/db-backupper/projects/${project_name}.conf"
            ;;
        "/etc/db-backupper/backup.conf")
            echo "/etc/db-backupper/projects/${project_name}.conf"
            ;;
        *)
            log_error "Unsupported legacy config location: $legacy_config_path"
            return 1
            ;;
    esac
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
    local legacy_config_path="$1"

    echo "Legacy configuration found at: ${legacy_config_path}"
    echo ""
    echo "Choose setup mode:"
    echo "1. Keep legacy mode"
    echo "2. Create named project from legacy config"
    echo "3. Cancel"

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
    local legacy_config_path="$2"
    local project_name="${3:-}"
    local project_config_path="${4:-}"

    echo ""
    echo "Setup summary:"

    case "$mode" in
        legacy)
            echo "1. Active mode: legacy"
            echo "2. Legacy config: ${legacy_config_path}"
            echo "3. Existing commands remain valid:"
            echo "   db-backupper backup"
            echo "   db-backupper restore /path/to/dump.sql --purge"
            ;;
        project)
            echo "1. Active mode: project"
            echo "2. Source legacy config: ${legacy_config_path}"
            echo "3. Project name: ${project_name}"
            echo "4. Project config: ${project_config_path}"
            echo "5. Next commands to use:"
            echo "   db-backupper --project ${project_name} backup"
            echo "   db-backupper --project ${project_name} crontab"
            echo "6. Legacy config was kept in place and was not removed."
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

    if ! legacy_config_path="$(find_active_legacy_config_for_setup)"; then
        return 1
    fi

    if existing_project_config="$(find_project_config_file "$project_name")"; then
        log_error "Project config '${project_name}' already exists at: ${existing_project_config}"
        return 1
    fi

    if ! project_config_path="$(get_project_config_target_path "$project_name" "$legacy_config_path")"; then
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
    print_setup_next_steps "project" "$legacy_config_path" "$project_name" "$project_config_path"
}

action_setup_keep_legacy() {
    local legacy_config_path=""

    if ! legacy_config_path="$(find_active_legacy_config_for_setup)"; then
        return 1
    fi

    log_info "Keeping legacy configuration mode."
    print_setup_next_steps "legacy" "$legacy_config_path"
}

action_setup() {
    local setup_mode=""
    local project_name=""

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

    if [[ -z "$setup_mode" ]]; then
        local legacy_config_path=""

        if ! legacy_config_path="$(find_active_legacy_config_for_setup)"; then
            echo "Setup currently supports migrating an existing legacy backup.conf."
            echo "If you are starting fresh, create a named config from project.conf.example."
            return 1
        fi

        prompt_setup_mode "$legacy_config_path"
        setup_mode="$SETUP_SELECTED_MODE"

        if [[ "$setup_mode" == "cancel" ]]; then
            log_info "Setup cancelled."
            return 0
        fi
    fi

    case "$setup_mode" in
        legacy)
            action_setup_keep_legacy
            ;;
        project)
            if [[ -z "$project_name" ]]; then
                prompt_project_name
                project_name="$SETUP_SELECTED_PROJECT_NAME"
            fi
            migrate_legacy_to_project "$project_name"
            ;;
        *)
            log_error "ERROR: Invalid setup mode '${setup_mode}'. Expected 'legacy' or 'project'."
            return 1
            ;;
    esac
}
