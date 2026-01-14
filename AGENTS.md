# AGENTS.md — repo_updater (ru) Project

## RULE 1 – ABSOLUTE (DO NOT EVER VIOLATE THIS)

You may NOT delete any file or directory unless I explicitly give the exact command **in this session**.

- This includes files you just created (tests, tmp files, scripts, etc.).
- You do not get to decide that something is "safe" to remove.
- If you think something should be removed, stop and ask. You must receive clear written approval **before** any deletion command is even proposed.

Treat "never delete files without permission" as a hard invariant.

---

## IRREVERSIBLE GIT & FILESYSTEM ACTIONS

Absolutely forbidden unless I give the **exact command and explicit approval** in the same message:

- `git reset --hard`
- `git clean -fd`
- `rm -rf`
- Any command that can delete or overwrite code/data

Rules:

1. If you are not 100% sure what a command will delete, do not propose or run it. Ask first.
2. Prefer safe tools: `git status`, `git diff`, `git stash`, copying to backups, etc.
3. After approval, restate the command verbatim, list what it will affect, and wait for confirmation.
4. When a destructive command is run, record in your response:
   - The exact user text authorizing it
   - The command run
   - When you ran it

If that audit trail is missing, then you must act as if the operation never happened.

---

## Shell / Bash Discipline

- This is a **pure Bash project**. The main script `ru` and `install.sh` are shell scripts.
- Target **Bash 4.0+** compatibility. Use `#!/usr/bin/env bash` shebang.
- Do NOT use `set -e` globally — handle errors explicitly to ensure processing continues after individual repo failures.
- Use `set -uo pipefail` instead.
- Use ShellCheck to lint all scripts. Address all warnings at severity `warning` or higher.

### Key Patterns from the Plan

- **No string parsing for git status** — use git plumbing commands (e.g., `git rev-list --left-right --count`)
- **No global `cd`** — always use `git -C "$repo_path"` instead
- **Stream separation** — stderr for human-readable output, stdout for structured data (JSON, paths)
- **Explicit error handling** — capture exit codes with `if output=$(cmd 2>&1); then ... else exit_code=$?; fi`

---

## Development Workspace Hygiene

**CRITICAL**: Do NOT create git worktrees, clones, or any other directories in `/data/projects/` (or the user's projects directory). This directory is managed by `ru` and should only contain repositories that are configured in `ru`.

### Forbidden Actions

- `git worktree add /data/projects/repo_updater_*` — creates clutter that confuses users
- Cloning repos to `/data/projects/` for "testing" or "exploration"
- Creating any subdirectories in the projects folder that aren't managed by `ru`

### Correct Approaches

For development/testing that requires separate working directories:

1. **Use `/tmp/`** — create temporary directories with `mktemp -d`
2. **Use the existing repo** — work in the current checkout, create branches if needed
3. **Clean up after yourself** — if you must create temporary files/dirs, remove them when done

The E2E tests demonstrate the correct pattern:
```bash
TEMP_DIR=$(mktemp -d)
export RU_PROJECTS_DIR="$TEMP_DIR/projects"
# ... run tests ...
rm -rf "$TEMP_DIR"  # cleanup
```

---

## Project Architecture

**ru** (repo_updater) is a robust, automation-friendly CLI tool that synchronizes a collection of GitHub repositories to a local projects directory.

### Key Features

- **One-liner curl-bash installation** with checksum verification by default
- **XDG-compliant configuration** with `ru init` for first-run setup
- **Automatic `gh` CLI detection** with prompted (not automatic) installation
- **Beautiful gum-powered terminal UI** with intelligent ANSI fallbacks
- **Intelligent clone/pull logic** using git plumbing (not string parsing)
- **Automation-grade design**: meaningful exit codes, non-interactive mode, JSON output
- **Subcommand architecture**: `sync`, `status`, `init`, `add`, `list`, `doctor`, `self-update`, `config`

### Subcommands

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

## Repo Layout

```
repo_updater/
├── ru                                    # Main script (~800-1000 LOC)
├── install.sh                            # Curl-bash installer (~250 LOC)
├── README.md                             # Comprehensive documentation
├── VERSION                               # Semver version file (e.g., "1.0.0")
├── LICENSE                               # MIT License
├── AGENTS.md                             # This file
├── PLAN_TO_CREATE_UPDATE_REPO_TOOL.md    # Detailed implementation plan
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

**Critical:** No `je_*.txt` files in repo. Those are examples only. User's actual lists live in XDG config (`~/.config/ru/repos.d/`).

---

## XDG Configuration Layout

```
~/.config/ru/
├── config                    # Key-value configuration
└── repos.d/
    ├── public.txt            # User's public repos
    └── private.txt           # User's private repos (optional)

~/.cache/ru/
└── (runtime cache)

~/.local/state/ru/
├── logs/
│   ├── YYYY-MM-DD/
│   │   ├── run.log           # Main run log
│   │   └── repos/
│   │       └── *.log         # Per-repo logs
│   └── latest -> YYYY-MM-DD  # Symlink to latest run
└── archived/                 # Orphan repos moved here by `ru prune`
```

---

## Exit Codes

| Code | Meaning | When |
|------|---------|------|
| `0` | Success | All repos synced or already current |
| `1` | Partial failure | Some repos failed (network/auth) |
| `2` | Conflicts exist | Some repos have conflicts needing resolution |
| `3` | Dependency/system error | gh missing, auth failed, doctor issues |
| `4` | Invalid arguments | Bad CLI options, missing files |
| `5` | Interrupted sync | Use `--resume` or `--restart` to continue |

---

## Generated Files — NEVER Edit Manually

**Current state:** There are **no checked-in generated source files** in this repo.

If/when we add generated artifacts:

- **Rule:** Never hand-edit generated outputs.
- **Convention:** Put generated outputs in a clearly labeled directory and document the generator command adjacent to it.

---

## Code Editing Discipline

- Do **not** run scripts that bulk-modify code (codemods, invented one-off scripts, giant `sed`/regex refactors).
- Large mechanical changes: break into smaller, explicit edits and review diffs.
- Subtle/complex changes: edit by hand, file-by-file, with careful reasoning.

---

## Backwards Compatibility & File Sprawl

We optimize for a clean architecture now, not backwards compatibility.

- No "compat shims" or "v2" file clones.
- When changing behavior, migrate callers and remove old code.
- New files are only for genuinely new domains that don't fit existing modules.
- The bar for adding files is very high.

---

## Console Output Design

This project has installer scripts (`install.sh`) and a CLI tool (`ru`).

Output stream rules:
- **stderr**: All human-readable output (progress, errors, summary, help)
- **stdout**: Only structured output (JSON in `--json` mode, paths otherwise)

Visual design:
- Use **gum** when available for beautiful terminal UI
- Fall back to ANSI color codes when gum is unavailable
- Non-interactive mode (`--non-interactive`) suppresses prompts for CI/automation

---

## Tooling Assumptions (recommended)

This section is a **developer toolbelt** reference.

### Shell & Terminal UX
- **zsh** + **oh-my-zsh** + **powerlevel10k**
- **lsd** (or eza fallback) — Modern ls
- **atuin** — Shell history with Ctrl-R
- **fzf** — Fuzzy finder
- **zoxide** — Better cd
- **direnv** — Directory-specific env vars

### Dev Tools
- **tmux** — Terminal multiplexer
- **ripgrep** (`rg`) — Fast search
- **ast-grep** (`sg`) — Structural search/replace
- **lazygit** — Git TUI
- **bat** — Better cat
- **gum** — Glamorous shell scripts (used by ru for UI)
- **ShellCheck** — Shell script linter

### Coding Agents
- **Claude Code** — Anthropic's coding agent
- **Codex CLI** — OpenAI's coding agent
- **Gemini CLI** — Google's coding agent

### Dependencies for ru
- **git** — Version control
- **gh** — GitHub CLI (for cloning private repos, auth)
- **curl** — For installer and self-update
- **jq** — JSON parsing (optional, for advanced scripting)

### Dicklesworthstone Stack (all 8 tools)
1. **ntm** — Named Tmux Manager (agent cockpit)
2. **mcp_agent_mail** — Agent coordination via mail-like messaging
3. **ultimate_bug_scanner** (`ubs`) — Bug scanning with guardrails
4. **beads_viewer** (`bv`) — Task management TUI
5. **coding_agent_session_search** (`cass`) — Unified agent history search
6. **cass_memory_system** (`cm`) — Procedural memory for agents
7. **coding_agent_account_manager** (`caam`) — Agent auth switching
8. **simultaneous_launch_button** (`slb`) — Two-person rule for dangerous commands

---

## MCP Agent Mail — Multi-Agent Coordination

Agent Mail is available as an MCP server for coordinating work across agents.

### CRITICAL: How Agents Access Agent Mail

**Coding agents (Claude Code, Codex, Gemini CLI) access Agent Mail NATIVELY via MCP tools.**

- You do NOT need to implement HTTP wrappers, client classes, or JSON-RPC handling
- MCP tools are available directly in your environment (e.g., `macro_start_session`, `send_message`, `fetch_inbox`)
- If MCP tools aren't available, flag it to the user — they may need to start the Agent Mail server

What Agent Mail gives:
- Identities, inbox/outbox, searchable threads.
- Advisory file reservations (leases) to avoid agents clobbering each other.
- Persistent artifacts in git (human-auditable).

Core patterns:

1. **Same repo**
   - Register identity:
     - `ensure_project` then `register_agent` with the repo's absolute path as `project_key`.
   - Reserve files before editing:
     - `file_reservation_paths(project_key, agent_name, ["ru", "install.sh"], ttl_seconds=3600, exclusive=true)`.
   - Communicate:
     - `send_message(..., thread_id="FEAT-123")`.
     - `fetch_inbox`, then `acknowledge_message`.
   - Fast reads:
     - `resource://inbox/{Agent}?project=<abs-path>&limit=20`.
     - `resource://thread/{id}?project=<abs-path>&include_bodies=true`.

2. **Macros vs granular:**
   - Prefer macros when speed is more important than fine-grained control:
     - `macro_start_session`, `macro_prepare_thread`, `macro_file_reservation_cycle`, `macro_contact_handshake`.
   - Use granular tools when you need explicit behavior.

Common pitfalls:
- "from_agent not registered" → call `register_agent` with correct `project_key`.
- `FILE_RESERVATION_CONFLICT` → adjust patterns, wait for expiry, or use non-exclusive reservation.

---

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - ShellCheck, syntax validation, tests
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds


---

## Issue Tracking with bd (beads)

All issue tracking goes through **bd**. No other TODO systems.

Key invariants:

- `.beads/` is authoritative state and **must always be committed** with code changes.
- Do not edit `.beads/*.jsonl` directly; only via `bd`.

### Basics

Check ready work:

```bash
bd ready --json
```

Create issues:

```bash
bd create "Issue title" -t bug|feature|task -p 0-4 --json
bd create "Issue title" -p 1 --deps discovered-from:bd-123 --json
```

Update:

```bash
bd update bd-42 --status in_progress --json
bd update bd-42 --priority 1 --json
```

Complete:

```bash
bd close bd-42 --reason "Completed" --json
```

Types:

- `bug`, `feature`, `task`, `epic`, `chore`

Priorities:

- `0` critical (security, data loss, broken builds)
- `1` high
- `2` medium (default)
- `3` low
- `4` backlog

Agent workflow:

1. `bd ready` to find unblocked work.
2. Claim: `bd update <id> --status in_progress`.
3. Implement + test.
4. If you discover new work, create a new bead with `discovered-from:<parent-id>`.
5. Close when done.
6. Commit `.beads/` in the same commit as code changes.

Auto-sync:

- bd exports to `.beads/issues.jsonl` after changes (debounced).
- It imports from JSONL when newer (e.g. after `git pull`).

Never:

- Use markdown TODO lists.
- Use other trackers.
- Duplicate tracking.

---

### Using bv as an AI sidecar

bv is a graph-aware triage engine for Beads projects (.beads/beads.jsonl). Instead of parsing JSONL or hallucinating graph traversal, use robot flags for deterministic, dependency-aware outputs with precomputed metrics (PageRank, betweenness, critical path, cycles, HITS, eigenvector, k-core).

**Scope boundary:** bv handles *what to work on* (triage, priority, planning). For agent-to-agent coordination (messaging, work claiming, file reservations), use MCP Agent Mail, which should be available to you as an MCP server (if it's not, then flag to the user; they might need to start Agent Mail using the `am` alias or by running `cd "<directory_where_they_installed_agent_mail>/mcp_agent_mail" && bash scripts/run_server_with_token.sh)' if the alias isn't available or isn't working.

**Use ONLY `--robot-*` flags. Bare `bv` launches an interactive TUI that blocks your session.**

#### The Workflow: Start With Triage

**`bv --robot-triage` is your single entry point.** It returns everything you need in one call:
- `quick_ref`: at-a-glance counts + top 3 picks
- `recommendations`: ranked actionable items with scores, reasons, unblock info
- `quick_wins`: low-effort high-impact items
- `blockers_to_clear`: items that unblock the most downstream work
- `project_health`: status/type/priority distributions, graph metrics
- `commands`: copy-paste shell commands for next steps

```bash
bv --robot-triage        # THE MEGA-COMMAND: start here
bv --robot-next          # Minimal: just the single top pick + claim command
```

#### Other bv Commands

**Planning:**
| Command | Returns |
|---------|---------|
| `--robot-plan` | Parallel execution tracks with `unblocks` lists |
| `--robot-priority` | Priority misalignment detection with confidence |

**Graph Analysis:**
| Command | Returns |
|---------|---------|
| `--robot-insights` | Full metrics: PageRank, betweenness, HITS, eigenvector, critical path, cycles, k-core, articulation points, slack |

Use bv instead of parsing beads.jsonl—it computes PageRank, critical paths, cycles, and parallel tracks deterministically.

---

### Morph Warp Grep — AI-Powered Code Search

Use `mcp__morph-mcp__warp_grep` for "how does X work?" discovery across the codebase.

When to use:

- You don't know where something lives.
- You want data flow across multiple files.
- You want all touchpoints of a cross-cutting concern.

Example:

```
mcp__morph-mcp__warp_grep(
  repoPath: "/data/projects/repo_updater",
  query: "How does URL parsing handle git@ SSH URLs?"
)
```

Warp Grep:

- Expands a natural-language query to multiple search patterns.
- Runs targeted greps, reads code, follows imports, then returns concise snippets with line numbers.
- Reduces token usage by returning only relevant slices, not entire files.

When **not** to use Warp Grep:

- You already know the function/identifier name; use `rg`.
- You know the exact file; just open it.
- You only need a yes/no existence check.

Comparison:

| Scenario | Tool |
| ---------------------------------- | ---------- |
| "How does gh auth check work?" | warp_grep |
| "Where is `parse_repo_url` defined?" | `rg` |
| "Replace `var` with `let`" | `ast-grep` |

---

### cass — Cross-Agent Search

`cass` indexes prior agent conversations (Claude Code, Codex, Cursor, Gemini, ChatGPT, etc.) so we can reuse solved problems.

Rules:

- Never run bare `cass` (TUI). Always use `--robot` or `--json`.

Examples:

```bash
cass health
cass search "bash error handling" --robot --limit 5
cass view /path/to/session.jsonl -n 42 --json
cass expand /path/to/session.jsonl -n 42 -C 3 --json
cass capabilities --json
cass robot-docs guide
```

Tips:

- Use `--fields minimal` for lean output.
- Filter by agent with `--agent`.
- Use `--days N` to limit to recent history.

stdout is data-only, stderr is diagnostics; exit code 0 means success.

Treat cass as a way to avoid re-solving problems other agents already handled.

---

## Memory System: cass-memory

The Cass Memory System (cm) is a tool for giving agents an effective memory based on the ability to quickly search across previous coding agent sessions and then reflect on what they find and learn in new sessions to draw out useful lessons and takeaways.

### Quick Start

```bash
# 1. Check status and see recommendations
cm onboard status

# 2. Get sessions to analyze (filtered by gaps in your playbook)
cm onboard sample --fill-gaps

# 3. Read a session with rich context
cm onboard read /path/to/session.jsonl --template

# 4. Add extracted rules (one at a time or batch)
cm playbook add "Your rule content" --category "debugging"

# 5. Mark session as processed
cm onboard mark-done /path/to/session.jsonl
```

Before starting complex tasks, retrieve relevant context:

```bash
cm context "<task description>" --json
```

This returns:
- **relevantBullets**: Rules that may help with your task
- **antiPatterns**: Pitfalls to avoid
- **historySnippets**: Past sessions that solved similar problems
- **suggestedCassQueries**: Searches for deeper investigation

### Protocol

1. **START**: Run `cm context "<task>" --json` before non-trivial work
2. **WORK**: Reference rule IDs when following them (e.g., "Following b-8f3a2c...")
3. **FEEDBACK**: Leave inline comments when rules help/hurt
4. **END**: Just finish your work. Learning happens automatically.

---

## UBS Quick Reference for AI Agents

UBS stands for "Ultimate Bug Scanner": **The AI Coding Agent's Secret Weapon: Flagging Likely Bugs for Fixing Early On**

**Golden Rule:** `ubs <changed-files>` before every commit. Exit 0 = safe. Exit >0 = fix & re-run.

**For Shell Scripts:**
```bash
ubs ru install.sh                         # Specific files (< 1s) — USE THIS
ubs $(git diff --name-only --cached)      # Staged files — before commit
ubs --only=bash scripts/                  # Language filter
ubs --ci --fail-on-warning .              # CI mode — before PR
ubs .                                     # Whole project
```

**Output Format:**
```
Warning  Category (N errors)
    file.sh:42:5 – Issue description
    Suggested fix
Exit code: 1
```
Parse: `file:line:col` -> location | Suggested fix -> how to fix | Exit 0/1 -> pass/fail

**Fix Workflow:**
1. Read finding -> category + fix suggestion
2. Navigate `file:line:col` -> view context
3. Verify real issue (not false positive)
4. Fix root cause (not symptom)
5. Re-run `ubs <file>` -> exit 0
6. Commit

**Speed Critical:** Scope to changed files. `ubs ru` (< 1s) vs `ubs .` (30s). Never full scan for small edits.

**Anti-Patterns:**
- Do not ignore findings -> Investigate each
- Do not full scan per edit -> Scope to file
- Do not fix symptom -> Fix root cause
