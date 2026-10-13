# PLAN: Create repo_updater (ru) - A State-of-the-Art Repository Synchronization Tool

## Executive Summary

**ru** (repo_updater) is a robust, automation-friendly CLI tool that synchronizes a collection of GitHub repositories to a local projects directory. Modeled after the [giil](https://github.com/Dicklesworthstone/get_icloud_image_link) project architecture, it features:

- **One-liner curl-bash installation** with checksum verification by default
- **XDG-compliant configuration** with `ru init` for first-run setup
- **Automatic `gh` CLI detection** with prompted (not automatic) installation
- **Beautiful gum-powered terminal UI** with intelligent ANSI fallbacks
- **Intelligent clone/pull logic** using git plumbing (not string parsing)
- **Automation-grade design**: meaningful exit codes, non-interactive mode, JSON output
- **Subcommand architecture**: `sync`, `status`, `init`, `add`, `doctor`

---

## Table of Contents

1. [Project Structure](#1-project-structure)
2. [Critical Design Decisions](#2-critical-design-decisions)
3. [Core Script Architecture (ru)](#3-core-script-architecture-ru)
4. [Subcommand Design](#4-subcommand-design)
5. [Configuration System (XDG-Compliant)](#5-configuration-system-xdg-compliant)
6. [GitHub CLI Integration](#6-github-cli-integration)
7. [Repository Processing Logic](#7-repository-processing-logic)
8. [Error Handling & Safety](#8-error-handling--safety)
9. [Output & Logging Design](#9-output--logging-design)
10. [Installation Script (install.sh)](#10-installation-script-installsh)
11. [Gum Integration & Visual Design](#11-gum-integration--visual-design)
12. [README.md Structure](#12-readmemd-structure)
13. [CI/CD Workflows](#13-cicd-workflows)
14. [Implementation Steps (Granular)](#14-implementation-steps-granular)
15. [Future Enhancements (v2)](#15-future-enhancements-v2)

---

## 1. Project Structure

```
repo_updater/
├── ru                                    # Main script (~800-1000 LOC)
├── install.sh                            # Curl-bash installer (~250 LOC)
├── README.md                             # Comprehensive documentation
├── VERSION                               # Semver version file (e.g., "1.0.0")
├── LICENSE                               # MIT License
├── .gitignore                            # Ignore runtime artifacts
├── .github/
│   └── workflows/
│       ├── ci.yml                        # ShellCheck, syntax, behavioral tests
│       └── release.yml                   # GitHub releases with checksums
├── scripts/
│   ├── test_local_git.sh                 # Integration tests with local git repos
│   ├── test_parsing.sh                   # URL parsing tests
│   └── test_json_output.sh               # JSON schema validation
└── examples/
    ├── public.txt                        # Example public repos list
    └── private.template.txt              # Empty template for private repos
```

**Critical change from v1:** No `je_*.txt` files in repo. Those are examples only. User's actual lists live in XDG config.

---

## 2. Critical Design Decisions

### 2.1 The Packaging Problem (FIXED)

**Problem:** Original plan had default lists pointing to repo-local files that won't exist after install.

**Solution:** XDG-compliant configuration:
```
~/.config/ru/
├── config                    # Key-value configuration
└── repos.d/
    ├── public.txt            # User's public repos
    └── private.txt           # User's private repos (optional)
```

On first run (or `ru init`), create these directories and files.

### 2.2 Path Layout Strategy

**Problem:** `org1/repo` and `org2/repo` would collide with flat layout.

**Solution:** Configurable layout with **flat as default** (for backwards compatibility with user's existing `/data/projects` structure):

| Layout | Path | Use Case |
|--------|------|----------|
| `flat` (default) | `$PROJECTS_DIR/repo` | Simple, matches existing setup |
| `owner-repo` | `$PROJECTS_DIR/owner/repo` | Avoids most collisions |
| `full` | `$PROJECTS_DIR/github.com/owner/repo` | Multi-host, enterprise |

**Collision detection:** Warn if multiple repos would map to same path.

### 2.3 The `set -e` Trap (FIXED)

**Problem:** `output=$(failing_cmd); exit_code=$?` exits script before capturing exit code.

**Solution:** Always use:
```bash
if output=$(git pull --ff-only 2>&1); then
    # success
else
    exit_code=$?
    # failure - continue processing
fi
```

### 2.4 No String Parsing for Git Status

**Problem:** Parsing "Already up to date" varies by git version and locale.

**Solution:** Use git plumbing:
```bash
# Get ahead/behind counts deterministically
read -r ahead behind < <(git rev-list --left-right --count HEAD...@{u} 2>/dev/null)
```

### 2.5 Output Stream Separation

**Problem:** Human logs on stdout break JSON parsers.

**Solution:**
- **stderr**: All human-readable output (progress, errors, summary)
- **stdout**: Only structured output (JSON in `--json` mode, paths otherwise)

### 2.6 No Auto-Install by Default

**Problem:** Automatically installing system packages is invasive.

**Solution:**
- Detect missing dependencies and explain
- Interactive mode: prompt "Install now? (y/N)"
- Non-interactive mode: fail with instructions
- Opt-in: `--install-deps` or `RU_INSTALL_DEPS=1`

### 2.7 Installer Security

**Problem:** Installing from `main` branch is mutable and unverified.

**Solution:**
- Default: Download from GitHub Release with checksum verification
- Fallback to `main` only with explicit `RU_UNSAFE_MAIN=1`

---

## 3. Core Script Architecture (ru)

### 3.1 Header & Metadata

```bash
#!/usr/bin/env bash
#
# ru - Repo Updater
# Synchronizes GitHub repositories to your local projects directory
#
# FEATURES:
#   - Subcommand architecture (sync, status, init, add, doctor)
#   - XDG-compliant configuration
#   - Prompted gh CLI installation (not automatic)
#   - Non-interactive mode for CI/automation
#   - Meaningful exit codes
#   - JSON output mode (stdout only)
#   - Git plumbing for status detection (no string parsing)
#   - Beautiful gum-powered output with ANSI fallbacks
#
# Usage:
#   ru [command] [options]
#
# Commands:
#   sync      Synchronize repositories (default if no command)
#   status    Show repository status without changes
#   init      Initialize configuration
#   add       Add repository to list
#   list      List configured repositories
#   doctor    Check system configuration
#   self-update  Update ru to latest version
#
# Global Options:
#   --help, -h       Show help message
#   --version, -v    Show version
#   --json           Output JSON (stdout only)
#   --quiet, -q      Minimal output (errors only)
#   --verbose        Detailed output
#   --non-interactive  Never prompt (for CI)
#
```

### 3.2 Constants & Defaults

```bash
set -uo pipefail
# NOTE: Not using `set -e` globally - we handle errors explicitly
# to ensure processing continues after individual repo failures

VERSION="1.0.0"

# Repository info
REPO_OWNER="Dicklesworthstone"
REPO_NAME="repo_updater"

# XDG-compliant paths
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"

RU_CONFIG_DIR="${RU_CONFIG_DIR:-$XDG_CONFIG_HOME/ru}"
RU_DATA_DIR="${RU_DATA_DIR:-$XDG_DATA_HOME/ru}"
RU_CACHE_DIR="${RU_CACHE_DIR:-$XDG_CACHE_HOME/ru}"
RU_STATE_DIR="${RU_STATE_DIR:-$XDG_STATE_HOME/ru}"
RU_LOG_DIR="${RU_LOG_DIR:-$RU_STATE_DIR/logs}"

# Default configuration
DEFAULT_PROJECTS_DIR="/data/projects"
DEFAULT_LAYOUT="flat"  # flat | owner-repo | full
DEFAULT_UPDATE_STRATEGY="ff-only"  # ff-only | rebase | merge

# ANSI Colors (fallback when gum not available)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Runtime state
GUM_AVAILABLE=false
INTERACTIVE=true
JSON_MODE=false
QUIET_MODE=false
VERBOSE_MODE=false
DRY_RUN=false

# Result tracking (NDJSON lines written to temp file)
RESULTS_FILE=""
RUN_START_TIME=""
```

### 3.3 Function Organization

```
┌─────────────────────────────────────────────────────────────────┐
│  SECTION 1: Core Utilities                                       │
├─────────────────────────────────────────────────────────────────┤
│  • is_interactive()           - Check if TTY available           │
│  • can_prompt()               - Check if prompting is allowed    │
│  • get_timestamp()            - ISO 8601 timestamp               │
│  • ensure_dir()               - Create directory if missing      │
│  • write_result()             - Append NDJSON result record      │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  SECTION 2: Configuration                                        │
├─────────────────────────────────────────────────────────────────┤
│  • get_config_value()         - Read from config file            │
│  • set_config_value()         - Write to config file             │
│  • resolve_config()           - Merge CLI > env > file > default │
│  • print_config()             - Show resolved configuration      │
│  • ensure_config_exists()     - Create default config if missing │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  SECTION 3: Logging (stderr for humans, stdout for data)         │
├─────────────────────────────────────────────────────────────────┤
│  • log_info()                 - Info messages (stderr)           │
│  • log_warn()                 - Warning messages (stderr)        │
│  • log_error()                - Error messages (stderr)          │
│  • log_step()                 - Step indicator (stderr)          │
│  • log_success()              - Success with checkmark (stderr)  │
│  • log_debug()                - Debug messages if verbose        │
│  • output_json()              - JSON output (stdout only)        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  SECTION 4: Gum Integration                                      │
├─────────────────────────────────────────────────────────────────┤
│  • check_gum()                - Detect gum availability          │
│  • prompt_install_gum()       - Ask user to install gum          │
│  • print_banner()             - Styled header display            │
│  • gum_confirm()              - Yes/no prompt with fallback      │
│  • gum_spin()                 - Spinner with fallback            │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  SECTION 5: Dependency Management                                │
├─────────────────────────────────────────────────────────────────┤
│  • detect_os()                - macOS/Linux detection            │
│  • check_gh_installed()       - Is gh in PATH?                   │
│  • check_gh_authenticated()   - Is gh logged in?                 │
│  • prompt_install_gh()        - Offer to install gh              │
│  • prompt_gh_auth()           - Run gh auth login                │
│  • ensure_dependencies()      - Full dependency check flow       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  SECTION 6: URL & Path Parsing                                   │
├─────────────────────────────────────────────────────────────────┤
│  • parse_repo_url()           - Extract host/owner/repo          │
│  • normalize_url()            - Canonical HTTPS form             │
│  • url_to_local_path()        - URL → local path (layout-aware)  │
│  • url_to_clone_target()      - URL → owner/repo for gh          │
│  • sanitize_path_segment()    - Remove unsafe characters         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  SECTION 7: Git Operations (using git -C, no global cd)          │
├─────────────────────────────────────────────────────────────────┤
│  • is_git_repo()              - Check .git exists                │
│  • get_repo_status()          - Plumbing-based status detection  │
│  • get_remote_url()           - Current origin URL               │
│  • check_remote_mismatch()    - Verify origin matches expected   │
│  • do_clone()                 - Clone with error handling        │
│  • do_pull()                  - Pull with strategy support       │
│  • do_fetch()                 - Fetch only (for status)          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  SECTION 8: Repo List Management                                 │
├─────────────────────────────────────────────────────────────────┤
│  • load_repo_list()           - Parse list file (skip comments)  │
│  • parse_repo_spec()          - Handle repo@branch syntax        │
│  • dedupe_repos()             - Remove duplicates by path        │
│  • detect_collisions()        - Warn about path collisions       │
│  • get_all_repos()            - Load and merge all lists         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  SECTION 9: Subcommand Implementations                           │
├─────────────────────────────────────────────────────────────────┤
│  • cmd_sync()                 - Main sync logic                  │
│  • cmd_status()               - Read-only status check           │
│  • cmd_init()                 - Initialize configuration         │
│  • cmd_add()                  - Add repo to list                 │
│  • cmd_list()                 - Show configured repos            │
│  • cmd_doctor()               - System diagnostics               │
│  • cmd_self_update()          - Update ru itself                 │
│  • cmd_config()               - Show/set configuration           │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  SECTION 10: Reporting & Summary                                 │
├─────────────────────────────────────────────────────────────────┤
│  • aggregate_results()        - Parse NDJSON results file        │
│  • print_summary()            - Human-readable summary (stderr)  │
│  • print_conflict_help()      - Actionable resolution commands   │
│  • generate_json_report()     - Final JSON output (stdout)       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  SECTION 11: Main & CLI Dispatch                                 │
├─────────────────────────────────────────────────────────────────┤
│  • show_help()                - Full help message                │
│  • show_version()             - Version display                  │
│  • parse_global_args()        - Global options                   │
│  • dispatch_command()         - Route to subcommand              │
│  • on_exit()                  - EXIT trap handler                │
│  • main()                     - Entry point                      │
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. Subcommand Design

### 4.1 Command Dispatch

```bash
dispatch_command() {
    local cmd="${1:-sync}"  # Default to sync
    shift || true

    case "$cmd" in
        sync)       cmd_sync "$@" ;;
        status)     cmd_status "$@" ;;
        init)       cmd_init "$@" ;;
        add)        cmd_add "$@" ;;
        list)       cmd_list "$@" ;;
        doctor)     cmd_doctor "$@" ;;
        self-update) cmd_self_update "$@" ;;
        config)     cmd_config "$@" ;;
        -h|--help)  show_help ;;
        -v|--version) show_version ;;
        *)
            # If it looks like a file or URL, treat as sync with args
            if [[ -f "$cmd" || "$cmd" =~ ^https?:// || "$cmd" =~ ^[a-zA-Z0-9_-]+/ ]]; then
                cmd_sync "$cmd" "$@"
            else
                log_error "Unknown command: $cmd"
                log_error "Run 'ru --help' for usage"
                exit 4  # Invalid arguments
            fi
            ;;
    esac
}
```

### 4.2 Subcommand Specifications

| Command | Purpose | Key Options |
|---------|---------|-------------|
| `sync` | Clone/pull repositories | `--clone-only`, `--pull-only`, `--autostash`, `--rebase`, `--dry-run` |
| `status` | Show repo status (read-only) | `--fetch` (default), `--no-fetch` |
| `init` | Create config directory & files | `--example` (include example repos) |
| `add` | Add repo to list | `--private`, `--from-cwd` |
| `list` | Show configured repos | `--public`, `--private`, `--paths` |
| `doctor` | System diagnostics | (none) |
| `self-update` | Update ru | `--check` (check only, don't update) |
| `config` | Show/set configuration | `--print`, `--set KEY=VALUE` |

---

## 5. Configuration System (XDG-Compliant)

### 5.1 Directory Structure

```
~/.config/ru/
├── config                    # Main configuration file
└── repos.d/
    ├── public.txt            # Public repositories
    └── private.txt           # Private repositories (gitignored locally)

~/.cache/ru/
└── (runtime cache)

~/.local/state/ru/
├── logs/
│   ├── 2026-01-03/
│   │   ├── run.log           # Main run log
│   │   └── repos/
│   │       ├── github.com_owner_repo1.log
│   │       └── github.com_owner_repo2.log
│   └── latest -> 2026-01-03  # Symlink to latest run
└── archived/                 # Orphan repos moved here by `ru prune`
```

### 5.2 Config File Format

```bash
# ~/.config/ru/config
# Configuration for ru (Repo Updater)

# Base directory for repositories
PROJECTS_DIR=/data/projects

# Directory layout: flat | owner-repo | full
LAYOUT=flat

# Update strategy: ff-only | rebase | merge
UPDATE_STRATEGY=ff-only

# Auto-stash local changes before pull
AUTOSTASH=false

# Parallel operations (1 = serial)
PARALLEL=1

# Check for ru updates on run
CHECK_UPDATES=false
```

### 5.3 Configuration Resolution Order

```
Priority (highest to lowest):
1. Command-line arguments (--dir, --layout, etc.)
2. Environment variables (RU_PROJECTS_DIR, RU_LAYOUT, etc.)
3. Config file (~/.config/ru/config)
4. Built-in defaults
```

### 5.4 Repo List File Format

```bash
# ~/.config/ru/repos.d/public.txt
# Lines starting with # are comments
# Empty lines are ignored

# Simple URL
https://github.com/owner/repo

# Shorthand (requires github.com context)
owner/repo

# Pin to branch
owner/repo@develop

# Custom local directory name (relative to PROJECTS_DIR)
owner/repo as custom-name

# Future: tags for filtering
# owner/repo #tag=backend
```

---

## 6. GitHub CLI Integration

### 6.1 Dependency Check Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                     ensure_dependencies()                        │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │ check_gh_installed │
                    └────────┬────────┘
                             │
                    ┌────────┴────────┐
                    │                 │
                 Installed        Missing
                    │                 │
                    │                 ▼
                    │        ┌─────────────────┐
                    │        │ can_prompt()?   │
                    │        └────────┬────────┘
                    │                 │
                    │        ┌────────┴────────┐
                    │        │                 │
                    │       Yes               No
                    │        │                 │
                    │        ▼                 ▼
                    │ ┌───────────────┐ ┌───────────────┐
                    │ │prompt_install_│ │ Error: gh     │
                    │ │gh() with user │ │ required.     │
                    │ │confirmation   │ │ Exit code 3   │
                    │ └───────┬───────┘ └───────────────┘
                    │         │
                    │ ┌───────┴───────┐
                    │ │               │
                    │ Yes            No
                    │ │               │
                    │ ▼               ▼
                    │ ┌───────────┐ ┌───────────────┐
                    │ │Install gh │ │ Exit with     │
                    │ │           │ │ instructions  │
                    │ └─────┬─────┘ └───────────────┘
                    │       │
                    └───────┴──────────┐
                                       │
                                       ▼
                              ┌─────────────────┐
                              │check_gh_authed()│
                              └────────┬────────┘
                                       │
                              ┌────────┴────────┐
                              │                 │
                           Authed          Not Authed
                              │                 │
                              │                 ▼
                              │        ┌─────────────────┐
                              │        │ can_prompt()?   │
                              │        └────────┬────────┘
                              │                 │
                              │        ┌────────┴────────┐
                              │        │                 │
                              │       Yes               No
                              │        │                 │
                              │        ▼                 ▼
                              │ ┌───────────────┐ ┌────────────────┐
                              │ │prompt_gh_auth │ │Error: gh auth  │
                              │ │(interactive)  │ │required. Use   │
                              │ └───────┬───────┘ │GH_TOKEN or run │
                              │         │         │gh auth login   │
                              │         │         └────────────────┘
                              │         │
                              └─────────┴──────────┐
                                                   │
                                                   ▼
                                          ┌─────────────────┐
                                          │   Ready to      │
                                          │   proceed       │
                                          └─────────────────┘
```

### 6.2 gh Installation (Prompted, Not Automatic)

```bash
prompt_install_gh() {
    if ! can_prompt; then
        log_error "GitHub CLI (gh) is required but not installed."
        log_error "Install it manually: https://cli.github.com/"
        log_error "Or run with --install-deps to auto-install."
        return 1
    fi

    log_warn "GitHub CLI (gh) is not installed."

    local install_cmd=""
    case "$(detect_os)" in
        macos)
            if command -v brew &>/dev/null; then
                install_cmd="brew install gh"
            fi
            ;;
        linux)
            if command -v apt-get &>/dev/null; then
                install_cmd="(instructions for apt)"
            elif command -v dnf &>/dev/null; then
                install_cmd="sudo dnf install gh"
            fi
            ;;
    esac

    if [[ -n "$install_cmd" ]]; then
        if gum_confirm "Install GitHub CLI now?"; then
            log_step "Installing gh..."
            # Execute install
        else
            log_error "gh is required. Please install manually."
            return 1
        fi
    fi
}
```

---

## 7. Repository Processing Logic

### 7.1 URL Parsing (Robust)

```bash
parse_repo_url() {
    local url="$1"
    local -n _host=$2
    local -n _owner=$3
    local -n _repo=$4

    # Handle various formats:
    # https://github.com/owner/repo
    # https://github.com/owner/repo.git
    # git@github.com:owner/repo.git
    # github.com/owner/repo
    # owner/repo (assumes github.com)

    # Normalize: strip .git suffix
    url="${url%.git}"

    # Extract components
    if [[ "$url" =~ ^git@([^:]+):(.+)/(.+)$ ]]; then
        _host="${BASH_REMATCH[1]}"
        _owner="${BASH_REMATCH[2]}"
        _repo="${BASH_REMATCH[3]}"
    elif [[ "$url" =~ ^https?://([^/]+)/([^/]+)/([^/]+)$ ]]; then
        _host="${BASH_REMATCH[1]}"
        _owner="${BASH_REMATCH[2]}"
        _repo="${BASH_REMATCH[3]}"
    elif [[ "$url" =~ ^([^/]+)/([^/]+)/([^/]+)$ ]]; then
        _host="${BASH_REMATCH[1]}"
        _owner="${BASH_REMATCH[2]}"
        _repo="${BASH_REMATCH[3]}"
    elif [[ "$url" =~ ^([^/]+)/([^/]+)$ ]]; then
        _host="github.com"
        _owner="${BASH_REMATCH[1]}"
        _repo="${BASH_REMATCH[2]}"
    else
        return 1
    fi
}

url_to_local_path() {
    local url="$1"
    local projects_dir="$2"
    local layout="$3"

    local host owner repo
    parse_repo_url "$url" host owner repo || return 1

    case "$layout" in
        flat)
            echo "${projects_dir}/${repo}"
            ;;
        owner-repo)
            echo "${projects_dir}/${owner}/${repo}"
            ;;
        full)
            echo "${projects_dir}/${host}/${owner}/${repo}"
            ;;
    esac
}
```

### 7.2 Git Status Detection (Plumbing-Based)

```bash
get_repo_status() {
    local repo_path="$1"
    local do_fetch="${2:-false}"

    # Returns structured status:
    # STATUS=<status> AHEAD=<n> BEHIND=<n> DIRTY=<bool> BRANCH=<name>

    if [[ ! -d "$repo_path/.git" ]]; then
        echo "STATUS=not_git AHEAD=0 BEHIND=0 DIRTY=false BRANCH="
        return
    fi

    # Fetch if requested (for accurate ahead/behind)
    if [[ "$do_fetch" == "true" ]]; then
        git -C "$repo_path" fetch --quiet 2>/dev/null || true
    fi

    # Check for uncommitted changes
    local dirty="false"
    if [[ -n $(git -C "$repo_path" status --porcelain 2>/dev/null) ]]; then
        dirty="true"
    fi

    # Get current branch
    local branch
    branch=$(git -C "$repo_path" symbolic-ref --short HEAD 2>/dev/null || echo "")

    # Check if we have an upstream
    if ! git -C "$repo_path" rev-parse --verify '@{u}' &>/dev/null; then
        echo "STATUS=no_upstream AHEAD=0 BEHIND=0 DIRTY=$dirty BRANCH=$branch"
        return
    fi

    # Get ahead/behind counts using plumbing
    local ahead=0 behind=0
    read -r ahead behind < <(git -C "$repo_path" rev-list --left-right --count HEAD...@{u} 2>/dev/null || echo "0 0")

    # Determine status
    local status
    if [[ "$ahead" -eq 0 && "$behind" -eq 0 ]]; then
        status="current"
    elif [[ "$ahead" -eq 0 && "$behind" -gt 0 ]]; then
        status="behind"
    elif [[ "$ahead" -gt 0 && "$behind" -eq 0 ]]; then
        status="ahead"
    else
        status="diverged"
    fi

    echo "STATUS=$status AHEAD=$ahead BEHIND=$behind DIRTY=$dirty BRANCH=$branch"
}
```

### 7.3 Remote Mismatch Detection

```bash
check_remote_mismatch() {
    local repo_path="$1"
    local expected_url="$2"

    local actual_url
    actual_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null || echo "")

    # Normalize both URLs for comparison
    local norm_expected norm_actual
    norm_expected=$(normalize_url "$expected_url")
    norm_actual=$(normalize_url "$actual_url")

    if [[ "$norm_expected" != "$norm_actual" ]]; then
        echo "mismatch:expected=$norm_expected:actual=$norm_actual"
        return 1
    fi
    return 0
}

normalize_url() {
    local url="$1"
    # Convert SSH to HTTPS, strip .git, lowercase host
    url="${url%.git}"
    url="${url/git@github.com:/https://github.com/}"
    echo "$url" | tr '[:upper:]' '[:lower:]'
}
```

### 7.4 Clone Operation (No cd, Proper Error Handling)

```bash
do_clone() {
    local url="$1"
    local target_dir="$2"
    local repo_name="$3"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would clone: $url → $target_dir"
        write_result "$repo_name" "clone" "dry_run" "" ""
        return 0
    fi

    local clone_target
    clone_target=$(url_to_clone_target "$url")

    local output
    local start_time
    start_time=$(date +%s)

    # Create parent directory if needed
    mkdir -p "$(dirname "$target_dir")"

    if output=$(gh repo clone "$clone_target" "$target_dir" -- --quiet 2>&1); then
        local duration=$(($(date +%s) - start_time))
        log_success "Cloned: $repo_name (${duration}s)"
        write_result "$repo_name" "clone" "ok" "$duration" ""
        return 0
    else
        local exit_code=$?
        log_error "Failed to clone: $repo_name"
        log_error "  $output"
        write_result "$repo_name" "clone" "failed" "" "$output"
        return $exit_code
    fi
}
```

### 7.5 Pull Operation (Strategy-Aware)

```bash
do_pull() {
    local repo_path="$1"
    local repo_name="$2"
    local strategy="${3:-ff-only}"
    local autostash="${4:-false}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would pull: $repo_name (strategy: $strategy)"
        write_result "$repo_name" "pull" "dry_run" "" ""
        return 0
    fi

    local output
    local start_time
    start_time=$(date +%s)

    # Build pull command
    local pull_args=()
    case "$strategy" in
        ff-only) pull_args+=(--ff-only) ;;
        rebase)  pull_args+=(--rebase) ;;
        merge)   pull_args+=(--no-ff) ;;
    esac

    if [[ "$autostash" == "true" ]]; then
        pull_args+=(--autostash)
    fi

    # Execute pull (no cd - use git -C)
    if output=$(git -C "$repo_path" pull "${pull_args[@]}" 2>&1); then
        local duration=$(($(date +%s) - start_time))

        # Check what happened using rev comparison, not string matching
        local new_head old_head
        old_head=$(git -C "$repo_path" rev-parse 'HEAD@{1}' 2>/dev/null || echo "")
        new_head=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || echo "")

        if [[ "$old_head" == "$new_head" ]]; then
            log_info "Already current: $repo_name"
            write_result "$repo_name" "pull" "current" "$duration" ""
        else
            log_success "Pulled: $repo_name (${duration}s)"
            write_result "$repo_name" "pull" "updated" "$duration" ""
        fi
        return 0
    else
        local exit_code=$?
        local reason="failed"

        # Categorize failure
        if [[ "$output" =~ (divergent|cannot\ be\ fast-forwarded) ]]; then
            reason="diverged"
            log_warn "Diverged: $repo_name (needs manual merge or --rebase)"
        elif [[ "$output" =~ (conflict|CONFLICT) ]]; then
            reason="conflict"
            log_error "Merge conflict: $repo_name"
        else
            log_error "Pull failed: $repo_name"
        fi

        write_result "$repo_name" "pull" "$reason" "" "$output"
        return $exit_code
    fi
}
```

---

## 8. Error Handling & Safety

### 8.1 Exit Codes

| Code | Meaning | When |
|------|---------|------|
| `0` | Success | All repos synced or already current |
| `1` | Partial failure | Some repos failed (network/auth) |
| `2` | Conflicts exist | Some repos have conflicts needing resolution |
| `3` | Dependency error | gh missing, auth failed, etc. |
| `4` | Invalid arguments | Bad CLI options, missing files |

```bash
compute_exit_code() {
    local failed_count="$1"
    local conflict_count="$2"

    if [[ "$failed_count" -gt 0 ]]; then
        return 1
    elif [[ "$conflict_count" -gt 0 ]]; then
        return 2
    else
        return 0
    fi
}
```

### 8.2 EXIT Trap (Always Print Summary)

```bash
on_exit() {
    local exit_code=$?

    # Always try to print summary, even on error
    if [[ -n "$RESULTS_FILE" && -f "$RESULTS_FILE" ]]; then
        if [[ "$JSON_MODE" == "true" ]]; then
            generate_json_report
        else
            print_summary
        fi
    fi

    # Cleanup
    [[ -n "$RESULTS_FILE" ]] && rm -f "$RESULTS_FILE"

    exit $exit_code
}

trap on_exit EXIT
trap 'exit 130' INT TERM
```

### 8.3 Non-Interactive Mode

```bash
is_interactive() {
    [[ -t 0 && -t 1 ]]
}

can_prompt() {
    [[ "$INTERACTIVE" == "true" ]] && is_interactive && [[ -z "${CI:-}" ]]
}

# Usage in functions:
prompt_install_gh() {
    if ! can_prompt; then
        log_error "gh not installed. In non-interactive mode, use --install-deps or install manually."
        return 1
    fi
    # ... prompt logic
}
```

---

## 9. Output & Logging Design

### 9.1 Stream Separation

| Stream | Content | JSON Mode |
|--------|---------|-----------|
| **stderr** | Progress, errors, summary, help | Same |
| **stdout** | Repo paths (default) or JSON | JSON only |

### 9.2 Per-Repo Log Files

```bash
get_repo_log_path() {
    local repo_name="$1"
    local date_dir
    date_dir=$(date +%Y-%m-%d)
    echo "${RU_LOG_DIR}/${date_dir}/repos/${repo_name//\//_}.log"
}

# During operations, redirect git output to log file
do_clone() {
    local log_file
    log_file=$(get_repo_log_path "$repo_name")
    mkdir -p "$(dirname "$log_file")"

    # Capture full output to log, show summary to user
    gh repo clone "$clone_target" "$target_dir" &> "$log_file"
}
```

### 9.3 NDJSON Result Records

```bash
write_result() {
    local repo="$1"
    local action="$2"
    local status="$3"
    local duration="${4:-}"
    local error="${5:-}"

    # Escape for JSON
    error="${error//\"/\\\"}"
    error="${error//$'\n'/\\n}"

    cat >> "$RESULTS_FILE" << EOF
{"repo":"$repo","action":"$action","status":"$status","duration":${duration:-null},"error":"$error","timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
}
```

### 9.4 JSON Report Format

```json
{
  "version": "1.0.0",
  "timestamp": "2026-01-03T14:30:00Z",
  "duration_seconds": 154,
  "config": {
    "projects_dir": "/data/projects",
    "layout": "flat",
    "update_strategy": "ff-only"
  },
  "summary": {
    "total": 47,
    "cloned": 8,
    "updated": 34,
    "current": 3,
    "conflicts": 2,
    "failed": 0
  },
  "repos": [
    {
      "name": "repo1",
      "path": "/data/projects/repo1",
      "action": "pull",
      "status": "updated",
      "duration": 2
    },
    {
      "name": "repo2",
      "path": "/data/projects/repo2",
      "action": "pull",
      "status": "diverged",
      "error": "local and remote have diverged",
      "ahead": 2,
      "behind": 5
    }
  ]
}
```

---

## 10. Installation Script (install.sh)

### 10.1 Security-First Design

```bash
#!/usr/bin/env bash
#
# ru installer
# Downloads and installs ru (Repo Updater) to your system
#
# DEFAULT: Downloads from GitHub Release with checksum verification
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/repo_updater/main/install.sh | bash
#
# Options (via environment variables):
#   DEST=/path/to/dir      Install directory (default: ~/.local/bin)
#   RU_SYSTEM=1            Install to /usr/local/bin (requires sudo)
#   RU_VERSION=x.y.z       Install specific version (default: latest release)
#   RU_UNSAFE_MAIN=1       Install from main branch (NOT RECOMMENDED)
#
```

### 10.2 Installation Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                        Installer Flow                            │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │ Determine       │
                    │ version         │
                    │ (latest release │
                    │ or RU_VERSION)  │
                    └────────┬────────┘
                             │
                    ┌────────┴────────┐
                    │                 │
              RU_UNSAFE_MAIN=1     Normal
                    │                 │
                    ▼                 ▼
           ┌─────────────────┐ ┌─────────────────┐
           │Download from    │ │Download from    │
           │main branch      │ │GitHub Release   │
           │(warn user)      │ │                 │
           └────────┬────────┘ └────────┬────────┘
                    │                   │
                    │                   ▼
                    │          ┌─────────────────┐
                    │          │Download checksum│
                    │          │and verify       │
                    │          └────────┬────────┘
                    │                   │
                    │          ┌────────┴────────┐
                    │          │                 │
                    │        Match           Mismatch
                    │          │                 │
                    │          │                 ▼
                    │          │          ┌─────────────────┐
                    │          │          │ERROR: Checksum  │
                    │          │          │verification     │
                    │          │          │failed. Abort.   │
                    │          │          └─────────────────┘
                    │          │
                    └──────────┴──────────┐
                                          │
                                          ▼
                                 ┌─────────────────┐
                                 │Install to       │
                                 │DEST directory   │
                                 └────────┬────────┘
                                          │
                                          ▼
                                 ┌─────────────────┐
                                 │Add to PATH      │
                                 │if needed        │
                                 └────────┬────────┘
                                          │
                                          ▼
                                 ┌─────────────────┐
                                 │Print success    │
                                 │and next steps   │
                                 └─────────────────┘
```

---

## 11. Gum Integration & Visual Design

### 11.1 Banner Design

**With gum:**
```
╭──────────────────────────────────────╮
│  🔄 ru v1.0.0                        │
│  Repo Updater                        │
╰──────────────────────────────────────╯
```

### 11.2 Progress Display

```
→ Processing 12/47: coding_agent_session_search
  ├─ Path: /data/projects/coding_agent_session_search
  ├─ Status: behind (0 ahead, 3 behind)
  ├─ Action: git pull --ff-only
  └─ Result: ✓ Updated (2s)

→ Processing 13/47: mcp_agent_mail
  ├─ Path: /data/projects/mcp_agent_mail
  ├─ Status: dirty (3 files modified)
  ├─ Action: Skipped
  └─ Result: ⚠️ Conflict (dirty working tree)
```

### 11.3 Summary Report

```
╭─────────────────────────────────────────────────────────────╮
│                    📊 Sync Summary                          │
├─────────────────────────────────────────────────────────────┤
│  ✅ Cloned:     8 repos                                     │
│  ✅ Updated:   31 repos                                     │
│  ⏭️  Current:    3 repos (already up to date)               │
│  ⚠️  Conflicts: 2 repos (need attention)                    │
│  ❌ Failed:     0 repos                                     │
├─────────────────────────────────────────────────────────────┤
│  Total: 47 repos processed in 2m 34s                        │
│  Logs: ~/.local/state/ru/logs/2026-01-03/                   │
╰─────────────────────────────────────────────────────────────╯
```

### 11.4 Conflict Resolution Help (Detailed)

```
╭─────────────────────────────────────────────────────────────╮
│  ⚠️  Repositories Needing Attention                         │
╰─────────────────────────────────────────────────────────────╯

1. mcp_agent_mail
   Path:   /data/projects/mcp_agent_mail
   Branch: main
   Issue:  Dirty working tree (3 files modified)
   Log:    ~/.local/state/ru/logs/2026-01-03/repos/mcp_agent_mail.log

   Resolution options:
     a) Stash and pull:
        cd /data/projects/mcp_agent_mail && git stash && git pull && git stash pop

     b) Commit your changes:
        cd /data/projects/mcp_agent_mail && git add . && git commit -m "WIP"

     c) Discard local changes (DESTRUCTIVE):
        cd /data/projects/mcp_agent_mail && git checkout . && git clean -fd

2. fix_my_documents_backend
   Path:   /data/projects/fix_my_documents_backend
   Branch: main
   Issue:  Diverged (2 ahead, 5 behind)
   Log:    ~/.local/state/ru/logs/2026-01-03/repos/fix_my_documents_backend.log

   Resolution options:
     a) Rebase your changes:
        cd /data/projects/fix_my_documents_backend && git pull --rebase

     b) Merge (creates merge commit):
        cd /data/projects/fix_my_documents_backend && git pull --no-ff

     c) Push your changes first (if intentional):
        cd /data/projects/fix_my_documents_backend && git push
```

---

## 12. README.md Structure

Following giil's comprehensive style:

```markdown
<p align="center">
  <img src="badges..." />
</p>

<h1 align="center">ru</h1>
<h3 align="center">Repo Updater</h3>

<p align="center">
  <strong>A beautiful, automation-friendly CLI for synchronizing GitHub repositories</strong>
</p>

---

## Table of Contents
- [The Primary Use Case](#the-primary-use-case)
- [Why ru Exists](#why-ru-exists)
- [Highlights](#highlights)
- [Quickstart](#quickstart)
- [Commands](#commands)
- [Configuration](#configuration)
- [Conflict Resolution](#conflict-resolution)
- [Automation & CI](#automation--ci)
- [Architecture](#architecture)
- [Exit Codes](#exit-codes)
- [Troubleshooting](#troubleshooting)
- [Uninstallation](#uninstallation)
- [License](#license)

---

## Quickstart

# Install
curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/repo_updater/main/install.sh | bash

# Initialize configuration
ru init

# Add your repos
ru add owner/repo1
ru add owner/repo2 --private

# Sync everything
ru sync

---

## Commands

| Command | Description |
|---------|-------------|
| `ru sync` | Synchronize all repos (default) |
| `ru status` | Show repo status without changes |
| `ru init` | Initialize configuration |
| `ru add <repo>` | Add repo to list |
| `ru list` | List configured repos |
| `ru doctor` | System diagnostics |
| `ru self-update` | Update ru |

---

## Automation & CI

ru is designed for non-interactive use:

# In CI/scripts, use:
ru sync --non-interactive --json

# Or with environment auth:
GH_TOKEN=xxx ru sync --non-interactive

Exit codes:
- 0: All repos synced
- 1: Some repos failed
- 2: Conflicts exist
- 3: Dependency error
- 4: Invalid arguments

[... continue with full documentation ...]
```

---

## 13. CI/CD Workflows

### 13.1 ci.yml (With Behavioral Tests)

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  shellcheck:
    name: ShellCheck
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ludeeus/action-shellcheck@master
        with:
          scandir: '.'
          severity: warning
        env:
          SHELLCHECK_OPTS: -e SC2155 -e SC2034

  syntax-check:
    name: Syntax Validation
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: bash -n ru
      - run: bash -n install.sh

  install-test:
    name: Installation Test
    needs: [shellcheck, syntax-check]
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - name: Run installer
        run: |
          export DEST="${HOME}/.local/bin"
          export RU_UNSAFE_MAIN=1  # OK for testing from PR
          bash install.sh
      - name: Verify installation
        run: |
          "${HOME}/.local/bin/ru" --version
          "${HOME}/.local/bin/ru" --help | head -20

  behavioral-tests:
    name: Behavioral Tests
    needs: [shellcheck, syntax-check]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Setup test environment
        run: |
          chmod +x ru
          mkdir -p /tmp/test-projects
      - name: Test URL parsing
        run: bash scripts/test_parsing.sh
      - name: Test local git operations
        run: bash scripts/test_local_git.sh
      - name: Test JSON output validity
        run: |
          ./ru list --json 2>/dev/null | python3 -m json.tool > /dev/null

  json-schema:
    name: JSON Output Validation
    needs: [shellcheck, syntax-check]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Test JSON output is valid
        run: |
          chmod +x ru
          ./ru --help 2>&1 || true  # Just ensure it doesn't crash

  version-consistency:
    name: Version Consistency
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Verify version matches
        run: |
          FILE_VERSION=$(cat VERSION)
          SCRIPT_VERSION=$(grep -m1 '^VERSION=' ru | cut -d'"' -f2)
          if [[ "$FILE_VERSION" != "$SCRIPT_VERSION" ]]; then
            echo "::error::VERSION mismatch"
            exit 1
          fi
```

### 13.2 Behavioral Test: Local Git Operations

```bash
#!/usr/bin/env bash
# scripts/test_local_git.sh
set -euo pipefail

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Create a "remote" bare repo
git init --bare "$TEMP_DIR/remote.git"

# Clone it as "local"
git clone "$TEMP_DIR/remote.git" "$TEMP_DIR/local"

# Make initial commit in local, push to remote
cd "$TEMP_DIR/local"
echo "initial" > file.txt
git add file.txt
git commit -m "Initial"
git push origin main

# Create another clone to simulate "projects dir"
git clone "$TEMP_DIR/remote.git" "$TEMP_DIR/projects/testrepo"

# Make a new commit in "remote" (via first clone)
cd "$TEMP_DIR/local"
echo "update" >> file.txt
git add file.txt
git commit -m "Update"
git push origin main

# Now test ru's status detection on projects/testrepo
cd "$TEMP_DIR/projects/testrepo"
source "$(dirname "$0")/../ru"  # Source for testing

# Test: should detect "behind"
status_output=$(get_repo_status "$TEMP_DIR/projects/testrepo" "true")
if [[ "$status_output" != *"STATUS=behind"* ]]; then
    echo "FAIL: Expected STATUS=behind, got: $status_output"
    exit 1
fi

echo "PASS: Local git operations test"
```

---

## 14. Implementation Steps (Granular)

### Phase 1: Project Setup (6 steps)

- [ ] **1.1** Create VERSION file with `1.0.0`
- [ ] **1.2** Create LICENSE file (MIT)
- [ ] **1.3** Create .gitignore (exclude runtime artifacts, logs)
- [ ] **1.4** Create .github/workflows directory structure
- [ ] **1.5** Create examples/ with `public.txt` and `private.template.txt`
- [ ] **1.6** Remove `je_*.txt` files from git tracking (keep as local development files)

### Phase 2: Core Script Skeleton (10 steps)

- [ ] **2.1** Create `ru` with shebang, header, `set -uo pipefail` (NOT `-e`)
- [ ] **2.2** Add VERSION, XDG paths, and default constants
- [ ] **2.3** Add ANSI color definitions
- [ ] **2.4** Add runtime state variables (GUM_AVAILABLE, INTERACTIVE, etc.)
- [ ] **2.5** Create RESULTS_FILE temp file and EXIT trap
- [ ] **2.6** Implement `is_interactive()` and `can_prompt()`
- [ ] **2.7** Implement `show_help()` and `show_version()`
- [ ] **2.8** Implement `dispatch_command()` with subcommand routing
- [ ] **2.9** Implement `parse_global_args()` for --json, --quiet, etc.
- [ ] **2.10** Create `main()` entry point

### Phase 3: Configuration System (7 steps)

- [ ] **3.1** Implement `ensure_dir()` utility
- [ ] **3.2** Implement `get_config_value()` to read from config file
- [ ] **3.3** Implement `set_config_value()` to write to config file
- [ ] **3.4** Implement `resolve_config()` for CLI > env > file > default
- [ ] **3.5** Implement `ensure_config_exists()` for first-run
- [ ] **3.6** Implement `cmd_init()` subcommand
- [ ] **3.7** Implement `cmd_config()` subcommand

### Phase 4: Logging System (6 steps)

- [ ] **4.1** Implement `log_info()`, `log_warn()`, `log_error()` → stderr
- [ ] **4.2** Implement `log_step()`, `log_success()`, `log_debug()` → stderr
- [ ] **4.3** Implement `output_json()` → stdout only
- [ ] **4.4** Implement `get_repo_log_path()` for per-repo logs
- [ ] **4.5** Implement `write_result()` for NDJSON records
- [ ] **4.6** Test stream separation (human → stderr, data → stdout)

### Phase 5: Gum Integration (5 steps)

- [ ] **5.1** Implement `check_gum()` to detect availability
- [ ] **5.2** Implement `gum_confirm()` with fallback to read
- [ ] **5.3** Implement `gum_spin()` with fallback to simple output
- [ ] **5.4** Implement `print_banner()` with gum and ANSI fallbacks
- [ ] **5.5** Test with GUM_AVAILABLE=true and false

### Phase 6: Dependency Management (7 steps)

- [ ] **6.1** Implement `detect_os()` for macOS/Linux
- [ ] **6.2** Implement `check_gh_installed()`
- [ ] **6.3** Implement `check_gh_authenticated()`
- [ ] **6.4** Implement `prompt_install_gh()` with user confirmation
- [ ] **6.5** Implement `prompt_gh_auth()` for interactive auth
- [ ] **6.6** Implement `ensure_dependencies()` full flow
- [ ] **6.7** Test non-interactive mode (should fail cleanly, not hang)

### Phase 7: URL & Path Parsing (6 steps)

- [ ] **7.1** Implement `parse_repo_url()` for all URL formats
- [ ] **7.2** Implement `normalize_url()` for comparison
- [ ] **7.3** Implement `url_to_local_path()` with layout support
- [ ] **7.4** Implement `url_to_clone_target()` for gh
- [ ] **7.5** Implement `sanitize_path_segment()`
- [ ] **7.6** Write `scripts/test_parsing.sh` tests

### Phase 8: Git Operations (8 steps)

- [ ] **8.1** Implement `is_git_repo()` check
- [ ] **8.2** Implement `get_repo_status()` using git plumbing
- [ ] **8.3** Implement `get_remote_url()`
- [ ] **8.4** Implement `check_remote_mismatch()`
- [ ] **8.5** Implement `do_fetch()` for status mode
- [ ] **8.6** Implement `do_clone()` with proper error handling
- [ ] **8.7** Implement `do_pull()` with strategy support
- [ ] **8.8** Write `scripts/test_local_git.sh` tests

### Phase 9: Repo List Management (5 steps)

- [ ] **9.1** Implement `load_repo_list()` (skip comments, empty lines)
- [ ] **9.2** Implement `parse_repo_spec()` for `repo@branch` syntax
- [ ] **9.3** Implement `dedupe_repos()` by local path
- [ ] **9.4** Implement `detect_collisions()` with warnings
- [ ] **9.5** Implement `get_all_repos()` to merge lists

### Phase 10: Subcommand Implementations (8 steps)

- [ ] **10.1** Implement `cmd_sync()` - main sync logic
- [ ] **10.2** Implement `cmd_status()` - read-only status
- [ ] **10.3** Implement `cmd_add()` - add repo to list
- [ ] **10.4** Implement `cmd_list()` - show configured repos
- [ ] **10.5** Implement `cmd_doctor()` - system diagnostics
- [ ] **10.6** Implement `cmd_self_update()` - update ru
- [ ] **10.7** Implement `process_single_repo()` orchestration
- [ ] **10.8** Implement main processing loop with progress

### Phase 11: Reporting & Summary (5 steps)

- [ ] **11.1** Implement `aggregate_results()` from NDJSON
- [ ] **11.2** Implement `print_summary()` styled box
- [ ] **11.3** Implement `print_conflict_help()` with commands
- [ ] **11.4** Implement `generate_json_report()` for --json
- [ ] **11.5** Implement `compute_exit_code()` logic

### Phase 12: Installation Script (6 steps)

- [ ] **12.1** Create `install.sh` skeleton with secure defaults
- [ ] **12.2** Implement `get_latest_release()` from GitHub API
- [ ] **12.3** Implement `download_and_verify()` with checksum
- [ ] **12.4** Implement `get_install_dir()` and `get_shell_config()`
- [ ] **12.5** Implement `add_to_path()` with idempotent checks
- [ ] **12.6** Implement `main()` with full installation flow

### Phase 13: README & Documentation (4 steps)

- [ ] **13.1** Create README.md header with badges
- [ ] **13.2** Write quickstart and commands sections
- [ ] **13.3** Write automation/CI section with exit codes
- [ ] **13.4** Write troubleshooting and architecture sections

### Phase 14: CI/CD Workflows (4 steps)

- [ ] **14.1** Create `.github/workflows/ci.yml`
- [ ] **14.2** Create `.github/workflows/release.yml`
- [ ] **14.3** Create `scripts/test_parsing.sh`
- [ ] **14.4** Create `scripts/test_local_git.sh`

### Phase 15: Testing & Polish (5 steps)

- [ ] **15.1** Test installation script on clean environment
- [ ] **15.2** Test gh CLI detection and auth flow
- [ ] **15.3** Test sync/status/init/add commands
- [ ] **15.4** Test non-interactive mode in CI
- [ ] **15.5** Final ShellCheck pass

---

## 15. Future Enhancements (v2)

These are valuable but deferred to keep v1 focused:

### 15.1 Parallelism
- Worker pool with NDJSON aggregation
- Progress bar instead of per-repo spinners
- `--parallel N` option

### 15.2 Advanced Repo Specs
- TOML/YAML manifest support
- Tags for filtering (`#tag=backend`)
- Skip rules (`!pull`)

### 15.3 Multi-Host Support
- GitHub Enterprise (`--hostname`)
- Per-host authentication
- `full` layout as default

### 15.4 Object Cache/Mirrors
- `--cache-mirrors` for faster clones
- Bare repo cache with `--reference-if-able`

### 15.5 Orphan Management
- `ru orphans` - show local repos not in lists
- `ru prune` - archive orphans (never delete by default)

### 15.6 Modular Build
- `src/lib/*.sh` modules
- `scripts/build.sh` concatenation
- Per-module unit tests

---

## Appendix A: Comparison with Original Plan

| Aspect | Original Plan | Revised Plan |
|--------|---------------|--------------|
| List files | In repo as defaults | XDG config, examples only in repo |
| Private list | Committed | Template only, actual in XDG |
| Path layout | Flat only | Configurable (flat default) |
| set -e | Used globally | Explicit error handling |
| Git status | String parsing | Git plumbing |
| cd in functions | Global cd | git -C everywhere |
| Output streams | Mixed | stderr=human, stdout=data |
| Exit codes | Single | Meaningful (0/1/2/3/4) |
| Auto-install | Default | Prompted or opt-in |
| Installer | From main | From release + checksum |
| CI tests | Syntax only | Behavioral tests included |
| Commands | Flags only | Subcommand architecture |

---

## Appendix B: Sample Session

```
$ ru init
╭──────────────────────────────────────╮
│  🔄 ru v1.0.0                        │
│  Repo Updater                        │
╰──────────────────────────────────────╯

✓ Created ~/.config/ru/config
✓ Created ~/.config/ru/repos.d/public.txt
✓ Created ~/.config/ru/repos.d/private.txt

Next steps:
  1. Add repos: ru add owner/repo
  2. Sync:      ru sync

$ ru add Dicklesworthstone/mcp_agent_mail
✓ Added to public list: Dicklesworthstone/mcp_agent_mail

$ ru sync
→ Processing 1/1: mcp_agent_mail
  ├─ Path: /data/projects/mcp_agent_mail
  ├─ Status: missing
  ├─ Action: gh repo clone
  └─ Result: ✓ Cloned (12s)

╭─────────────────────────────────────────────────────────────╮
│                    📊 Sync Summary                          │
├─────────────────────────────────────────────────────────────┤
│  ✅ Cloned:  1 repo                                         │
│  Total: 1 repo processed in 12s                             │
╰─────────────────────────────────────────────────────────────╯
```

---

*This revised plan incorporates critical fixes for packaging, error handling, and automation support while maintaining the original giil-like polish goals.*

---

## 2026-10-13 Reality Check and Evidence-Based Bridge

This section records the current assessment and the executable bridge backlog.
The original plan above remains historical design context; its unchecked boxes,
old versions and pseudocode are not a statement of current implementation status.

### Verdict and assessment boundary

**ru delivers its basic repository synchronization value, but does not yet deliver
the full reliability and automation contract advertised by the README.** There
is substantial functioning software here: real Git clone/pull/status handling,
configuration and layout parsing, parallel/state machinery, conservative prune
protections, review discovery and drivers, quality-gate helpers and structured
output helpers. Several workflows nevertheless report success without satisfying
their promised result, and some documented operations cannot be invoked.

Assessment baseline: `main` at
`73846ab9300af58d436f9d82c32eb1ab2096acd7`, `VERSION=1.5.0`.
The full 849-line local AGENTS.md, 539-line suite AGENTS.md and 3,864-line README
were read. The original synchronization plan, automated-review plan, NTM plan,
testing guidance, research findings and agent guidance were compared with actual
code. Source, CLI probes, tracker records and test evidence take precedence over
old completion claims.

The production script and installer were unchanged during this assessment:

| File | SHA256 |
|---|---|
| `ru` | `df405927d525ae6c17cd81365672dbf00c8628f70b7e030476eb55f415541b86` |
| `install.sh` | `4af6f6fc31979c775553fdb50da73f34395762eca8c769dea9ab6de77535dc94` |

GitHub's latest published release was v1.5.0, published 2026-10-01. Its downloaded
`ru` asset matched both the manifest and the script above. These findings therefore
apply to the published script, rather than only an unreleased local change.
Actual installation on a clean machine and live AI orchestration were not proven
by this download comparison.

Local evidence is retained under `/tmp/ru-reality-check-73846ab/`. In particular:
`probes.sh` and `probes.log`, per-command stdout/stderr, `core-probes.sh` and
`core-probes.log`, `gate-exit42.json`, `fork-clean-details.log`, lint/full-suite
logs, tracker snapshots and release/CI metadata. The two probe scripts are
standalone, inspectable reproductions. Temporary Git fixtures remain outside the
managed projects directory.

### Vision checklist

Status describes the exact proof available. WORKING is scoped to demonstrated
behavior; PARTIAL identifies a concrete limitation; UNPROVEN means implementation
exists without sufficient qualification. Existing explicitly deferred future
ideas remain deferred rather than being silently turned into release requirements.

| # | Promised outcome | Current reality and evidence | Bridge Beads |
|---|---|---|---|
| V1 | Release installation with mandatory checksum verification | PARTIAL. Live v1.5.0 download matches the manifest. Missing checksum tooling is accepted, and no-release detection automatically falls back to mutable main. | `.23`, `.24` |
| V2 | XDG configuration, init/add/remove/list and precedence | WORKING for tested valid forms; PARTIAL for documented `config --set KEY=VALUE`, which exits 4. Full CLI init/add and actual `--set=KEY=VALUE` work. | `.17`, `.18` |
| V3 | URL/spec parsing, layouts, custom names, groups and path protections | Implemented and exercised by existing parsing/spec/prune tests. Branch pins have a confirmed success-reporting gap. | `.19`, `.20`, `.27` |
| V4 | Clone missing repos, pull remote updates, preserve dirty work | WORKING in the independent full CLI exercise with real local Git storage: clone and pull exit 0, dirty sync exits 2 and preserves the file. GitHub transport/auth were fixture-controlled. | `.19`, `.20`, `.27` |
| V5 | Trustworthy freshness, conflicts, network failures and timeout semantics | PARTIAL. Requested fetch failures are suppressed in status; HTTP low-speed settings are not an overall command deadline. | `.19`, `.20` |
| V6 | Parallel synchronization and reliable interrupted resume | Real implementation and extensive tests exist. Full-suite/platform qualification is distinct from reading those helpers. | `.27` |
| V7 | Conservative orphan detection, archive and deletion protections | Substantial implementation. Existing prune E2E file passed in this audit; documented stale-ref/LFS/reflog limits remain. No destructive operation was run against the user's fleet. | `.27` |
| V8 | Meaningful failure codes and honest recovery state | PARTIAL. A review orchestration failure becomes exit 0 and clears its checkpoint; failed/missing session artifacts can be counted as completed. | `.9`, `.10` |
| V9 | Consistent JSON/TOON output, schemas and data-only stdout | PARTIAL. Populated sync/status/list use the envelope. Empty commands, doctor/config, review, sweep, AI sync and ad-hoc sync do not share that complete contract. | `.15`, `.16` |
| V10 | All documented commands, filters and parallel flags work | PARTIAL. `--set`, import stars/org/user modes, sweep debug/denylist and wildcard filters are absent or ineffective; sweep short parallel flags miss its local scheduling value. | `.17`, `.18` |
| V11 | Discover and prioritize all open review work | PARTIAL. Discovery caps newest issues at 50, PRs at 20 and labels at 10 without pagination. Natural scores never reach the CRITICAL threshold. | `.21`, `.22` |
| V12 | Isolated reviews, questions, approval and plan/apply policy | Real drivers/worktrees/questions exist. PARTIAL: plan identity/schema and approval enforcement are incomplete; advertised policy JSON is not read by the actual policy loader. | `.3`, `.4`, `.9`, `.10` |
| V13 | Quality gates prevent publishing broken changes | FAIL for demonstrated nonzero exits: actual `exit 42` yields `tests.ok=false` but `overall_ok=true` and return 0. Runtime test detection differs from its unit-tested earlier definition. | `.1`, `.2` |
| V14 | Agent sweep commits exactly validated, allowed files | PARTIAL. A supplied one-file plan committed a pre-staged unrelated file too. Untracked candidates evade heuristic scanning; heuristic findings are not blocked by block mode. | `.5`, `.6` |
| V15 | AI sync verifies logical commits and optional pushes | UNPROVEN as a live workflow, with a confirmed source defect: idle/stale or vanished sessions are accepted without proving requested Git outcomes. | `.11`, `.12` |
| V16 | Dependency updates across all configured repos and eight managers | FAIL in default mode: an undefined listing helper produces a successful empty run. The wrapper's success result is rejected by the consumer; Maven/Gradle have no effective outdated discovery. | `.13`, `.14` |
| V17 | Deterministic version bump, changelog, tag, release and checks | PARTIAL. Tag/GitHub-release operations exist; version-file/changelog execution and complete remote CI/artifact validation promised by the NTM plan are missing. | `.7`, `.8` |
| V18 | Dashboard application/pause and trustworthy metrics | PARTIAL. The enhanced `run_dashboard` has no production caller; apply/bulk-apply keys only log requests. Scheduler controls and completion metrics need integrated outcome proof. | `.9`, `.10` |
| V19 | Safe fork maintenance and accurate cleanup reporting | PARTIAL. Explicit reset/force works; default ff-only preserves local commits but reports removal. An existing test incorrectly expects default removal. | `.25`, `.26` |
| V20 | Bash 4.0+, Linux/macOS, optional-tool fallbacks and current CI proof | UNPROVEN across the declared matrix. This audit ran GNU Bash 5.3.9 on Linux. A newer Bash syntax pass does not establish minimum-runtime or macOS support. | `.27` |
| V21 | Correct privacy, dependency and agent documentation | PARTIAL. README's GitHub-only/local-processing privacy statement omits optional AI-provider processing. Version/LOC/default/policy/output examples drift across documents. | `.17`, `.18`, `.27` |

All shorthand IDs in this table are children of `bd-tr5y`, for example `.1` is
`bd-tr5y.1`. The original plan's v2 manifests/tags/skip rules, mirrors/object cache
and modular build, and the review plan's future web/team/learning/plugin ideas,
are explicitly deferred design ideas. They are not demonstrated implemented
features and were not added to this corrective release graph as scope expansion.

### What the probes establish

1. **Core value is real.** The independent CLI exercise initialized configuration,
   added a repo, cloned real local Git storage, pulled a new remote commit and
   detected dirty work with exit 2. Existing E2E checks additionally exercise the
   production command dispatch for pruning, review/apply, drivers and state.
   Fixture-controlled external endpoints are not live GitHub/provider proof.
2. **Quality gates admit failed commands.** `run_quality_gates` recognizes only
   exit 1 as failure, although the test/lint helpers return actual process codes.
   The captured result contains `tests.exit_code=42`, `tests.ok=false` and
   `overall_ok=true`. Exit 2 can also be confused with an absent runner, and a
   timeout/missing executable can be misreported. This is an execution-contract
   defect, not an argument for weakening tests.
3. **Review success is unreliable.** The negated-command branch captures `$?`
   after `!`, losing the failing orchestration code. A controlled failure of 3
   produced `checkpoint-cleared`, reported orchestration 0 and final review 0.
   The orchestration loop and missing-plan completion paths also need honest
   per-session aggregation and recovery.
4. **Dependency update is disconnected.** `_list_local_repos` has no definition.
   Default `dep-update --dry-run --json` reported no configured repos despite a
   valid configured repo. Separately, injecting `spawn_ai_session`'s actual
   `{status:"success"}` contract produced one failed update; the consumer accepts
   `completed|idle` instead. Registry/tool failures cannot be counted as current.
5. **The staged index bypasses the plan.** A real Git fixture pre-staged
   `unrelated.txt`; a plan naming only `planned.txt` committed both. The executor
   must preserve the existing index while committing only approved candidate
   content. Heuristic scanning called a harmless untracked password assignment
   clean, then returned warning 2 once staged; block mode only blocks code 1.
6. **Documented CLI choices fail.** `config --set KEY=VALUE`, `import --stars`,
   `agent-sweep --show-denylist` and `agent-sweep --debug` return 4. A wildcard
   sweep filter selects no matching dirty repo; an AI-sync wildcard exclusion
   does not exclude it. These are full-dispatch observations.
7. **Machine output is incomplete.** Empty list/status/prune and doctor/config
   JSON invocations emitted zero data bytes. AI-sync dry-run produced an array,
   review status another object shape, and missing-pin ad-hoc sync no JSON.
   Documentation/schema text alone cannot prove output conformance.
8. **Branch pins are not enforced at success.** Syncing a nonexistent requested
   branch warned, left the clone on main and returned 0. Preserve the partial
   clone for inspection, but make failure visible and resumable.
9. **Review prioritization misses its stated target.** An old security issue
   scored 125/HIGH. The maximum natural issue/PR scores are 125/135, below the
   CRITICAL threshold 150. Paginated discovery must also find old security items
   beyond the newest 50/20 and relevant labels beyond the first ten.
10. **The broad gate remains authoritative.** The focused fork-clean reproduction
    produced 7 passed / 1 failed, with one failing assertion in
    `test_resets_main_to_upstream`. It expects default cleanup to remove commits,
    whereas code requires explicit reset/force. Retain the safe default, correct
    reporting, and document the old/new acceptance split for a legitimate test
    correction. Do not make the default destructive to obtain a green number.

Driver-interface fallback functions are overridden by loaded real drivers; their
stub comments are not evidence that all review commands are placeholders. Similarly,
the old SECTION 13 "COMMAND STUBS" heading is stale labeling, not a reliable
description of its substantial command bodies. The actionable dashboard apply
TODO and missing manager behavior are actual implementation gaps.

### Verification ledger

| Check | Result and scope |
|---|---|
| `shellcheck -s bash -S warning ru install.sh` | PASS, exit 0, ShellCheck 0.11.0 |
| `bash -n ru`, `bash -n install.sh`, all `scripts/*.sh` | PASS; all 98 script files parse |
| `bash scripts/run_all_tests.sh` | The slower duplicate sequential attempt was stopped after the complete parallel run finished. Its partial log is retained and is not counted as a completed gate. |
| `bash scripts/run_all_tests.sh -j 4` | FAIL, exit 1: all 95 test files ran, 94 passed / 1 failed, 1,026 seconds. The only failed file is `test_e2e_fork_clean.sh`. These are file counts, not an assertion count or proof that every gated inner scenario ran. |
| Independent CLI/core/adversarial probes | Completed; failures and successes above are retained rather than normalized into a green verdict |
| Focused fork-clean file | FAIL, 7 passed / 1 failed, 21 assertions passed / 1 failed |
| Live release download/manifest | PASS for v1.5.0 ru byte identity and checksum |
| Live CI visibility | Latest visible CI workflow run was July 23 and failed ShellCheck; test/install jobs skipped. It does not qualify this October revision. Recent green Dependabot runs are not CLI quality gates. |
| UBS on changed Markdown/JSONL | UNSCANNED, exit 3: no supported language; this is not a scanner pass. Ledger JSON parsing, unique IDs, append-only original records and `git diff --check` were checked separately. |
| UBS on unchanged `ru`/`install.sh` | PARTIAL, exit 2: its embedded ShellCheck hit a hardcoded 120-second timeout. The Bash module reports 11 critical-pattern findings and 131 warnings; the combined summary's 0 critical is not reliable for this partial run. Findings are scanner observations, not 11 independently proven vulnerabilities. |
| UBS environment diagnosis | `ubs doctor` passes. Seven critical patterns are variable-name-guarded array helpers, four are quoted installer instructions, and all 131 warnings concern post-increment under `set -e`, which these scripts explicitly avoid. This contextual review does not turn the partial scanner run into a clean scan. |
| Bash 4.0/macOS/live AI and external apply/release | UNPROVEN in this audit; explicitly required by final qualification |

### Beads coverage and bridge ordering

Before this assessment there were **525 closed, 1 open and 0 in-progress Beads**.
The only open issue, `bd-ri2v`, covers preserved fleet maintenance. Completing it
would not repair any of the confirmed product gaps above. Historical closed
implementation/test issues provide context, not an active correction plan or
current end-to-end qualification.

The new epic is **`bd-tr5y`**, with 13 implementation/verification pairs and one
final qualification task: **28 new Beads total**, all left open. Every task embeds
the baseline, observed defect, intended result, edit surface, concrete acceptance,
adversarial cases and evidence requirements. Implementation tasks must include
meaningful regressions in the same change; companion tasks independently verify
the full workflow. Existing issue criteria and `bd-ri2v` remain unchanged.

| Work package | Implementation | Independent verification | Dependencies and intended result |
|---|---|---|---|
| Test/lint gates and runtime test detection | `.1` | `.2` | Reject executed failures and missing required proof; remove runtime/test divergence |
| Review-plan identity, approval and policy | `.3` | `.4` | Bind approved content to exact run/repo/worktree/commits before application |
| Exact sweep candidate and secret scanning | `.5` | `.6` | Preserve peer staging; scan the complete publishable candidate; verification also requires `.2` |
| Deterministic version/changelog/release outcome | `.7` | `.8` | Implementation depends on `.1` and `.5`; verify actual tagged and remote outcome |
| Review failures/checkpoints/dashboard controls | `.9` | `.10` | Verification also requires `.2` and `.4`; route all application through the shared gates |
| AI session work-result contract | `.11` | `.12` | Distinguish idle/death from verified requested commits/push; preserve artifacts |
| Dependency update repo/manager wiring | `.13` | `.14` | Implementation depends on `.11`; consume actual shared results and real manager outcomes |
| Structured outputs and schema conformance | `.15` | `.16` | Verification also requires `.12`, `.14`, `.18`; all empty/dry-run/failure paths have useful data |
| Advertised flags, filtering and documentation | `.17` | `.18` | Make the documented features invocable and controls observable |
| Sync pins, freshness and deadlines | `.19` | `.20` | Preserve incomplete work while making unmet requests visible |
| Complete review discovery and priorities | `.21` | `.22` | Find old/beyond-page critical work and make critical scheduling reachable |
| Installer integrity and explicit unsafe opt-in | `.23` | `.24` | Fail required verification clearly and make pipeline options effective |
| Fork preservation contract and test diagnostics | `.25` | `.26` | Correct the defective gate with retained evidence; report actual changes and assertions |
| Integrated qualification | `.27` | — | Blocked by every verification task; one exact revision, full matrix and current real evidence |

Start with the P1 execution failures: gates, approval/plan identity, candidate
isolation and review recovery. Independent parser/output/discovery work can proceed
without serializing unrelated changes; reserve narrow paths because the main Bash
file is shared. Complete the common session contract before its dependency-update
consumer. Release automation depends on validated candidate isolation and gates.
The final task cannot be closed on isolated helper tests, unavailable platforms,
mock-only AI results or an old GitHub badge.

### Ambition and refinement record

Three scope-expansion rounds tested the plan against increasingly complete user
outcomes: (1) move from helper existence to actual CLI selection/results; (2) bind
plans, staging, approvals, recovery and publication to the requested candidate;
(3) require supported-platform and real-tool proof, including release bytes and
failure behavior. These rounds retained the existing functionality rather than
introducing unrelated speculative features.

Five plan-space checks were applied: coverage against the vision and old tracker;
safe ordering and shared contracts; discriminative unit/full-CLI adversarial cases;
negative outcomes, artifact logging and qualification boundaries; and final graph
and criteria review. The fork-contract and final qualification tasks were added
when coverage checks exposed omissions. Cross-package dependencies and acceptance
criteria were strengthened in place. The final dependency-cycle check was empty.

The skill's frozen bead-generation and refinement requirements were followed:
tasks are self-contained, changes use `br`, features are retained, tests and logs
are explicit, and completion remains gated on observed behavior. Proposed work is
not implemented work. No implementation or qualification Bead was closed by this
assessment.

Two policy references in local AGENTS.md are stale: "Named Reward-Hacking Patterns"
and "Work-Graph Discipline" are not present in the current suite AGENTS.md. This
does not authorize weakening gates or ignoring the local preservation/graph rules.
The documented policy/reference drift belongs in `.17`/`.18`; no suite policy
file was rewritten during this assessment.

Completing the new graph would address the known gaps and require proof of the
advertised workflows. It is an evidence-backed bridge, not a guarantee that an
untested external tool, platform or future failure mode is already handled.
