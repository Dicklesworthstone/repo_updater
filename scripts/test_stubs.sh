#!/usr/bin/env bash
# Test stubs for unit testing ru functions in isolation
# This file provides mock implementations of logging and utility functions.

# Logging stubs - suppress output
log_warn() { :; }
log_debug() { :; }
log_error() { :; }

# JSON escape function (simplified for testing)
json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    printf '%s' "$str"
}

# Deduplication helper
dedupe_repos() {
    awk '!seen[$0]++'
}

# Path validation stub
_is_safe_path_segment() {
    local segment="$1"
    [[ -n "$segment" ]] || return 1
    [[ "$segment" != "." && "$segment" != ".." ]] || return 1
    [[ "$segment" != */* ]] || return 1
    return 0
}

# Output variable setter
_set_out_var() {
    local varname="$1"
    local value="$2"
    [[ -z "$varname" ]] && return 0
    printf -v "$varname" '%s' "$value"
}
