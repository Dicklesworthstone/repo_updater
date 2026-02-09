#!/usr/bin/env bash
#
# Unit tests: Review policy functions (bd-7onq)
#
# Covers:
# - get_review_policy_dir
# - init_review_policies
# - validate_policy_file
# - load_policy_for_repo
# - get_policy_value
# - repo_allows_push
# - repo_requires_approval
# - apply_policy_priority_boost
#
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/test_framework.sh"

source_ru_function "get_review_policy_dir"
source_ru_function "init_review_policies"
source_ru_function "validate_policy_file"
source_ru_function "load_policy_for_repo"
source_ru_function "get_policy_value"
source_ru_function "repo_allows_push"
source_ru_function "repo_requires_approval"
source_ru_function "apply_policy_priority_boost"

# Mock logging (avoid noisy output on error paths)
log_error() { :; }
log_warn() { :; }
log_info() { :; }
log_verbose() { :; }

require_jq_or_skip() {
    if ! command -v jq &>/dev/null; then
        skip_test "jq not installed"
        return 1
    fi
    return 0
}

#==============================================================================
# get_review_policy_dir
#==============================================================================

test_get_review_policy_dir_uses_config_dir() {
    local test_name="get_review_policy_dir: uses RU_CONFIG_DIR"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"

    local result
    result=$(get_review_policy_dir)

    assert_equals "$env_root/config/ru/review-policies.d" "$result" "Returns policy dir under RU_CONFIG_DIR"

    log_test_pass "$test_name"
}

#==============================================================================
# init_review_policies
#==============================================================================

test_init_review_policies_creates_dir() {
    local test_name="init_review_policies: creates directory and example"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"

    local policy_dir="$env_root/config/ru/review-policies.d"

    # Should not exist yet
    [[ ! -d "$policy_dir" ]] || fail "Policy dir should not exist before init"

    local output
    output=$(init_review_policies 2>&1)
    local exit_code=$?

    assert_equals "0" "$exit_code" "init exits 0"
    assert_dir_exists "$policy_dir" "Policy directory created"
    assert_file_exists "$policy_dir/_default.example" "Example file created"

    log_test_pass "$test_name"
}

test_init_review_policies_idempotent() {
    local test_name="init_review_policies: idempotent when dir exists"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"

    init_review_policies quiet >/dev/null 2>&1
    init_review_policies quiet >/dev/null 2>&1
    local exit_code=$?

    assert_equals "0" "$exit_code" "Second init exits 0"

    log_test_pass "$test_name"
}

test_init_review_policies_quiet_mode() {
    local test_name="init_review_policies: quiet suppresses output"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"

    local output
    output=$(init_review_policies quiet 2>&1)

    # Quiet mode should produce no info output (log_info is mocked to :)
    # Just verify it completes successfully
    assert_equals "0" "$?" "Quiet init exits 0"

    log_test_pass "$test_name"
}

#==============================================================================
# validate_policy_file
#==============================================================================

test_validate_policy_file_valid() {
    local test_name="validate_policy_file: accepts valid policy"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)

    local policy_file="$env_root/valid_policy"
    cat > "$policy_file" << 'EOF'
# Comment line
BASE_PRIORITY=2
REVIEW_ALLOW_PUSH=true
REVIEW_REQUIRE_APPROVAL=false
MAX_PARALLEL_AGENTS=8
LABEL_PRIORITY_BOOST=security=2,bug=1,documentation=-1
SKIP_PATTERNS=*.generated.go,vendor/*
TEST_COMMAND=make test
LINT_COMMAND=golangci-lint run
EOF

    local output
    output=$(validate_policy_file "$policy_file" 2>&1)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Valid policy returns 0"
    assert_contains "$output" "Valid" "Reports valid"

    log_test_pass "$test_name"
}

test_validate_policy_file_empty() {
    local test_name="validate_policy_file: accepts empty/comment-only file"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)

    local policy_file="$env_root/empty_policy"
    cat > "$policy_file" << 'EOF'
# Only comments
# Nothing active
EOF

    local output
    output=$(validate_policy_file "$policy_file" 2>&1)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Empty policy returns 0"
    assert_contains "$output" "Valid" "Reports valid"

    log_test_pass "$test_name"
}

test_validate_policy_file_missing() {
    local test_name="validate_policy_file: rejects missing file"
    log_test_start "$test_name"

    local output
    output=$(validate_policy_file "/nonexistent/policy" 2>&1)
    local exit_code=$?

    assert_equals "1" "$exit_code" "Missing file returns 1"
    assert_contains "$output" "File not found" "Reports missing file"

    log_test_pass "$test_name"
}

test_validate_policy_file_bad_format() {
    local test_name="validate_policy_file: rejects invalid format"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)

    local policy_file="$env_root/bad_format"
    cat > "$policy_file" << 'EOF'
not a valid line
lowercase_key=value
EOF

    local output exit_code=0
    output=$(validate_policy_file "$policy_file" 2>&1) || exit_code=$?

    assert_equals "1" "$exit_code" "Bad format returns 1"
    assert_contains "$output" "Invalid format" "Reports format error"

    log_test_pass "$test_name"
}

test_validate_policy_file_bad_priority() {
    local test_name="validate_policy_file: rejects non-integer priority"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)

    local policy_file="$env_root/bad_priority"
    echo "BASE_PRIORITY=high" > "$policy_file"

    local output exit_code=0
    output=$(validate_policy_file "$policy_file" 2>&1) || exit_code=$?

    assert_equals "1" "$exit_code" "Non-integer priority returns 1"
    assert_contains "$output" "must be an integer" "Reports integer error"

    log_test_pass "$test_name"
}

test_validate_policy_file_bad_boolean() {
    local test_name="validate_policy_file: rejects invalid boolean"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)

    local policy_file="$env_root/bad_bool"
    echo "REVIEW_ALLOW_PUSH=yes" > "$policy_file"

    local output exit_code=0
    output=$(validate_policy_file "$policy_file" 2>&1) || exit_code=$?

    assert_equals "1" "$exit_code" "Invalid boolean returns 1"
    assert_contains "$output" "must be true or false" "Reports boolean error"

    log_test_pass "$test_name"
}

test_validate_policy_file_bad_max_parallel() {
    local test_name="validate_policy_file: rejects zero max parallel"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)

    local policy_file="$env_root/bad_parallel"
    echo "MAX_PARALLEL_AGENTS=0" > "$policy_file"

    local output exit_code=0
    output=$(validate_policy_file "$policy_file" 2>&1) || exit_code=$?

    assert_equals "1" "$exit_code" "Zero parallel returns 1"
    assert_contains "$output" "must be a positive integer" "Reports positive integer error"

    log_test_pass "$test_name"
}

test_validate_policy_file_bad_label_boost() {
    local test_name="validate_policy_file: rejects malformed label boost"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)

    local policy_file="$env_root/bad_labels"
    echo "LABEL_PRIORITY_BOOST=security:high,bug:low" > "$policy_file"

    local output exit_code=0
    output=$(validate_policy_file "$policy_file" 2>&1) || exit_code=$?

    assert_equals "1" "$exit_code" "Malformed label boost returns 1"
    assert_contains "$output" "LABEL_PRIORITY_BOOST format" "Reports format error"

    log_test_pass "$test_name"
}

test_validate_policy_file_unknown_key() {
    local test_name="validate_policy_file: rejects unknown key"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)

    local policy_file="$env_root/unknown_key"
    echo "UNKNOWN_SETTING=value" > "$policy_file"

    local output exit_code=0
    output=$(validate_policy_file "$policy_file" 2>&1) || exit_code=$?

    assert_equals "1" "$exit_code" "Unknown key returns 1"
    assert_contains "$output" "Unknown policy key" "Reports unknown key"

    log_test_pass "$test_name"
}

test_validate_policy_file_negative_priority() {
    local test_name="validate_policy_file: accepts negative priority"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)

    local policy_file="$env_root/neg_priority"
    echo "BASE_PRIORITY=-3" > "$policy_file"

    local output
    output=$(validate_policy_file "$policy_file" 2>&1)
    local exit_code=$?

    assert_equals "0" "$exit_code" "Negative priority returns 0"
    assert_contains "$output" "Valid" "Accepts negative priority"

    log_test_pass "$test_name"
}

test_validate_policy_file_line_numbers() {
    local test_name="validate_policy_file: reports correct line numbers"
    log_test_start "$test_name"

    local env_root
    env_root=$(create_test_env)

    local policy_file="$env_root/multi_error"
    cat > "$policy_file" << 'EOF'
# Comment
BASE_PRIORITY=2
bad line here
REVIEW_ALLOW_PUSH=maybe
EOF

    local output exit_code=0
    output=$(validate_policy_file "$policy_file" 2>&1) || exit_code=$?

    assert_equals "1" "$exit_code" "Multiple errors returns 1"
    assert_contains "$output" "Line 3" "Reports line 3 error"
    assert_contains "$output" "Line 4" "Reports line 4 error"

    log_test_pass "$test_name"
}

#==============================================================================
# load_policy_for_repo
#==============================================================================

test_load_policy_defaults() {
    local test_name="load_policy_for_repo: returns defaults with no policies"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    mkdir -p "$(get_review_policy_dir)"

    local output
    output=$(load_policy_for_repo "owner/repo")
    local exit_code=$?

    assert_equals "0" "$exit_code" "Returns 0 with no policies"

    local base_priority
    base_priority=$(echo "$output" | jq -r '.base_priority')
    assert_equals "0" "$base_priority" "Default base_priority is 0"

    local allow_push
    allow_push=$(echo "$output" | jq -r '.allow_push')
    assert_equals "false" "$allow_push" "Default allow_push is false"

    local require_approval
    require_approval=$(echo "$output" | jq -r '.require_approval')
    assert_equals "true" "$require_approval" "Default require_approval is true"

    local max_parallel
    max_parallel=$(echo "$output" | jq -r '.max_parallel_agents')
    assert_equals "4" "$max_parallel" "Default max_parallel_agents is 4"

    log_test_pass "$test_name"
}

test_load_policy_from_default_file() {
    local test_name="load_policy_for_repo: loads _default file"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    local policy_dir
    policy_dir=$(get_review_policy_dir)
    mkdir -p "$policy_dir"

    cat > "$policy_dir/_default" << 'EOF'
BASE_PRIORITY=1
REVIEW_ALLOW_PUSH=true
MAX_PARALLEL_AGENTS=2
EOF

    local output
    output=$(load_policy_for_repo "any/repo")

    assert_equals "1" "$(echo "$output" | jq -r '.base_priority')" "Default file sets base_priority"
    assert_equals "true" "$(echo "$output" | jq -r '.allow_push')" "Default file sets allow_push"
    assert_equals "2" "$(echo "$output" | jq -r '.max_parallel_agents')" "Default file sets max_parallel"
    assert_contains "$output" "_default" "Reports _default in policies_loaded"

    log_test_pass "$test_name"
}

test_load_policy_exact_repo_match() {
    local test_name="load_policy_for_repo: exact repo overrides default"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    local policy_dir
    policy_dir=$(get_review_policy_dir)
    mkdir -p "$policy_dir"

    cat > "$policy_dir/_default" << 'EOF'
BASE_PRIORITY=1
REVIEW_ALLOW_PUSH=false
EOF

    cat > "$policy_dir/owner_repo" << 'EOF'
REVIEW_ALLOW_PUSH=true
MAX_PARALLEL_AGENTS=16
EOF

    local output
    output=$(load_policy_for_repo "owner/repo")

    assert_equals "1" "$(echo "$output" | jq -r '.base_priority')" "Inherits base_priority from _default"
    assert_equals "true" "$(echo "$output" | jq -r '.allow_push')" "Exact match overrides allow_push"
    assert_equals "16" "$(echo "$output" | jq -r '.max_parallel_agents')" "Exact match sets max_parallel"

    log_test_pass "$test_name"
}

test_load_policy_skips_example_files() {
    local test_name="load_policy_for_repo: skips .example files"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    local policy_dir
    policy_dir=$(get_review_policy_dir)
    mkdir -p "$policy_dir"

    cat > "$policy_dir/_default.example" << 'EOF'
BASE_PRIORITY=99
REVIEW_ALLOW_PUSH=true
EOF

    local output
    output=$(load_policy_for_repo "owner/repo")

    assert_equals "0" "$(echo "$output" | jq -r '.base_priority')" "Example file not loaded"
    assert_equals "false" "$(echo "$output" | jq -r '.allow_push')" "Example file not applied"

    log_test_pass "$test_name"
}

test_load_policy_strips_quotes() {
    local test_name="load_policy_for_repo: strips surrounding quotes from values"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    local policy_dir
    policy_dir=$(get_review_policy_dir)
    mkdir -p "$policy_dir"

    cat > "$policy_dir/_default" << 'EOF'
TEST_COMMAND="make test"
LINT_COMMAND='golangci-lint run'
EOF

    local output
    output=$(load_policy_for_repo "owner/repo")

    assert_equals "make test" "$(echo "$output" | jq -r '.test_command')" "Strips double quotes"
    assert_equals "golangci-lint run" "$(echo "$output" | jq -r '.lint_command')" "Strips single quotes"

    log_test_pass "$test_name"
}

test_load_policy_merge_order() {
    local test_name="load_policy_for_repo: merges _default then exact match"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    local policy_dir
    policy_dir=$(get_review_policy_dir)
    mkdir -p "$policy_dir"

    cat > "$policy_dir/_default" << 'EOF'
BASE_PRIORITY=1
REVIEW_ALLOW_PUSH=false
REVIEW_REQUIRE_APPROVAL=true
SKIP_PATTERNS=vendor/*
EOF

    cat > "$policy_dir/owner_repo" << 'EOF'
BASE_PRIORITY=3
REVIEW_ALLOW_PUSH=true
EOF

    local output
    output=$(load_policy_for_repo "owner/repo")

    # Overridden by exact match
    assert_equals "3" "$(echo "$output" | jq -r '.base_priority')" "Exact match overrides base_priority"
    assert_equals "true" "$(echo "$output" | jq -r '.allow_push')" "Exact match overrides allow_push"
    # Inherited from _default (not overridden)
    assert_equals "true" "$(echo "$output" | jq -r '.require_approval')" "Inherits require_approval"
    assert_equals "vendor/*" "$(echo "$output" | jq -r '.skip_patterns')" "Inherits skip_patterns"

    log_test_pass "$test_name"
}

test_load_policy_policies_loaded_list() {
    local test_name="load_policy_for_repo: reports loaded policies"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    local policy_dir
    policy_dir=$(get_review_policy_dir)
    mkdir -p "$policy_dir"

    echo "BASE_PRIORITY=0" > "$policy_dir/_default"
    echo "BASE_PRIORITY=1" > "$policy_dir/owner_repo"

    local output
    output=$(load_policy_for_repo "owner/repo")

    local loaded
    loaded=$(echo "$output" | jq -r '.policies_loaded | join(",")')
    assert_contains "$loaded" "_default" "Reports _default loaded"
    assert_contains "$loaded" "owner_repo" "Reports exact match loaded"

    log_test_pass "$test_name"
}

#==============================================================================
# get_policy_value
#==============================================================================

test_get_policy_value_found() {
    local test_name="get_policy_value: returns value when found"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    local policy_dir
    policy_dir=$(get_review_policy_dir)
    mkdir -p "$policy_dir"

    echo "BASE_PRIORITY=5" > "$policy_dir/_default"

    local value
    value=$(get_policy_value "any/repo" "base_priority")
    local exit_code=$?

    assert_equals "0" "$exit_code" "Returns 0 for found key"
    assert_equals "5" "$value" "Returns correct value"

    log_test_pass "$test_name"
}

test_get_policy_value_not_found() {
    local test_name="get_policy_value: returns 1 for missing key"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    local policy_dir
    policy_dir=$(get_review_policy_dir)
    mkdir -p "$policy_dir"

    echo "BASE_PRIORITY=0" > "$policy_dir/_default"

    local value exit_code=0
    value=$(get_policy_value "any/repo" "nonexistent_key") || exit_code=$?

    assert_equals "1" "$exit_code" "Returns 1 for missing key"

    log_test_pass "$test_name"
}

test_get_policy_value_boolean() {
    local test_name="get_policy_value: returns boolean values correctly"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    local policy_dir
    policy_dir=$(get_review_policy_dir)
    mkdir -p "$policy_dir"

    echo "REVIEW_ALLOW_PUSH=true" > "$policy_dir/_default"

    local value
    value=$(get_policy_value "any/repo" "allow_push")

    assert_equals "true" "$value" "Returns boolean value"

    log_test_pass "$test_name"
}

#==============================================================================
# repo_allows_push
#==============================================================================

test_repo_allows_push_true() {
    local test_name="repo_allows_push: returns 0 when push allowed"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    local policy_dir
    policy_dir=$(get_review_policy_dir)
    mkdir -p "$policy_dir"

    echo "REVIEW_ALLOW_PUSH=true" > "$policy_dir/_default"

    repo_allows_push "any/repo"
    local exit_code=$?

    assert_equals "0" "$exit_code" "Returns 0 when push is allowed"

    log_test_pass "$test_name"
}

test_repo_allows_push_false() {
    local test_name="repo_allows_push: returns 1 when push denied"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    local policy_dir
    policy_dir=$(get_review_policy_dir)
    mkdir -p "$policy_dir"

    echo "REVIEW_ALLOW_PUSH=false" > "$policy_dir/_default"

    local exit_code=0
    repo_allows_push "any/repo" || exit_code=$?

    assert_equals "1" "$exit_code" "Returns 1 when push is denied"

    log_test_pass "$test_name"
}

test_repo_allows_push_default() {
    local test_name="repo_allows_push: defaults to deny (no policy)"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    mkdir -p "$(get_review_policy_dir)"

    local exit_code=0
    repo_allows_push "any/repo" || exit_code=$?

    assert_equals "1" "$exit_code" "Defaults to deny push"

    log_test_pass "$test_name"
}

#==============================================================================
# repo_requires_approval
#==============================================================================

test_repo_requires_approval_true() {
    local test_name="repo_requires_approval: returns 0 when approval required"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    local policy_dir
    policy_dir=$(get_review_policy_dir)
    mkdir -p "$policy_dir"

    echo "REVIEW_REQUIRE_APPROVAL=true" > "$policy_dir/_default"

    repo_requires_approval "any/repo"
    local exit_code=$?

    assert_equals "0" "$exit_code" "Returns 0 when approval required"

    log_test_pass "$test_name"
}

test_repo_requires_approval_false() {
    local test_name="repo_requires_approval: returns 1 when no approval"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    local policy_dir
    policy_dir=$(get_review_policy_dir)
    mkdir -p "$policy_dir"

    echo "REVIEW_REQUIRE_APPROVAL=false" > "$policy_dir/_default"

    local exit_code=0
    repo_requires_approval "any/repo" || exit_code=$?

    assert_equals "1" "$exit_code" "Returns 1 when approval not required"

    log_test_pass "$test_name"
}

test_repo_requires_approval_default() {
    local test_name="repo_requires_approval: defaults to require approval"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    mkdir -p "$(get_review_policy_dir)"

    repo_requires_approval "any/repo"
    local exit_code=$?

    assert_equals "0" "$exit_code" "Defaults to require approval"

    log_test_pass "$test_name"
}

#==============================================================================
# apply_policy_priority_boost
#==============================================================================

test_apply_priority_boost_no_policy() {
    local test_name="apply_policy_priority_boost: no change without policy"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    mkdir -p "$(get_review_policy_dir)"

    local result
    result=$(apply_policy_priority_boost "any/repo" 2)

    assert_equals "2" "$result" "Priority unchanged with no policy"

    log_test_pass "$test_name"
}

test_apply_priority_boost_base_boost() {
    local test_name="apply_policy_priority_boost: applies base boost"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    local policy_dir
    policy_dir=$(get_review_policy_dir)
    mkdir -p "$policy_dir"

    echo "BASE_PRIORITY=1" > "$policy_dir/_default"

    local result
    result=$(apply_policy_priority_boost "any/repo" 3)

    # new_priority = current(3) - boost(1) = 2 (lower number = higher priority)
    assert_equals "2" "$result" "Base boost reduces priority number"

    log_test_pass "$test_name"
}

test_apply_priority_boost_label_boost() {
    local test_name="apply_policy_priority_boost: applies label boost"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    local policy_dir
    policy_dir=$(get_review_policy_dir)
    mkdir -p "$policy_dir"

    echo "LABEL_PRIORITY_BOOST=security=2,bug=1" > "$policy_dir/_default"

    local result
    result=$(apply_policy_priority_boost "any/repo" 3 "security")

    # new_priority = current(3) - (base:0 + security:2) = 1
    assert_equals "1" "$result" "Security label boosts priority"

    log_test_pass "$test_name"
}

test_apply_priority_boost_multiple_labels() {
    local test_name="apply_policy_priority_boost: applies multiple label boosts"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    local policy_dir
    policy_dir=$(get_review_policy_dir)
    mkdir -p "$policy_dir"

    echo "LABEL_PRIORITY_BOOST=security=2,bug=1" > "$policy_dir/_default"

    local result
    result=$(apply_policy_priority_boost "any/repo" 4 "security,bug")

    # new_priority = current(4) - (base:0 + security:2 + bug:1) = 1
    assert_equals "1" "$result" "Multiple labels stack boosts"

    log_test_pass "$test_name"
}

test_apply_priority_boost_clamps_to_zero() {
    local test_name="apply_policy_priority_boost: clamps to 0 minimum"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    local policy_dir
    policy_dir=$(get_review_policy_dir)
    mkdir -p "$policy_dir"

    echo "BASE_PRIORITY=10" > "$policy_dir/_default"

    local result
    result=$(apply_policy_priority_boost "any/repo" 2)

    # new_priority = current(2) - boost(10) = -8, clamped to 0
    assert_equals "0" "$result" "Priority clamped to 0"

    log_test_pass "$test_name"
}

test_apply_priority_boost_clamps_to_four() {
    local test_name="apply_policy_priority_boost: clamps to 4 maximum"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    local policy_dir
    policy_dir=$(get_review_policy_dir)
    mkdir -p "$policy_dir"

    echo "BASE_PRIORITY=-10" > "$policy_dir/_default"

    local result
    result=$(apply_policy_priority_boost "any/repo" 2)

    # new_priority = current(2) - boost(-10) = 12, clamped to 4
    assert_equals "4" "$result" "Priority clamped to 4"

    log_test_pass "$test_name"
}

test_apply_priority_boost_negative_label() {
    local test_name="apply_policy_priority_boost: negative label boost lowers priority"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    local policy_dir
    policy_dir=$(get_review_policy_dir)
    mkdir -p "$policy_dir"

    echo "LABEL_PRIORITY_BOOST=documentation=-1" > "$policy_dir/_default"

    local result
    result=$(apply_policy_priority_boost "any/repo" 2 "documentation")

    # new_priority = current(2) - (base:0 + documentation:-1) = 3
    assert_equals "3" "$result" "Negative label boost increases priority number"

    log_test_pass "$test_name"
}

test_apply_priority_boost_no_matching_labels() {
    local test_name="apply_policy_priority_boost: ignores non-matching labels"
    log_test_start "$test_name"

    require_jq_or_skip || return 0

    local env_root
    env_root=$(create_test_env)
    export RU_CONFIG_DIR="$env_root/config/ru"
    local policy_dir
    policy_dir=$(get_review_policy_dir)
    mkdir -p "$policy_dir"

    echo "LABEL_PRIORITY_BOOST=security=2,bug=1" > "$policy_dir/_default"

    local result
    result=$(apply_policy_priority_boost "any/repo" 2 "enhancement,wontfix")

    # No matching labels, so just base boost (0)
    assert_equals "2" "$result" "Non-matching labels have no effect"

    log_test_pass "$test_name"
}

#==============================================================================
# Run Tests
#==============================================================================

run_test test_get_review_policy_dir_uses_config_dir

run_test test_init_review_policies_creates_dir
run_test test_init_review_policies_idempotent
run_test test_init_review_policies_quiet_mode

run_test test_validate_policy_file_valid
run_test test_validate_policy_file_empty
run_test test_validate_policy_file_missing
run_test test_validate_policy_file_bad_format
run_test test_validate_policy_file_bad_priority
run_test test_validate_policy_file_bad_boolean
run_test test_validate_policy_file_bad_max_parallel
run_test test_validate_policy_file_bad_label_boost
run_test test_validate_policy_file_unknown_key
run_test test_validate_policy_file_negative_priority
run_test test_validate_policy_file_line_numbers

run_test test_load_policy_defaults
run_test test_load_policy_from_default_file
run_test test_load_policy_exact_repo_match
run_test test_load_policy_skips_example_files
run_test test_load_policy_strips_quotes
run_test test_load_policy_merge_order
run_test test_load_policy_policies_loaded_list

run_test test_get_policy_value_found
run_test test_get_policy_value_not_found
run_test test_get_policy_value_boolean

run_test test_repo_allows_push_true
run_test test_repo_allows_push_false
run_test test_repo_allows_push_default

run_test test_repo_requires_approval_true
run_test test_repo_requires_approval_false
run_test test_repo_requires_approval_default

run_test test_apply_priority_boost_no_policy
run_test test_apply_priority_boost_base_boost
run_test test_apply_priority_boost_label_boost
run_test test_apply_priority_boost_multiple_labels
run_test test_apply_priority_boost_clamps_to_zero
run_test test_apply_priority_boost_clamps_to_four
run_test test_apply_priority_boost_negative_label
run_test test_apply_priority_boost_no_matching_labels

print_results
exit "$(get_exit_code)"
