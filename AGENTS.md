# AGENTS.md — repo_updater

> Guidelines for AI coding agents working in this Bash codebase.

---

## RULE 0 - THE FUNDAMENTAL OVERRIDE PREROGATIVE

If I tell you to do something, even if it goes against what follows below, YOU MUST LISTEN TO ME. I AM IN CHARGE, NOT YOU.

---

## RULE NUMBER 1: NO FILE DELETION

**YOU ARE NEVER ALLOWED TO DELETE A FILE WITHOUT EXPRESS PERMISSION.** Even a new file that you yourself created, such as a test code file. You have a horrible track record of deleting critically important files or otherwise throwing away tons of expensive work. As a result, you have permanently lost any and all rights to determine that a file or folder should be deleted.

**YOU MUST ALWAYS ASK AND RECEIVE CLEAR, WRITTEN PERMISSION BEFORE EVER DELETING A FILE OR FOLDER OF ANY KIND.**

---

## Irreversible Git & Filesystem Actions — DO NOT EVER BREAK GLASS

1. **Absolutely forbidden commands:** `git reset --hard`, `git clean -fd`, `rm -rf`, or any command that can delete or overwrite code/data must never be run unless the user explicitly provides the exact command and states, in the same message, that they understand and want the irreversible consequences.
2. **No guessing:** If there is any uncertainty about what a command might delete or overwrite, stop immediately and ask the user for specific approval. "I think it's safe" is never acceptable.
3. **Safer alternatives first:** When cleanup or rollbacks are needed, request permission to use non-destructive options (`git status`, `git diff`, `git stash`, copying to backups) before ever considering a destructive command.
4. **Mandatory explicit plan:** Even after explicit user authorization, restate the command verbatim, list exactly what will be affected, and wait for a confirmation that your understanding is correct. Only then may you execute it—if anything remains ambiguous, refuse and escalate.
5. **Document the confirmation:** When running any approved destructive command, record (in the session notes / final response) the exact user text that authorized it, the command actually run, and the execution time. If that record is absent, the operation did not happen.

---

## Git Branch: ONLY Use `main`, NEVER `master`

**The default branch is `main`. The `master` branch exists only for legacy URL compatibility.**

- **All work happens on `main`** — commits, PRs, feature branches all merge to `main`
- **Never reference `master` in code or docs** — if you see `master` anywhere, it's a bug that needs fixing
- **The `master` branch must stay synchronized with `main`** — after pushing to `main`, also push to `master`:
  ```bash
  git push origin main:master
  ```

**If you see `master` referenced anywhere:**
1. Update it to `main`
2. Ensure `master` is synchronized: `git push origin main:master`

---

## Toolchain: Bash & ShellCheck

This is a **pure Bash project**. The main script `ru` and `install.sh` are shell scripts.

- **Shebang:** `#!/usr/bin/env bash`
- **Target:** Bash 4.0+ compatibility
- **Error handling:** `set -uo pipefail` (do NOT use `set -e` globally — handle errors explicitly to ensure processing continues after individual repo failures)
- **Linter:** ShellCheck — address all warnings at severity `warning` or higher
- **No build step:** No compilation; scripts are executed directly

### Shell Discipline

- **No string parsing for git status** — use git plumbing commands (e.g., `git rev-list --left-right --count`)
- **No global `cd`** — always use `git -C "$repo_path"` instead
- **Stream separation** — stderr for human-readable output, stdout for structured data (JSON, paths)
- **Explicit error handling** — capture exit codes with `if output=$(cmd 2>&1); then ... else exit_code=$?; fi`

### Key Dependencies

| Dependency | Purpose |
|------------|---------|
| `git` | Version control, clone/pull operations |
| `gh` | GitHub CLI (private repos, auth, API calls) |
| `curl` | Installer and self-update downloads |
| `jq` | JSON parsing (optional, for advanced scripting) |
| `gum` | Beautiful terminal UI (optional, ANSI fallback when absent) |
| `ShellCheck` | Shell script linting |

---

## Code Editing Discipline

### No Script-Based Changes

**NEVER** run a script that processes/changes code files in this repo. Brittle regex-based transformations create far more problems than they solve.

- **Always make code changes manually**, even when there are many instances
- For many simple changes: use parallel subagents
- For subtle/complex changes: do them methodically yourself

### No File Proliferation

If you want to change something or add a feature, **revise existing code files in place**.

**NEVER** create variations like:
- `ru_v2`
- `ru_improved`
- `install_enhanced.sh`

New files are reserved for **genuinely new functionality** that makes zero sense to include in any existing file. The bar for creating new files is **incredibly high**.

---

## Backwards Compatibility

We do not care about backwards compatibility—we're in early development with no users. We want to do things the **RIGHT** way with **NO TECH DEBT**.

- Never create "compatibility shims"
- Never create wrapper functions for deprecated APIs
- Just fix the code directly

---

## Compiler Checks (CRITICAL)

**After any substantive code changes, you MUST verify no errors were introduced:**

```bash
# Check for ShellCheck warnings (main script + installer)
shellcheck -s bash -S warning ru install.sh

# Verify syntax of all shell scripts
bash -n ru
bash -n install.sh
for f in scripts/*.sh; do bash -n "$f"; done

# Run the full test suite
bash scripts/run_all_tests.sh
```

If you see errors, **carefully understand and resolve each issue**. Read sufficient context to fix them the RIGHT way.

---

## Testing

### Testing Policy

All tests are shell scripts in `scripts/`. Tests must cover:
- Happy path
- Edge cases (empty input, missing files, boundary conditions)
- Error conditions

### Running Tests

```bash
# Run the full test suite
bash scripts/run_all_tests.sh

# Run a specific test file
bash scripts/test_unit_parsing_functions.sh
bash scripts/test_e2e_sync_workflow.sh
bash scripts/test_local_git.sh

# Run unit tests by category
bash scripts/test_unit_argument_parsing.sh
bash scripts/test_unit_config.sh
bash scripts/test_unit_core_utils.sh
bash scripts/test_unit_repo_list.sh
```

### Test Categories

| Category | Focus Areas |
|----------|-------------|
| `test_unit_*.sh` | Individual function testing: parsing, config, utilities, gum wrappers, state locking, review, worktree, checkpoint, completions |
| `test_e2e_*.sh` | End-to-end workflows: sync, clone, pull, status, init, config, add/remove, prune, doctor, self-update, review, fork operations |
| `test_local_git.sh` | Integration tests with local git repositories |
| `test_parsing.sh` | URL parsing tests |
| `test_security_guardrails.sh` | Security-related test coverage |
| `test_framework.sh` | Test framework infrastructure itself |
| `test_coverage.sh` | Test coverage analysis |

### Test Fixtures

Test fixtures live in `test/fixtures/`:
- `gh/graphql_batch.json` — Mock GitHub GraphQL API responses
- `plans/*.json` — Plan validation test cases (valid, invalid, edge cases)

### Development Workspace Hygiene

**CRITICAL**: Do NOT create git worktrees, clones, or any other directories in `/data/projects/` (or the user's projects directory). This directory is managed by `ru` and should only contain repositories that are configured in `ru`.

**Forbidden Actions:**
- `git worktree add /data/projects/repo_updater_*` — creates clutter that confuses users
- Cloning repos to `/data/projects/` for "testing" or "exploration"
- Creating any subdirectories in the projects folder that are not managed by `ru`

**Correct Approaches:**
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

## Third-Party Library Usage

If you aren't 100% sure how to use a third-party library, **SEARCH ONLINE** to find the latest documentation and current best practices.

---

## repo_updater — This Project

**This is the project you're working on.** repo_updater (`ru`) is a robust, automation-friendly CLI tool that synchronizes a collection of GitHub repositories to a local projects directory.

### What It Does

One-liner curl-bash installation with checksum verification. XDG-compliant configuration. Automatic `gh` CLI detection. Beautiful gum-powered terminal UI with ANSI fallbacks. Intelligent clone/pull logic using git plumbing (not string parsing). Automation-grade design with meaningful exit codes, non-interactive mode, and JSON output.

### Subcommand Architecture

| Command | Purpose | Key Options |
|---------|---------|-------------|
| `sync` | Clone/pull repositories | `--clone-only`, `--pull-only`, `--autostash`, `--rebase`, `--dry-run` |
| `status` | Show repo status (read-only) | `--fetch` (default), `--no-fetch` |
| `init` | Create config directory and files | `--example` (include example repos) |
| `add` | Add repo to list | `--private`, `--from-cwd` |
| `list` | Show configured repos | `--public`, `--private`, `--paths` |
| `doctor` | System diagnostics | (none) |
| `self-update` | Update ru | `--check` (check only, do not update) |
| `config` | Show/set configuration | `--print`, `--set KEY=VALUE` |
| `robot-docs` | Machine-readable CLI docs (JSON) | `<topic>`: quickstart, commands, examples, exit-codes, formats, schemas, all |

### Repo Layout

```
repo_updater/
├── ru                                    # Main script (~22K LOC)
├── install.sh                            # Curl-bash installer (~860 LOC)
├── VERSION                               # Semver version file (e.g., "1.2.1")
├── README.md                             # Comprehensive documentation
├── AGENTS.md                             # This file
├── LICENSE                               # MIT License
├── PLAN_TO_CREATE_UPDATE_REPO_TOOL.md    # Detailed implementation plan
├── .gitignore                            # Ignore runtime artifacts
├── .github/
│   └── workflows/
│       ├── ci.yml                        # ShellCheck, syntax, behavioral tests
│       └── release.yml                   # GitHub releases with checksums
├── scripts/
│   ├── run_all_tests.sh                  # Master test runner
│   ├── test_framework.sh                 # Test framework infrastructure
│   ├── test_stubs.sh                     # Test stubs/mocks
│   ├── test_unit_*.sh                    # Unit tests (~40 files)
│   ├── test_e2e_*.sh                     # E2E tests (~20 files)
│   ├── test_local_git.sh                 # Local git integration tests
│   ├── test_parsing.sh                   # URL parsing tests
│   └── test_coverage.sh                  # Coverage analysis
├── test/
│   └── fixtures/
│       ├── gh/graphql_batch.json         # Mock GitHub API responses
│       └── plans/*.json                  # Plan validation fixtures
└── examples/
    ├── public.txt                        # Example public repos list
    ├── private.template.txt              # Empty template for private repos
    └── github-review.yaml                # Example review configuration
```

**Critical:** No `je_*.txt` files in repo. Those are examples only. User's actual lists live in XDG config (`~/.config/ru/repos.d/`).

### XDG Configuration Layout

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

### Exit Codes

| Code | Meaning | When |
|------|---------|------|
| `0` | Success | All repos synced or already current |
| `1` | Partial failure | Some repos failed (network/auth) |
| `2` | Conflicts exist | Some repos have conflicts needing resolution |
| `3` | Dependency/system error | gh missing, auth failed, doctor issues |
| `4` | Invalid arguments | Bad CLI options, missing files |
| `5` | Interrupted sync | Use `--resume` or `--restart` to continue |

### Console Output Design

Output stream rules:
- **stderr**: All human-readable output (progress, errors, summary, help)
- **stdout**: Only structured output (JSON in `--json` mode, paths otherwise)

Visual design:
- Use **gum** when available for beautiful terminal UI
- Fall back to ANSI color codes when gum is unavailable
- Non-interactive mode (`--non-interactive`) suppresses prompts for CI/automation

### Generated Files — NEVER Edit Manually

**Current state:** There are **no checked-in generated source files** in this repo.

If/when we add generated artifacts:

- **Rule:** Never hand-edit generated outputs.
- **Convention:** Put generated outputs in a clearly labeled directory and document the generator command adjacent to it.

---

## MCP Agent Mail — Multi-Agent Coordination

A mail-like layer that lets coding agents coordinate asynchronously via MCP tools and resources. Provides identities, inbox/outbox, searchable threads, and advisory file reservations with human-auditable artifacts in Git.

### Why It's Useful

- **Prevents conflicts:** Explicit file reservations (leases) for files/globs
- **Token-efficient:** Messages stored in per-project archive, not in context
- **Quick reads:** `resource://inbox/...`, `resource://thread/...`

### Same Repository Workflow

1. **Register identity:**
   ```
   ensure_project(project_key=<abs-path>)
   register_agent(project_key, program, model)
   ```

2. **Reserve files before editing:**
   ```
   file_reservation_paths(project_key, agent_name, ["ru", "install.sh"], ttl_seconds=3600, exclusive=true)
   ```

3. **Communicate with threads:**
   ```
   send_message(..., thread_id="FEAT-123")
   fetch_inbox(project_key, agent_name)
   acknowledge_message(project_key, agent_name, message_id)
   ```

4. **Quick reads:**
   ```
   resource://inbox/{Agent}?project=<abs-path>&limit=20
   resource://thread/{id}?project=<abs-path>&include_bodies=true
   ```

### Macros vs Granular Tools

- **Prefer macros for speed:** `macro_start_session`, `macro_prepare_thread`, `macro_file_reservation_cycle`, `macro_contact_handshake`
- **Use granular tools for control:** `register_agent`, `file_reservation_paths`, `send_message`, `fetch_inbox`, `acknowledge_message`

### Common Pitfalls

- `"from_agent not registered"`: Always `register_agent` in the correct `project_key` first
- `"FILE_RESERVATION_CONFLICT"`: Adjust patterns, wait for expiry, or use non-exclusive reservation
- **Auth errors:** If JWT+JWKS enabled, include bearer token with matching `kid`

---

## Beads (br) — Dependency-Aware Issue Tracking

Beads provides a lightweight, dependency-aware issue database and CLI (`br` - beads_rust) for selecting "ready work," setting priorities, and tracking status. It complements MCP Agent Mail's messaging and file reservations.

**Important:** `br` is non-invasive—it NEVER runs git commands automatically. You must manually commit changes after `br sync --flush-only`.

**SQLite/WAL Caution:** br uses SQLite with WAL mode. Always run `br sync --flush-only` before git operations to ensure `.beads/` files are consistent.

### Conventions

- **Single source of truth:** Beads for task status/priority/dependencies; Agent Mail for conversation and audit
- **Shared identifiers:** Use Beads issue ID (e.g., `br-123`) as Mail `thread_id` and prefix subjects with `[br-123]`
- **Reservations:** When starting a task, call `file_reservation_paths()` with the issue ID in `reason`

### Typical Agent Flow

1. **Pick ready work (Beads):**
   ```bash
   br ready --json  # Choose highest priority, no blockers
   ```

2. **Reserve edit surface (Mail):**
   ```
   file_reservation_paths(project_key, agent_name, ["ru", "install.sh"], ttl_seconds=3600, exclusive=true, reason="br-123")
   ```

3. **Announce start (Mail):**
   ```
   send_message(..., thread_id="br-123", subject="[br-123] Start: <title>", ack_required=true)
   ```

4. **Work and update:** Reply in-thread with progress

5. **Complete and release:**
   ```bash
   br close 123 --reason "Completed"
   br sync --flush-only  # Export to JSONL (no git operations)
   ```
   ```
   release_file_reservations(project_key, agent_name, paths=["ru", "install.sh"])
   ```
   Final Mail reply: `[br-123] Completed` with summary

### Mapping Cheat Sheet

| Concept | Value |
|---------|-------|
| Mail `thread_id` | `br-###` |
| Mail subject | `[br-###] ...` |
| File reservation `reason` | `br-###` |
| Commit messages | Include `br-###` for traceability |

---

## bv — Graph-Aware Triage Engine

bv is a graph-aware triage engine for Beads projects (`.beads/beads.jsonl`). It computes PageRank, betweenness, critical path, cycles, HITS, eigenvector, and k-core metrics deterministically.

**Scope boundary:** bv handles *what to work on* (triage, priority, planning). For agent-to-agent coordination (messaging, work claiming, file reservations), use MCP Agent Mail.

**CRITICAL: Use ONLY `--robot-*` flags. Bare `bv` launches an interactive TUI that blocks your session.**

### The Workflow: Start With Triage

**`bv --robot-triage` is your single entry point.** It returns:
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

### Command Reference

**Planning:**
| Command | Returns |
|---------|---------|
| `--robot-plan` | Parallel execution tracks with `unblocks` lists |
| `--robot-priority` | Priority misalignment detection with confidence |

**Graph Analysis:**
| Command | Returns |
|---------|---------|
| `--robot-insights` | Full metrics: PageRank, betweenness, HITS, eigenvector, critical path, cycles, k-core, articulation points, slack |
| `--robot-label-health` | Per-label health: `health_level`, `velocity_score`, `staleness`, `blocked_count` |
| `--robot-label-flow` | Cross-label dependency: `flow_matrix`, `dependencies`, `bottleneck_labels` |
| `--robot-label-attention [--attention-limit=N]` | Attention-ranked labels |

**History & Change Tracking:**
| Command | Returns |
|---------|---------|
| `--robot-history` | Bead-to-commit correlations |
| `--robot-diff --diff-since <ref>` | Changes since ref: new/closed/modified issues, cycles |

**Other:**
| Command | Returns |
|---------|---------|
| `--robot-burndown <sprint>` | Sprint burndown, scope changes, at-risk items |
| `--robot-forecast <id\|all>` | ETA predictions with dependency-aware scheduling |
| `--robot-alerts` | Stale issues, blocking cascades, priority mismatches |
| `--robot-suggest` | Hygiene: duplicates, missing deps, label suggestions |
| `--robot-graph [--graph-format=json\|dot\|mermaid]` | Dependency graph export |
| `--export-graph <file.html>` | Interactive HTML visualization |

### Scoping & Filtering

```bash
bv --robot-plan --label backend              # Scope to label's subgraph
bv --robot-insights --as-of HEAD~30          # Historical point-in-time
bv --recipe actionable --robot-plan          # Pre-filter: ready to work
bv --recipe high-impact --robot-triage       # Pre-filter: top PageRank
bv --robot-triage --robot-triage-by-track    # Group by parallel work streams
bv --robot-triage --robot-triage-by-label    # Group by domain
```

### Understanding Robot Output

**All robot JSON includes:**
- `data_hash` — Fingerprint of source beads.jsonl
- `status` — Per-metric state: `computed|approx|timeout|skipped` + elapsed ms
- `as_of` / `as_of_commit` — Present when using `--as-of`

**Two-phase analysis:**
- **Phase 1 (instant):** degree, topo sort, density
- **Phase 2 (async, 500ms timeout):** PageRank, betweenness, HITS, eigenvector, cycles

### jq Quick Reference

```bash
bv --robot-triage | jq '.quick_ref'                        # At-a-glance summary
bv --robot-triage | jq '.recommendations[0]'               # Top recommendation
bv --robot-plan | jq '.plan.summary.highest_impact'        # Best unblock target
bv --robot-insights | jq '.status'                         # Check metric readiness
bv --robot-insights | jq '.Cycles'                         # Circular deps (must fix!)
```

---

## UBS — Ultimate Bug Scanner

**Golden Rule:** `ubs <changed-files>` before every commit. Exit 0 = safe. Exit >0 = fix & re-run.

### Commands

```bash
ubs ru install.sh                          # Specific files (< 1s) — USE THIS
ubs $(git diff --name-only --cached)       # Staged files — before commit
ubs --only=bash scripts/                   # Language filter
ubs --ci --fail-on-warning .               # CI mode — before PR
ubs .                                      # Whole project
```

### Output Format

```
Warning  Category (N errors)
    file.sh:42:5 – Issue description
    Suggested fix
Exit code: 1
```

Parse: `file:line:col` -> location | Suggested fix -> how to fix | Exit 0/1 -> pass/fail

### Fix Workflow

1. Read finding -> category + fix suggestion
2. Navigate `file:line:col` -> view context
3. Verify real issue (not false positive)
4. Fix root cause (not symptom)
5. Re-run `ubs <file>` -> exit 0
6. Commit

### Bug Severity

- **Critical (always fix):** Command injection, unquoted variables, path traversal
- **Important (production):** Unhandled exit codes, missing error messages, resource leaks
- **Contextual (judgment):** TODO/FIXME, echo debugging

---

## RCH — Remote Compilation Helper

RCH offloads `cargo build`, `cargo test`, `cargo clippy`, and other compilation commands to a fleet of 8 remote Contabo VPS workers instead of building locally. This prevents compilation storms from overwhelming csd when many agents run simultaneously.

**RCH is installed at `~/.local/bin/rch` and is hooked into Claude Code's PreToolUse automatically.** Most of the time you don't need to do anything if you are Claude Code — builds are intercepted and offloaded transparently.

To manually offload a build:
```bash
rch exec -- cargo build --release
rch exec -- cargo test
rch exec -- cargo clippy
```

Quick commands:
```bash
rch doctor                    # Health check
rch workers probe --all       # Test connectivity to all 8 workers
rch status                    # Overview of current state
rch queue                     # See active/waiting builds
```

If rch or its workers are unavailable, it fails open — builds run locally as normal.

**Note for Codex/GPT-5.2:** Codex does not have the automatic PreToolUse hook, but you can (and should) still manually offload compute-intensive compilation commands using `rch exec -- <command>`. This avoids local resource contention when multiple agents are building simultaneously.

---

## ast-grep vs ripgrep

**Use `ast-grep` when structure matters.** It parses code and matches AST nodes, ignoring comments/strings, and can **safely rewrite** code.

- Refactors/codemods: rename APIs, change import forms
- Policy checks: enforce patterns across a repo
- Editor/automation: LSP mode, `--json` output

**Use `ripgrep` when text is enough.** Fastest way to grep literals/regex.

- Recon: find strings, TODOs, log lines, config values
- Pre-filter: narrow candidate files before ast-grep

### Rule of Thumb

- Need correctness or **applying changes** -> `ast-grep`
- Need raw speed or **hunting text** -> `rg`
- Often combine: `rg` to shortlist files, then `ast-grep` to match/modify

### Shell Examples

```bash
# Find structured code (ignores comments)
ast-grep run -l Bash -p 'if $COND; then $$$BODY fi'

# Quick textual hunt
rg -n 'set -e' -t sh

# Combine speed + precision
rg -l -t sh 'parse_repo_url' | xargs ast-grep run -l Bash --json
```

---

## Morph Warp Grep — AI-Powered Code Search

**Use `mcp__morph-mcp__warp_grep` for exploratory "how does X work?" questions.** An AI agent expands your query, greps the codebase, reads relevant files, and returns precise line ranges with full context.

**Use `ripgrep` for targeted searches.** When you know exactly what you're looking for.

**Use `ast-grep` for structural patterns.** When you need AST precision for matching/rewriting.

### When to Use What

| Scenario | Tool | Why |
|----------|------|-----|
| "How does gh auth check work?" | `warp_grep` | Exploratory; don't know where to start |
| "How does URL parsing handle git@ SSH URLs?" | `warp_grep` | Need to understand architecture |
| "Find all uses of `parse_repo_url`" | `ripgrep` | Targeted literal search |
| "Find files with `set -e`" | `ripgrep` | Simple pattern |
| "Replace all `var` with `let`" | `ast-grep` | Structural refactor |

### warp_grep Usage

```
mcp__morph-mcp__warp_grep(
  repoPath: "/dp/repo_updater",
  query: "How does URL parsing handle git@ SSH URLs?"
)
```

Returns structured results with file paths, line ranges, and extracted code snippets.

### Anti-Patterns

- **Don't** use `warp_grep` to find a specific function name -> use `ripgrep`
- **Don't** use `ripgrep` to understand "how does X work" -> wastes time with manual reads
- **Don't** use `ripgrep` for codemods -> risks collateral edits

---

## cass — Cross-Agent Search

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

<!-- bv-agent-instructions-v1 -->

---

## Beads Workflow Integration

This project uses [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`) for issue tracking. Issues are stored in `.beads/` and tracked in git.

**Important:** `br` is non-invasive—it NEVER executes git commands. After `br sync --flush-only`, you must manually run `git add .beads/ && git commit`.

### Essential Commands

```bash
# View issues (launches TUI - avoid in automated sessions)
bv

# CLI commands for agents (use these instead)
br ready              # Show issues ready to work (no blockers)
br list --status=open # All open issues
br show <id>          # Full issue details with dependencies
br create --title="..." --type=task --priority=2
br update <id> --status=in_progress
br close <id> --reason "Completed"
br close <id1> <id2>  # Close multiple issues at once
br sync --flush-only  # Export to JSONL (NO git operations)
```

### Workflow Pattern

1. **Start**: Run `br ready` to find actionable work
2. **Claim**: Use `br update <id> --status=in_progress`
3. **Work**: Implement the task
4. **Complete**: Use `br close <id>`
5. **Sync**: Run `br sync --flush-only` then manually commit

### Key Concepts

- **Dependencies**: Issues can block other issues. `br ready` shows only unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers, not words)
- **Types**: task, bug, feature, epic, chore
- **Blocking**: `br dep add <issue> <depends-on>` to add dependencies

### Session Protocol

**Before ending any session, run this checklist:**

```bash
git status              # Check what changed
git add <files>         # Stage code changes
br sync --flush-only    # Export beads to JSONL
git add .beads/         # Stage beads changes
git commit -m "..."     # Commit everything together
git push                # Push to remote
```

### Best Practices

- Check `br ready` at session start to find available work
- Update status as you work (in_progress -> closed)
- Create new issues with `br create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Always `br sync --flush-only && git add .beads/` before ending session

<!-- end-bv-agent-instructions -->

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Sync beads** - `br sync --flush-only` to export to JSONL
5. **Hand off** - Provide context for next session


---

Note for Codex/GPT-5.2:

You constantly bother me and stop working with concerned questions that look similar to this:

```
Unexpected changes (need guidance)

- Working tree still shows edits I did not make in ru, install.sh, scripts/test_unit_parsing_functions.sh. Please advise whether to keep/commit/revert these before any further work. I did not touch them.

Next steps (pick one)

1. Decide how to handle the unrelated modified files above so we can resume cleanly.
2. Triage open beads issues.
3. If you want a full suite run later, fix ShellCheck blockers and re-run.
```

NEVER EVER DO THAT AGAIN. The answer is literally ALWAYS the same: those are changes created by the potentially dozen of other agents working on the project at the same time. This is not only a common occurrence, it happens multiple times PER MINUTE. The way to deal with it is simple: you NEVER, under ANY CIRCUMSTANCE, stash, revert, overwrite, or otherwise disturb in ANY way the work of other agents. Just treat those changes identically to changes that you yourself made. Just fool yourself into thinking YOU made the changes and simply don't recall it for some reason.

---

## Note on Built-in TODO Functionality

Also, if I ask you to explicitly use your built-in TODO functionality, don't complain about this and say you need to use beads. You can use built-in TODOs if I tell you specifically to do so. Always comply with such orders.
