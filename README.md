<p align="center">
  <img src="https://img.shields.io/badge/version-1.0.0-blue?style=for-the-badge" alt="Version" />
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blueviolet?style=for-the-badge" alt="Platform" />
  <img src="https://img.shields.io/badge/shell-Bash%204.0+-purple?style=for-the-badge" alt="Shell" />
  <img src="https://img.shields.io/badge/license-MIT-green?style=for-the-badge" alt="License" />
</p>

<h1 align="center">ru</h1>
<h3 align="center">Repo Updater</h3>

<p align="center">
  <strong>A beautiful, automation-friendly CLI for synchronizing GitHub repositories</strong>
</p>

<p align="center">
  Keep dozens (or hundreds) of repos in sync with a single command.<br/>
  Clone missing repos, pull updates, detect conflicts, and get actionable resolution commands.
</p>

<p align="center">
  <em>Pure Bash with no string parsing of git output. Uses git plumbing for reliable status detection.<br/>
  Meaningful exit codes for CI. JSON output for scripting. Non-interactive mode for automation.</em>
</p>

---

<p align="center">

```bash
curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/repo_updater/main/install.sh | bash
```

</p>

---

## 🎯 The Primary Use Case: Keeping Your Projects Directory in Sync

**The scenario:** You work across multiple machines, contribute to dozens of repositories, and your local `/data/projects` directory needs to stay synchronized with GitHub. Manually running `git pull` in each directory is tedious and error-prone.

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Your Repos     │     │  repos.d/       │     │       ru        │
│  on GitHub      │────▶│  public.txt     │────▶│     sync        │
│  (47 repos)     │     │  private.txt    │     │                 │
└─────────────────┘     └─────────────────┘     └─────────────────┘
                                                        │
         ┌──────────────────────────────────────────────┤
         ▼                    ▼                         ▼
┌─────────────────┐  ┌─────────────────┐     ┌─────────────────┐
│  Clone Missing  │  │  Pull Updates   │     │  Report Status  │
│  (8 new repos)  │  │  (34 updated)   │     │  (2 conflicts)  │
└─────────────────┘  └─────────────────┘     └─────────────────┘
                                                        │
                                                        ▼
                                             ┌─────────────────┐
                                             │  Actionable     │
                                             │  Resolution     │
                                             │  Commands       │
                                             └─────────────────┘
```

**The workflow:**

1. **Configure once** — Add repos to `~/.config/ru/repos.d/public.txt`
2. **Run `ru sync`** — Everything happens automatically
3. **Review conflicts** — Get copy-paste commands to resolve issues

```bash
# On any machine, sync all 47 of your repos
ru sync

# Output:
# → Processing 1/47: mcp_agent_mail
#   ├─ Path: /data/projects/mcp_agent_mail
#   ├─ Status: behind (0 ahead, 3 behind)
#   └─ Result: ✓ Updated (2s)
#
# ╭─────────────────────────────────────────────────────────────╮
# │                    📊 Sync Summary                          │
# │  ✅ Cloned:     8 repos                                     │
# │  ✅ Updated:   34 repos                                     │
# │  ⏭️  Current:    3 repos                                    │
# │  ⚠️  Conflicts: 2 repos (need attention)                    │
# │  Total: 47 repos processed in 2m 34s                        │
# ╰─────────────────────────────────────────────────────────────╯
```

**Comparison:**

| Without ru | With ru |
|------------|---------|
| `cd` into each of 47 directories and `git pull` | One command syncs everything |
| Forget which repos exist locally vs remotely | Automatically clones missing repos |
| Wonder if your local branch diverged | Clear status: behind, ahead, diverged, conflict |
| Google the right git commands for conflicts | Copy-paste resolution commands provided |
| Manual process breaks when network fails | Meaningful exit codes for scripting |

---

## Table of Contents

- [The Primary Use Case](#-the-primary-use-case-keeping-your-projects-directory-in-sync)
- [Why ru Exists](#-why-ru-exists)
- [Highlights](#-highlights)
- [Quickstart](#-quickstart)
- [Commands](#-commands)
- [Configuration](#-configuration)
- [Repo List Format](#-repo-list-format)
- [Sync Workflow](#-sync-workflow)
- [Git Status Detection](#-git-status-detection)
- [Conflict Resolution](#-conflict-resolution)
- [Output Modes](#-output-modes)
- [Exit Codes](#-exit-codes)
- [Architecture](#-architecture)
- [Design Principles](#-design-principles)
- [Troubleshooting](#-troubleshooting)
- [Environment Variables](#-environment-variables)
- [Dependencies](#-dependencies)
- [Security & Privacy](#-security--privacy)
- [Uninstallation](#-uninstallation)
- [Contributing](#-contributing)
- [License](#-license)

---

## 💡 Why ru Exists

Managing a large collection of GitHub repositories presents unique challenges:

| Problem | Why It's Hard | How ru Solves It |
|---------|---------------|------------------|
| **Too many repos to update manually** | 47 repos × `cd` + `git pull` = wasted time | One command syncs everything |
| **New repos on GitHub not cloned locally** | No way to detect missing repos automatically | Compares list to local directory, clones missing |
| **Diverged branches are confusing** | "Already up to date" vs actual divergence | Git plumbing detects ahead/behind/diverged states |
| **Dirty working trees block pulls** | Errors with uncommitted changes | Clear warnings + resolution commands |
| **Different clone strategies per repo** | Some need SSH, some HTTPS, some specific branches | Flexible repo spec syntax (`repo@branch`) |
| **Need automation in CI** | Interactive prompts break scripts | `--non-interactive` mode, JSON output, exit codes |
| **Public vs private repos** | Different auth requirements | Separate lists, automatic `gh` CLI integration |

ru brings order to your projects directory. It's the tool you wish existed every time you've thought "I should really update all my repos."

---

## ✨ Highlights

<table>
<tr>
<td width="50%">

### Zero-Setup Installation
One-liner installer handles everything:
- Checksum verification by default
- Auto-installs to `~/.local/bin`
- Detects missing `gh` CLI and prompts
- XDG-compliant configuration

</td>
<td width="50%">

### Automation-Grade Design
Built for scripting and CI from day one:
- Meaningful exit codes (0/1/2/3/4)
- `--json` mode for structured output
- `--non-interactive` for unattended runs
- `--dry-run` to preview changes

</td>
</tr>
<tr>
<td width="50%">

### Git Plumbing, Not String Parsing
Reliable status detection:
- `git rev-list --left-right` for ahead/behind
- `git status --porcelain` for dirty detection
- Never parses "Already up to date" text
- Locale-independent, version-safe

</td>
<td width="50%">

### Beautiful Terminal UI
Powered by [gum](https://github.com/charmbracelet/gum) with ANSI fallbacks:
- Styled progress indicators
- Boxed summary reports
- Color-coded status (green/yellow/red)
- Works without gum installed

</td>
</tr>
<tr>
<td width="50%">

### Subcommand Architecture
Clean CLI with focused commands:
- `sync` — Clone and pull repos
- `status` — Show status without changes
- `init` — Create configuration
- `add` — Add repo to list
- `doctor` — System diagnostics

</td>
<td width="50%">

### Conflict Resolution Help
Actionable commands for every issue:
- Dirty working tree? Stash/commit/discard options
- Diverged branches? Rebase/merge/push options
- Auth failed? Token/login instructions
- Copy-paste ready commands

</td>
</tr>
</table>

---

## ⚡ Quickstart

### Installation

**One-liner (recommended):**
```bash
curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/repo_updater/main/install.sh | bash
```

<details>
<summary><strong>Manual installation</strong></summary>

```bash
# Download script
curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/repo_updater/main/ru -o ~/.local/bin/ru
chmod +x ~/.local/bin/ru

# Ensure ~/.local/bin is in PATH
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc  # or ~/.bashrc
source ~/.zshrc
```

</details>

<details>
<summary><strong>Installation options</strong></summary>

```bash
# Custom install directory
DEST=/opt/bin curl -fsSL .../install.sh | bash

# System-wide installation (requires sudo)
RU_SYSTEM=1 curl -fsSL .../install.sh | bash

# Install specific version
RU_VERSION=1.0.0 curl -fsSL .../install.sh | bash

# Install from main branch (not recommended for production)
RU_UNSAFE_MAIN=1 curl -fsSL .../install.sh | bash
```

</details>

### First Run

```bash
# Initialize configuration
ru init

# Add some repos
ru add Dicklesworthstone/mcp_agent_mail
ru add Dicklesworthstone/beads_viewer

# Sync everything
ru sync
```

---

## 🛠️ Commands

```
ru [command] [options]
```

### Available Commands

| Command | Description |
|---------|-------------|
| `sync` | Clone missing repos and pull updates (default) |
| `status` | Show repository status without making changes |
| `init` | Initialize configuration directory and files |
| `add <repo>` | Add a repository to your list |
| `list` | Show configured repositories |
| `doctor` | Run system diagnostics |
| `self-update` | Update ru to the latest version |
| `config` | Show or set configuration values |

### Global Options

| Flag | Description |
|------|-------------|
| `--help`, `-h` | Show help message |
| `--version`, `-v` | Show version |
| `--json` | Output JSON to stdout (human output still goes to stderr) |
| `--quiet`, `-q` | Minimal output (errors only) |
| `--verbose` | Detailed output |
| `--non-interactive` | Never prompt (for CI/automation) |

### Command-Specific Options

**`ru sync`**
| Flag | Description |
|------|-------------|
| `--clone-only` | Only clone missing repos, don't pull |
| `--pull-only` | Only pull existing repos, don't clone |
| `--autostash` | Stash changes before pull, pop after |
| `--rebase` | Use `git pull --rebase` instead of merge |
| `--dry-run` | Show what would happen without making changes |
| `--dir PATH` | Override projects directory |

**`ru status`**
| Flag | Description |
|------|-------------|
| `--fetch` | Fetch remotes first (default) |
| `--no-fetch` | Skip fetch, use cached state |

**`ru add`**
| Flag | Description |
|------|-------------|
| `--private` | Add to private repos list |
| `--from-cwd` | Add the current directory's repo |

**`ru list`**
| Flag | Description |
|------|-------------|
| `--public` | Show only public repos |
| `--private` | Show only private repos |
| `--paths` | Show local paths instead of URLs |

**`ru self-update`**
| Flag | Description |
|------|-------------|
| `--check` | Check for updates without installing |

**`ru config`**
| Flag | Description |
|------|-------------|
| `--print` | Print all configuration values |
| `--set KEY=VALUE` | Set a configuration value |

---

## ⚙️ Configuration

ru uses [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html) for configuration.

### Directory Structure

```
~/.config/ru/
├── config                    # Main configuration file
└── repos.d/
    ├── public.txt            # Public repositories
    └── private.txt           # Private repositories

~/.cache/ru/
└── (runtime cache)

~/.local/state/ru/
├── logs/
│   ├── 2025-01-03/
│   │   ├── run.log           # Main run log
│   │   └── repos/
│   │       ├── mcp_agent_mail.log
│   │       └── beads_viewer.log
│   └── latest -> 2025-01-03  # Symlink to latest run
└── archived/                 # Orphan repos (from ru prune)
```

### Configuration File

```bash
# ~/.config/ru/config

# Base directory for repositories
PROJECTS_DIR=/data/projects

# Directory layout: flat | owner-repo | full
#   flat:       $PROJECTS_DIR/repo
#   owner-repo: $PROJECTS_DIR/owner/repo
#   full:       $PROJECTS_DIR/github.com/owner/repo
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

### Configuration Resolution

Priority (highest to lowest):
1. Command-line arguments (`--dir`, `--rebase`, etc.)
2. Environment variables (`RU_PROJECTS_DIR`, `RU_LAYOUT`, etc.)
3. Config file (`~/.config/ru/config`)
4. Built-in defaults

---

## 📝 Repo List Format

### Basic Format

```bash
# ~/.config/ru/repos.d/public.txt
# Lines starting with # are comments
# Empty lines are ignored

# Full URL
https://github.com/owner/repo

# Shorthand (assumes github.com)
owner/repo

# Pin to specific branch
owner/repo@develop

# Custom local directory name
owner/repo as custom-name

# SSH URL format
git@github.com:owner/repo.git
```

### Supported URL Formats

All of these are equivalent:

```
https://github.com/owner/repo
https://github.com/owner/repo.git
git@github.com:owner/repo.git
github.com/owner/repo
owner/repo
```

### Path Layout Examples

| Layout | Input | Local Path |
|--------|-------|------------|
| `flat` | `Dicklesworthstone/mcp_agent_mail` | `/data/projects/mcp_agent_mail` |
| `owner-repo` | `Dicklesworthstone/mcp_agent_mail` | `/data/projects/Dicklesworthstone/mcp_agent_mail` |
| `full` | `Dicklesworthstone/mcp_agent_mail` | `/data/projects/github.com/Dicklesworthstone/mcp_agent_mail` |

> **Note:** `flat` layout is the default for backwards compatibility with existing `/data/projects` structures. Use `owner-repo` if you have repos with the same name from different owners.

---

## 🔄 Sync Workflow

### What `ru sync` Does

```
┌─────────────────────────────────────────────────────────────────┐
│                        ru sync                                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │  Load repo      │
                    │  lists          │
                    └────────┬────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │  For each repo: │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
       ┌──────────┐   ┌──────────┐   ┌──────────┐
       │ Missing? │   │ Exists?  │   │ Mismatch?│
       │ → Clone  │   │ → Pull   │   │ → Warn   │
       └──────────┘   └──────────┘   └──────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │  Check status   │
                    │  (plumbing)     │
                    └────────┬────────┘
                             │
         ┌───────────────────┼───────────────────┐
         ▼                   ▼                   ▼
  ┌────────────┐     ┌────────────┐     ┌────────────┐
  │  current   │     │  behind    │     │  diverged  │
  │  → Skip    │     │  → Pull    │     │  → Report  │
  └────────────┘     └────────────┘     └────────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │  Write result   │
                    │  to log         │
                    └────────┬────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │  Print summary  │
                    │  + exit code    │
                    └─────────────────┘
```

### Per-Repo Processing

For each repository in your lists:

1. **Parse URL** — Extract host, owner, repo name
2. **Compute local path** — Based on layout configuration
3. **Check existence** — Does the directory exist?
4. **If missing** → Clone with `gh repo clone`
5. **If exists** → Verify remote URL matches, then check status
6. **Get status** — Using git plumbing (ahead/behind/dirty)
7. **Take action** — Pull if behind, skip if current, warn if diverged
8. **Log result** — Per-repo log file + NDJSON result

---

## 🔬 Git Status Detection

ru uses git plumbing commands for reliable status detection, never parsing human-readable output.

### Why Plumbing Matters

**Fragile approach (what other tools do):**
```bash
# This breaks with non-English locales!
if git pull 2>&1 | grep -q "Already up to date"; then
    echo "Current"
fi
```

**Robust approach (what ru does):**
```bash
# Works regardless of locale or git version
read -r ahead behind < <(git rev-list --left-right --count HEAD...@{u})
if [[ "$ahead" -eq 0 && "$behind" -eq 0 ]]; then
    echo "Current"
fi
```

### Status States

| State | Ahead | Behind | Meaning |
|-------|-------|--------|---------|
| `current` | 0 | 0 | Fully synchronized |
| `behind` | 0 | >0 | Remote has new commits |
| `ahead` | >0 | 0 | Local has unpushed commits |
| `diverged` | >0 | >0 | Both have new commits |
| `dirty` | — | — | Uncommitted local changes |
| `no_upstream` | — | — | No tracking branch set |

### Dirty Detection

```bash
# Empty output = clean working tree
if [[ -n $(git -C "$repo_path" status --porcelain 2>/dev/null) ]]; then
    dirty="true"
fi
```

---

## 🚨 Conflict Resolution

When ru encounters issues, it provides actionable resolution commands.

### Example Output

```
╭─────────────────────────────────────────────────────────────╮
│  ⚠️  Repositories Needing Attention                         │
╰─────────────────────────────────────────────────────────────╯

1. mcp_agent_mail
   Path:   /data/projects/mcp_agent_mail
   Branch: main
   Issue:  Dirty working tree (3 files modified)
   Log:    ~/.local/state/ru/logs/2025-01-03/repos/mcp_agent_mail.log

   Resolution options:
     a) Stash and pull:
        cd /data/projects/mcp_agent_mail && git stash && git pull && git stash pop

     b) Commit your changes:
        cd /data/projects/mcp_agent_mail && git add . && git commit -m "WIP"

     c) Discard local changes (DESTRUCTIVE):
        cd /data/projects/mcp_agent_mail && git checkout . && git clean -fd

2. beads_viewer
   Path:   /data/projects/beads_viewer
   Branch: main
   Issue:  Diverged (2 ahead, 5 behind)

   Resolution options:
     a) Rebase your changes:
        cd /data/projects/beads_viewer && git pull --rebase

     b) Merge (creates merge commit):
        cd /data/projects/beads_viewer && git pull --no-ff

     c) Push your changes first (if intentional):
        cd /data/projects/beads_viewer && git push
```

### Common Issues and Fixes

| Issue | Cause | Resolution |
|-------|-------|------------|
| Dirty working tree | Uncommitted changes | Stash, commit, or discard |
| Diverged | Local and remote both have commits | Rebase, merge, or push |
| No upstream | Branch doesn't track remote | `git branch --set-upstream-to=origin/main` |
| Remote mismatch | Different repo at same path | Remove directory or update list |
| Auth failed | gh not authenticated | `gh auth login` or set `GH_TOKEN` |

---

## 📤 Output Modes

### Default: Human-Readable (stderr)

Progress and results go to stderr, paths to stdout:

```bash
ru sync
# stderr: → Processing 1/47: mcp_agent_mail...
# stderr: ╭─────────── Summary ───────────╮
# stdout: /data/projects/mcp_agent_mail
# stdout: /data/projects/beads_viewer
```

### JSON Mode: `--json`

Structured output on stdout for scripting:

```bash
ru sync --json 2>/dev/null
```

```json
{
  "version": "1.0.0",
  "timestamp": "2025-01-03T14:30:00Z",
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
      "name": "mcp_agent_mail",
      "path": "/data/projects/mcp_agent_mail",
      "action": "pull",
      "status": "updated",
      "duration": 2
    }
  ]
}
```

**Parse with jq:**
```bash
# Get paths of all cloned repos
ru sync --json 2>/dev/null | jq -r '.repos[] | select(.action=="clone") | .path'

# Get count of failures
ru sync --json 2>/dev/null | jq '.summary.failed'
```

### Quiet Mode: `--quiet`

Only errors to stderr, still outputs paths to stdout:

```bash
ru sync --quiet
# Only shows errors, no progress
```

---

## 🔢 Exit Codes

ru uses meaningful exit codes for automation:

| Code | Meaning | When |
|------|---------|------|
| `0` | Success | All repos synced or already current |
| `1` | Partial failure | Some repos failed (network/auth/remote error) |
| `2` | Conflicts exist | Some repos have unresolved conflicts |
| `3` | Dependency error | gh CLI missing, auth failed, etc. |
| `4` | Invalid arguments | Bad CLI options, missing config files |

### Using in Scripts

```bash
#!/bin/bash
ru sync --non-interactive
exit_code=$?

case $exit_code in
    0) echo "All repos synchronized successfully" ;;
    1) echo "Some repos failed - check logs" ;;
    2) echo "Conflicts detected - manual resolution required" ;;
    3) echo "Missing dependencies - run 'ru doctor'" ;;
    4) echo "Invalid configuration" ;;
esac
```

### CI Usage

```yaml
# GitHub Actions example
- name: Sync repositories
  run: |
    ru sync --non-interactive --json > sync-results.json
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  continue-on-error: true

- name: Check sync status
  run: |
    if [ $? -eq 2 ]; then
      echo "::warning::Some repos have conflicts"
    fi
```

---

## 🏗️ Architecture

### Component Overview

```
ru (bash, ~800-1000 LOC)
├── Core Utilities
│   ├── is_interactive()      # TTY detection
│   ├── can_prompt()          # Interactive + non-CI
│   ├── ensure_dir()          # Create if missing
│   └── write_result()        # NDJSON logging
│
├── Configuration
│   ├── get_config_value()    # Read from file
│   ├── set_config_value()    # Write to file
│   └── resolve_config()      # CLI > env > file > default
│
├── Logging (stderr=human, stdout=data)
│   ├── log_info/warn/error() # Human messages
│   ├── log_step/success()    # Progress indicators
│   └── output_json()         # Structured output
│
├── Gum Integration
│   ├── check_gum()           # Availability check
│   ├── gum_confirm()         # Y/N with fallback
│   └── print_banner()        # Styled header
│
├── Dependency Management
│   ├── detect_os()           # macOS/Linux
│   ├── check_gh_*()          # Installed + authenticated
│   └── ensure_dependencies() # Full check flow
│
├── URL & Path Parsing
│   ├── parse_repo_url()      # Extract components
│   ├── normalize_url()       # Canonical form
│   └── url_to_local_path()   # Layout-aware path
│
├── Git Operations (no cd, plumbing-based)
│   ├── get_repo_status()     # Ahead/behind/dirty
│   ├── do_clone()            # gh repo clone
│   └── do_pull()             # Strategy-aware pull
│
├── Repo List Management
│   ├── load_repo_list()      # Parse list file
│   ├── parse_repo_spec()     # repo@branch syntax
│   └── detect_collisions()   # Path collision warning
│
├── Subcommand Implementations
│   ├── cmd_sync()            # Main sync logic
│   ├── cmd_status()          # Read-only check
│   ├── cmd_init()            # Create config
│   ├── cmd_add()             # Add to list
│   └── cmd_doctor()          # Diagnostics
│
└── Main & CLI Dispatch
    ├── show_help()           # Usage message
    ├── dispatch_command()    # Route to handler
    └── on_exit()             # Cleanup trap
```

### Data Flow

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Config    │────▶│  Repo List  │────▶│  Processing │
│   Files     │     │   Parser    │     │    Loop     │
└─────────────┘     └─────────────┘     └─────────────┘
                                               │
    ┌──────────────────────────────────────────┤
    ▼                    ▼                     ▼
┌─────────┐       ┌─────────────┐       ┌──────────┐
│  Clone  │       │   Status    │       │   Pull   │
│ (gh)    │       │ (plumbing)  │       │  (git)   │
└─────────┘       └─────────────┘       └──────────┘
    │                    │                     │
    └──────────────────────────────────────────┤
                                               ▼
                                        ┌─────────────┐
                                        │   Results   │
                                        │  (NDJSON)   │
                                        └──────────────┘
                                               │
                    ┌──────────────────────────┤
                    ▼                          ▼
             ┌─────────────┐           ┌─────────────┐
             │   Summary   │           │    JSON     │
             │  (stderr)   │           │  (stdout)   │
             └─────────────┘           └─────────────┘
```

---

## 🧭 Design Principles

### 1. No Global `cd`

ru never changes the working directory. All git operations use `git -C`:

```bash
# DO: Use git -C
git -C "$repo_path" status --porcelain
git -C "$repo_path" pull --ff-only

# DON'T: cd into directories
cd "$repo_path"     # Can fail, leaves state
git status          # Which directory are we in?
cd -                # Error-prone
```

### 2. Explicit Error Handling (No `set -e`)

ru uses `set -uo pipefail` but **not** `set -e`. This allows:
- Continuing after individual repo failures
- Capturing exit codes correctly
- Aggregating results for summary

```bash
# With set -e, this would exit before capturing exit_code:
output=$(failing_command); exit_code=$?

# ru's approach:
if output=$(git pull --ff-only 2>&1); then
    log_success "Pulled"
else
    exit_code=$?
    log_error "Failed: $output"
    # Continue to next repo
fi
```

### 3. Stream Separation

Human-readable output goes to stderr; data to stdout:

```bash
# Human messages → stderr
log_info "Syncing repos..." >&2
log_success "Done!" >&2

# Data → stdout (can be piped)
echo "$repo_path"        # For scripts
output_json "$data"      # For --json mode

# This works correctly:
ru sync --json | jq '.summary'
# Progress shows in terminal, JSON pipes to jq
```

### 4. Git Plumbing for Status

Never parse human-readable git output:

```bash
# WRONG: Locale-dependent, version-fragile
git pull 2>&1 | grep "Already up to date"

# RIGHT: Machine-readable plumbing
git rev-list --left-right --count HEAD...@{u}
git status --porcelain
git rev-parse HEAD
```

### 5. Prompted, Not Automatic

ru never auto-installs without asking:

```bash
# Interactive mode: ask first
if gum_confirm "GitHub CLI (gh) not found. Install now?"; then
    install_gh
fi

# Non-interactive mode: fail clearly
log_error "gh not installed. Run with --install-deps or install manually."
exit 3
```

---

## 🧭 Troubleshooting

### Common Issues

<details>
<summary><strong>"gh: command not found"</strong></summary>

**Cause:** GitHub CLI not installed.

**Fix:** Install gh and authenticate:
```bash
# macOS
brew install gh

# Ubuntu/Debian
sudo apt install gh

# Then authenticate
gh auth login
```

</details>

<details>
<summary><strong>"gh: auth required"</strong></summary>

**Cause:** gh CLI installed but not authenticated.

**Fixes:**
1. Interactive: `gh auth login`
2. Non-interactive: Set `GH_TOKEN` environment variable
```bash
export GH_TOKEN=ghp_xxxxxxxxxxxx
ru sync --non-interactive
```

</details>

<details>
<summary><strong>"Cannot fast-forward"</strong></summary>

**Cause:** Local and remote have diverged.

**Fixes:**
1. Rebase: `git pull --rebase`
2. Merge: `git pull --no-ff`
3. Use `--rebase` flag: `ru sync --rebase`
4. Push first if your changes are intentional

</details>

<details>
<summary><strong>"dirty working tree"</strong></summary>

**Cause:** Uncommitted local changes.

**Fixes:**
1. Stash: `git stash && git pull && git stash pop`
2. Commit: `git add . && git commit -m "WIP"`
3. Use `--autostash`: `ru sync --autostash`
4. Discard (careful!): `git checkout . && git clean -fd`

</details>

<details>
<summary><strong>Config directory doesn't exist</strong></summary>

**Cause:** First run without `ru init`.

**Fix:**
```bash
ru init
# Creates ~/.config/ru/ with default files
```

</details>

<details>
<summary><strong>Wrong repository cloned to path</strong></summary>

**Cause:** Path collision from different owners with same repo name.

**Fixes:**
1. Use `owner-repo` layout: `ru config --set LAYOUT=owner-repo`
2. Use custom name: `owner/repo as different-name`
3. Remove conflicting directory and re-sync

</details>

### Debug Mode

Check per-repo logs for detailed output:

```bash
# View latest run log
cat ~/.local/state/ru/logs/latest/run.log

# View specific repo log
cat ~/.local/state/ru/logs/latest/repos/mcp_agent_mail.log
```

### System Check

Run diagnostics:

```bash
ru doctor
```

Output includes:
- gh CLI installation and auth status
- Configuration file locations
- Directory permissions
- Network connectivity

---

## 🌐 Environment Variables

### Runtime Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `RU_PROJECTS_DIR` | Base directory for repos | `/data/projects` |
| `RU_LAYOUT` | Path layout (flat/owner-repo/full) | `flat` |
| `RU_CONFIG_DIR` | Configuration directory | `~/.config/ru` |
| `RU_LOG_DIR` | Log directory | `~/.local/state/ru/logs` |
| `GH_TOKEN` | GitHub token for authentication | (from gh CLI) |
| `CI` | Detected CI environment | unset |

### XDG Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `XDG_CONFIG_HOME` | Base config directory | `~/.config` |
| `XDG_STATE_HOME` | Base state directory | `~/.local/state` |
| `XDG_CACHE_HOME` | Base cache directory | `~/.cache` |

### Installer Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `DEST` | Install directory | `~/.local/bin` |
| `RU_SYSTEM` | Install to `/usr/local/bin` | unset |
| `RU_VERSION` | Specific version to install | latest |
| `RU_UNSAFE_MAIN` | Install from main branch | unset |

---

## 📦 Dependencies

### Required

| Dependency | Version | Purpose |
|------------|---------|---------|
| Bash | 4.0+ | Script runtime |
| git | 2.0+ | Repository operations |
| gh | 2.0+ | GitHub CLI for cloning |
| curl | any | Installation and updates |

### Optional

| Dependency | Purpose |
|------------|---------|
| gum | Beautiful terminal UI |
| jq | JSON processing (for scripts) |

### System Requirements

| Platform | Requirements |
|----------|--------------|
| macOS | macOS 10.15+ (Catalina or later) |
| Linux | glibc 2.17+ (Ubuntu 18.04+, Debian 10+) |

---

## 🛡️ Security & Privacy

### Security Features

- **Checksum verification:** Installer verifies SHA256 before installation
- **Release downloads:** Default installation from GitHub Releases, not main
- **No credential storage:** Uses gh CLI's secure credential storage
- **Prompted installation:** Never auto-installs without user confirmation

### Privacy

- **Local execution:** All processing happens on your machine
- **No telemetry:** No data sent anywhere except to GitHub (via gh)
- **No logging to remote:** All logs are local only
- **Config is local:** No cloud sync of configuration

### Audit

The entire codebase is a single bash script:

```bash
less ~/.local/bin/ru
```

---

## 🔧 Uninstallation

```bash
# Remove script
rm ~/.local/bin/ru

# Remove configuration
rm -rf ~/.config/ru

# Remove logs and state
rm -rf ~/.local/state/ru

# Remove cache
rm -rf ~/.cache/ru
```

---

## 🤝 Contributing

> *About Contributions:* Please don't take this the wrong way, but I do not accept outside contributions for any of my projects. I simply don't have the mental bandwidth to review anything, and it's my name on the thing, so I'm responsible for any problems it causes; thus, the risk-reward is highly asymmetric from my perspective. I'd also have to worry about other "stakeholders," which seems unwise for tools I mostly make for myself for free. Feel free to submit issues, and even PRs if you want to illustrate a proposed fix, but know I won't merge them directly. Instead, I'll have Claude or Codex review submissions via `gh` and independently decide whether and how to address them. Bug reports in particular are welcome. Sorry if this offends, but I want to avoid wasted time and hurt feelings. I understand this isn't in sync with the prevailing open-source ethos that seeks community contributions, but it's the only way I can move at this velocity and keep my sanity.

---

## 📄 License

MIT License. See [LICENSE](LICENSE) for details.

---

<div align="center">

**[Report Bug](https://github.com/Dicklesworthstone/repo_updater/issues) · [Request Feature](https://github.com/Dicklesworthstone/repo_updater/issues)**

---

<sub>Built with Bash, git plumbing, and a desire to never manually cd into 47 directories again.</sub>

</div>
