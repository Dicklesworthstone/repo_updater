# Extending ru for Automated Reviews of GitHub Issues and PRs Using Claude Code

## Executive Summary

This proposal outlines a comprehensive system for automating the review of GitHub issues and pull requests across multiple repositories using Claude Code as the AI agent. The goal is to transform a manual, time-consuming process into an orchestrated workflow that only surfaces decisions requiring human judgment.

**Key Innovation**: By leveraging Claude Code's stream-json output mode, ntm's sophisticated activity detection (velocity-based state classification with hysteresis), and a priority-scored question queue, we can process dozens of repositories in parallel while presenting a unified, intuitive interface for human decision-making.

---

## Table of Contents

1. [Background: What is ru?](#1-background-what-is-ru)
2. [The Problem We're Solving](#2-the-problem-were-solving)
3. [Current Manual Workflow](#3-current-manual-workflow)
4. [Desired Automated Workflow](#4-desired-automated-workflow)
5. [Architecture Options Analysis](#5-architecture-options-analysis)
6. [Recommended Architecture](#6-recommended-architecture)
7. [Implementation Plan](#7-implementation-plan)
8. [Technical Deep Dive: Claude Code Automation](#8-technical-deep-dive-claude-code-automation)
9. [Technical Deep Dive: ntm Integration](#9-technical-deep-dive-ntm-integration)
10. [Performance Optimization Strategies](#10-performance-optimization-strategies)
11. [Priority Scoring Algorithm](#11-priority-scoring-algorithm)
12. [TUI Design](#12-tui-design)
13. [Error Handling and Recovery](#13-error-handling-and-recovery)
14. [Security Considerations](#14-security-considerations)
15. [Metrics, Analytics, and Learning](#15-metrics-analytics-and-learning)
16. [Real-World Edge Cases](#16-real-world-edge-cases)
17. [Risk Mitigation](#17-risk-mitigation)
18. [Future Enhancements](#18-future-enhancements)

---

## 1. Background: What is ru?

### 1.1 Overview

**ru (Repo Updater)** is a pure Bash CLI tool (~3,800 lines) for synchronizing GitHub repositories. It provides a beautiful, automation-friendly interface for managing collections of repositories - cloning new ones, pulling updates, checking status, and maintaining configuration.

### 1.2 Core Capabilities

| Command | Description |
|---------|-------------|
| `sync` | Clone missing repos and pull updates for existing ones |
| `status` | Show repository status without making changes |
| `import` | Import repos from files with auto visibility detection |
| `prune` | Find and manage orphan repositories |
| `add/remove` | Manage repository list |
| `self-update` | Update ru with checksum verification |
| `doctor` | System diagnostics |

### 1.3 Technical Implementation

ru is implemented as a single Bash script (`ru`) with these characteristics:

```bash
# Core design principles
#!/usr/bin/env bash
set -uo pipefail  # NOT set -e (explicit error handling)

# Key architectural patterns:
# - XDG Base Directory Specification compliance
# - Git plumbing commands (not porcelain) for reliable status
# - Flock-based parallel sync work queue
# - NDJSON output for results tracking
# - Gum integration with ANSI fallback for TUI
# - Nameref-based function output (Bash 4.3+)
```

### 1.4 Configuration Structure

```
~/.config/ru/
├── config                 # Main configuration (PROJECTS_DIR, LAYOUT, etc.)
└── repos.d/
    ├── repos.txt          # Primary repository list
    ├── work.txt           # Work repositories
    └── personal.txt       # Personal projects

~/.local/state/ru/
├── sync-state.json        # Resume state for interrupted syncs
├── review-state.json      # Review tracking (NEW)
└── logs/                  # Operation logs
```

### 1.5 Repository Specification Format

```bash
# Basic formats
owner/repo                      # GitHub shorthand
owner/repo@develop              # Branch pinning
owner/repo as myname            # Custom local directory name
owner/repo@main as custom       # Combined

# Full URLs
https://github.com/owner/repo   # HTTPS
git@github.com:owner/repo       # SSH
https://gitlab.com/owner/repo   # Non-GitHub hosts
```

---

## 2. The Problem We're Solving

### 2.1 The Maintainer's Dilemma

Developers who create many open-source projects face an impossible scaling problem:

| Challenge | Impact |
|-----------|--------|
| **Volume** | Dozens or hundreds of repositories across domains |
| **Bandwidth** | No time for manual review of issues and PRs |
| **Quality** | Still want to maintain quality and respond to users |
| **Risk** | External contributions carry responsibility |
| **Context Switching** | Each repo requires deep understanding |
| **Staleness** | Issues become outdated as code evolves |

### 2.2 The Contribution Policy

The maintainer has adopted this policy (disclosed to users):

> *About Contributions:* Please don't take this the wrong way, but I do not accept outside contributions for any of my projects. I simply don't have the mental bandwidth to review anything, and it's my name on the thing, so I'm responsible for any problems it causes; thus, the risk-reward is highly asymmetric from my perspective. I'd also have to worry about other "stakeholders," which seems unwise for tools I mostly make for myself for free. Feel free to submit issues, and even PRs if you want to illustrate a proposed fix, but know I won't merge them directly. Instead, I'll have Claude or Codex review submissions via `gh` and independently decide whether and how to address them. Bug reports in particular are welcome. Sorry if this offends, but I want to avoid wasted time and hurt feelings. I understand this isn't in sync with the prevailing open-source ethos that seeks community contributions, but it's the only way I can move at this velocity and keep my sanity.

### 2.3 Key Principles

1. **No Direct PR Merges**: External code is never merged directly
2. **Independent Verification**: AI validates independently - never trust user claims
3. **AI as Implementation**: Good ideas are implemented from scratch by AI
4. **Human Judgment for Direction**: Maintainer decides features/scope
5. **AI as Communicator**: AI responds via `gh` on maintainer's behalf
6. **Date Awareness**: Many issues are stale - check against recent commits

---

## 3. Current Manual Workflow

### 3.1 Step-by-Step Process

For each repository with open issues or PRs:

```bash
# 1. Navigate and update
cd ~/projects/myproject
git pull

# 2. Launch Claude Code
cc    # alias for claude-code CLI

# 3. Send codebase understanding prompt (wait ~5 min)
# 4. Send issue/PR review prompt (wait ~10-20 min)
# 5. Handle interactive questions from Claude
# 6. Repeat for next project
```

### 3.2 The Prompts

**Prompt 1: Codebase Understanding (Incremental Digest)**
```
First read ALL of AGENTS.md and README.md carefully.

If a prior repo digest exists at .ru/repo-digest.md, read it first.
Then update it based on changes since last review:
  • inspect git log since the last review timestamp
  • inspect changed files and any new architecture decisions

If no prior digest exists, create a comprehensive repo digest covering:
  • Project purpose and architecture
  • Key files and modules
  • Patterns and conventions used

Write the updated digest to .ru/repo-digest.md.
Use ultrathink.
```

**Prompt 2: Issue/PR Review**
```
We don't allow PRs or outside contributions to this project as a matter
of policy; here is the policy disclosed to users:

> *About Contributions:* Please don't take this the wrong way, but I do
not accept outside contributions for any of my projects. I simply don't
have the mental bandwidth to review anything, and it's my name on the
thing, so I'm responsible for any problems it causes; thus, the
risk-reward is highly asymmetric from my perspective. I'd also have to
worry about other "stakeholders," which seems unwise for tools I mostly
make for myself for free. Feel free to submit issues, and even PRs if
you want to illustrate a proposed fix, but know I won't merge them
directly. Instead, I'll have Claude or Codex review submissions via `gh`
and independently decide whether and how to address them. Bug reports in
particular are welcome. Sorry if this offends, but I want to avoid
wasted time and hurt feelings. I understand this isn't in sync with the
prevailing open-source ethos that seeks community contributions, but
it's the only way I can move at this velocity and keep my sanity.

But I want you to now use the `gh` utility to review all open issues and
PRs and to independently read and review each of these carefully; without
trusting or relying on any of the user reports being correct, or their
suggested/proposed changes or "fixes" being correct, I want you to do
your own totally separate and independent verification and validation.
You can use the stuff from users as possible inspiration, but everything
has to come from your own mind and/or official documentation and the
actual code and empirical, independent evidence. Note that MANY of these
are likely out of date because I made tons of fixes and changes already;
it's important to look at the dates and subsequent commits. Use ultrathink.
After you have reviewed things carefully and taken actions in response
(including implementing possible fixes or new features), you can respond
on my behalf using `gh`.

Just a reminder: we do NOT accept ANY PRs. You can look at them to see if
they contain good ideas but even then you must check with me first before
integrating even ideas because they could take the project into another
direction I don't like or introduce scope creep. Use ultrathink.
```

### 3.3 Pain Points

| Pain Point | Impact | Frequency |
|------------|--------|-----------|
| Time per repo | 10-20+ minutes, fully attended | Every repo |
| Context switching | Mental overhead between projects | Constant |
| Interruption-driven | Claude asks questions needing immediate response | Frequent |
| No aggregation | Questions from different repos not consolidated | Always |
| No prioritization | Can't prioritize which repos need attention first | Always |
| No persistence | Must restart if interrupted | Occasionally |
| Session degradation | Claude slows down over long sessions | After 8-12 exchanges |

---

## 4. Desired Automated Workflow

### 4.1 High-Level Vision (Work Items First, Plan → Apply)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              ru review                                       │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ PHASE 1: Discovery & Prioritization (GraphQL Batched)                   ││
│  │  • Scan all repos via batched GraphQL (alias chunks, not O(n) calls)   ││
│  │  • Build a WORK ITEM list (issue/PR objects with full metadata)        ││
│  │  • Score items individually (security/bug/recency/engagement)          ││
│  │  • Derive repo scheduling from top items + capacity                    ││
│  │  • Filter: skip archived, forks, recently-reviewed                     ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                     │                                        │
│                                     ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ PHASE 2: Preparation & Isolation                                        ││
│  │  • Ensure repos exist locally (auto-clone if needed via ru sync)       ││
│  │  • Create git worktrees for isolation (branch: ru/review/<run_id>)     ││
│  │  • Load/update repo digest cache (incremental understanding)           ││
│  │  • Respect branch pins from repo spec                                  ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                     │                                        │
│                                     ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ PHASE 3: Parallel Orchestration (Plan Mode - No Mutations)             ││
│  │  • Launch Claude Code sessions via unified Session Driver              ││
│  │  • Provide repo digest + delta (incremental understanding)             ││
│  │  • Agent produces local patches + review-plan.json artifact            ││
│  │  • NO direct GitHub mutations (comment/close/label) in this phase      ││
│  │  • Monitor via activity detection + rate-limit governor                ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                     │                                        │
│                                     ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ PHASE 4: Question Aggregation (Three Wait Reasons)                      ││
│  │  • Detect AskUserQuestion tool calls (structured)                       ││
│  │  • Detect agent text questions at prompt (heuristic)                    ││
│  │  • Detect external prompts (git conflict, auth, shell)                  ││
│  │  • Queue with context, options, recommended action, risk level          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                     │                                        │
│                                     ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ PHASE 5: Unified TUI (Enhanced UX)                                      ││
│  │  • Present aggregated questions with patch summaries                    ││
│  │  • Show: changed files, LOC, test status from plan artifact             ││
│  │  • Actions: answer, drill-down, snooze, template, bulk-apply            ││
│  │  • Route answers back to sessions                                       ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                     │                                        │
│                                     ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ PHASE 6: Apply (Optional, Explicit)                                     ││
│  │  • Consume review-plan.json artifacts                                   ││
│  │  • Run quality gates (tests/lint) - block if failing                    ││
│  │  • Execute approved gh_actions (comment, close, label)                  ││
│  │  • Push changes only with --apply --push (safe default: no push)        ││
│  │  • Merge worktree changes to main branch                                ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                     │                                        │
│                                     ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ PHASE 7: Completion & Reporting                                         ││
│  │  • Update item-level outcomes in state                                  ││
│  │  • Update repo digest cache                                             ││
│  │  • Generate summary report + analytics                                  ││
│  │  • Clean up worktrees (or preserve for investigation)                   ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Key Requirements

| Requirement | Description | Priority |
|-------------|-------------|----------|
| **Work Item Model** | Score issues/PRs individually, not just repos | P0 |
| **GraphQL Batching** | Efficient discovery (10-100× fewer API calls) | P0 |
| **Plan → Apply Split** | Safe defaults; mutations only with explicit --apply | P0 |
| **Worktree Isolation** | Each review in isolated git worktree | P0 |
| **Question Aggregation** | Collect all wait reasons (AskUser, text, external) | P0 |
| **Unified Session Driver** | Same interface for ntm and local modes | P0 |
| **Review Plan Artifact** | Structured JSON output for apply phase | P0 |
| **Quality Gates** | Tests/lint must pass before push | P0 |
| **Rate-Limit Governor** | Adaptive concurrency based on real limits | P1 |
| **Repo Digest Cache** | Incremental understanding across runs | P1 |
| **Parallel Execution** | Run multiple reviews concurrently | P1 |
| **Item-Level Outcomes** | Track decisions per issue/PR, not just repo | P1 |
| **Context Preservation** | Show patch summaries, test status, risk level | P1 |
| **Drill-Down** | View full session for more detail | P1 |
| **State Persistence** | Atomic writes, locking, resume after interruption | P1 |
| **TUI Enhancements** | Snooze, templates, bulk-apply, patch preview | P2 |
| **Metrics Collection** | Learn from decisions over time | P2 |
| **Cost Budget** | --max-repos, --max-runtime, --max-questions | P2 |

### 4.3 User Experience Goal

```
$ ru review

Scanning 47 repositories for open issues and PRs...

╭─────────────────────────────────────────────────────────────────────────────╮
│  📊 Discovery Results                                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│  Repositories with activity:  8                                              │
│  Total open issues:          14                                              │
│  Total open PRs:              3                                              │
│  Estimated review time:      ~45 minutes                                     │
╰─────────────────────────────────────────────────────────────────────────────╯

Starting 4 parallel review sessions...

╭─────────────────────────────────────────────────────────────────────────────╮
│  🔍 ru review - Questions Pending: 3                     Progress: 5/8 ████░│
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  [1] ● project-alpha  │  Issue #42  │  Priority: HIGH                       │
│      ─────────────────────────────────────────────────────────────────────  │
│      User reports authentication failing on Windows. I found the issue is  │
│      related to path handling in auth.py:234. Should I:                     │
│                                                                              │
│        a) Fix for Windows only (5 lines, minimal risk)                      │
│        b) Refactor path handling for all platforms (45 lines, better)       │
│        c) Skip - not a priority right now                                   │
│                                                                              │
│  [2] ○ project-beta   │  PR #15     │  Priority: NORMAL                     │
│      ─────────────────────────────────────────────────────────────────────  │
│      PR proposes adding Redis caching. I verified the approach is sound     │
│      but it adds a dependency. Do you want me to:                           │
│                                                                              │
│        a) Implement caching with Redis (as proposed)                        │
│        b) Implement with in-memory cache (no new deps)                      │
│        c) Skip - out of scope for now                                       │
│                                                                              │
│  [3] ○ project-gamma  │  Issue #7   │  Priority: LOW                        │
│      Feature request for dark mode. [Press Enter to expand]                 │
│                                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│  ACTIVE SESSIONS                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│  project-delta    ████████░░ 80%  Reviewing issue #3... (2m remaining)      │
│  project-epsilon  ██████░░░░ 60%  Understanding codebase...                 │
│  project-zeta     ████░░░░░░ 40%  Cloning repository...                     │
│  project-eta      ░░░░░░░░░░  0%  Queued (starting in ~3m)                  │
│                                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│  [1-9] Answer  [Enter] Expand  [d] Drill-down  [s] Skip  [q] Quit           │
╰─────────────────────────────────────────────────────────────────────────────╯
```

---

## 5. Architecture Options Analysis

### 5.1 Option A: Pure Bash Extension

**Approach**: Extend `ru` with a new `review` subcommand entirely in Bash.

```bash
# Implementation sketch
cmd_review() {
    local repos_with_issues=()

    # Scan repos for open issues/PRs
    while IFS= read -r repo_spec; do
        local issue_count pr_count
        issue_count=$(gh issue list -R "$repo" --state open --json number | jq length)
        pr_count=$(gh pr list -R "$repo" --state open --json number | jq length)

        if [[ $((issue_count + pr_count)) -gt 0 ]]; then
            repos_with_issues+=("$repo_spec")
        fi
    done < <(get_all_repos)

    # Process each repo sequentially
    for repo in "${repos_with_issues[@]}"; do
        # Launch tmux session with Claude Code
        # Send prompts via tmux send-keys
        # Poll for questions using output pattern matching
        # Show questions via gum
    done
}
```

| Pros | Cons |
|------|------|
| Keeps ru as pure Bash (consistent with existing codebase) | Bash awkward for complex TUI interactions |
| No new dependencies beyond what ru already uses | Limited concurrency control |
| Simple deployment (single script) | Output parsing is fragile |
| | No real-time monitoring |
| | Would reinvent functionality that exists elsewhere (ntm) |
| | Hard to maintain as complexity grows |

**Verdict**: ❌ Not recommended for full implementation, but useful for basic functionality.

### 5.2 Option B: Standalone Go/Rust Helper Binary

**Approach**: Create `ru-review` as a separate binary that ru calls.

```go
// ru-review/main.go sketch
func main() {
    repos := scanForActivity()
    sessions := make(map[string]*Session)

    for _, repo := range repos {
        session := launchClaudeSession(repo)
        sessions[repo] = session
        go monitorSession(session)
    }

    runTUI(sessions)
}
```

| Pros | Cons |
|------|------|
| Proper TUI support (using tview, bubbletea, etc.) | New codebase to maintain |
| Better output parsing and state management | Duplicates functionality from ntm |
| Good concurrency primitives | More complex build and installation |
| Type safety and better error handling | Different language from ru (coordination overhead) |

**Verdict**: ⚠️ Reasonable but suboptimal given ntm exists.

### 5.3 Option C: Deep ntm Integration

**Approach**: Use ntm as the orchestration engine, ru as the repo management layer.

```
┌─────────────────────────────────────────────────────────────────────┐
│                           ru review                                  │
│                              │                                       │
│                    ┌─────────┴─────────┐                            │
│                    ▼                   ▼                            │
│              ┌──────────┐       ┌──────────────┐                    │
│              │  ru      │       │  ntm         │                    │
│              │  (Bash)  │       │  (Go)        │                    │
│              └────┬─────┘       └──────┬───────┘                    │
│                   │                    │                            │
│    Repo config    │                    │  Session mgmt              │
│    Issue scanning │                    │  Activity detection        │
│    Git operations │                    │  TUI/Dashboard             │
│                   │                    │  Robot mode API            │
│                   └────────┬───────────┘                            │
│                            │                                        │
│                            ▼                                        │
│                    ┌───────────────┐                                │
│                    │ Claude Code   │                                │
│                    │ (tmux panes)  │                                │
│                    └───────────────┘                                │
└─────────────────────────────────────────────────────────────────────┘
```

| Pros | Cons |
|------|------|
| Leverages mature, tested orchestration code (~29K lines of Go) | Adds ntm as dependency |
| Beautiful TUI already exists (command palette, dashboard) | Requires ntm installation and configuration |
| Health monitoring, auto-restart, activity detection | More complex initial setup |
| Robot mode enables Bash→Go communication | Two-language coordination (Bash + Go) |
| Workflow pipelines for complex sequences | |
| Session persistence across disconnections | |

**Verdict**: ✅ **Recommended** - leverages existing sophisticated tooling.

### 5.4 Option D: Hybrid with Graceful Degradation

**Approach**: Works with or without ntm.

- **Without ntm**: Sequential processing, gum-based TUI, basic functionality
- **With ntm**: Full parallel processing, rich dashboard, advanced features

| Pros | Cons |
|------|------|
| Works for all users | Two code paths to maintain |
| Enhanced experience with ntm | More testing required |
| Gradual adoption path | |

**Verdict**: ✅ **Selected** - Best balance of accessibility and power.

---

## 6. Recommended Architecture

### 6.1 Component Architecture (Unified Session Driver)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            User: ru review                                   │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         ru (Bash Layer)                                      │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  • GraphQL batched discovery (alias chunks)                           │  │
│  │  • Work Item queue + item-level scoring                               │  │
│  │  • Worktree preparation (isolation)                                   │  │
│  │  • Repo digest cache management                                       │  │
│  │  • State persistence (atomic, locked, item-level)                     │  │
│  │  • Rate-limit governor integration                                    │  │
│  │  • Driver detection (ntm vs local)                                    │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Session Driver Interface (Unified)                       │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  start(repo_ctx) -> session_handle                                    │  │
│  │  send(session, message)                                               │  │
│  │  stream(session) -> normalized_events                                 │  │
│  │  interrupt(session)                                                   │  │
│  │  stop(session)                                                        │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │
                    ┌──────────────┴──────────────┐
                    │                             │
                    ▼                             ▼
┌───────────────────────────────────┐ ┌───────────────────────────────────────┐
│      Local Driver (no ntm)        │ │         ntm Driver (full power)       │
│  ┌─────────────────────────────┐  │ │  ┌─────────────────────────────────┐  │
│  │ • tmux + stream-json        │  │ │  │ • Robot mode API                │  │
│  │ • Interactive Q/A routing   │  │ │  │ • Activity detection            │  │
│  │ • Same event schema as ntm  │  │ │  │ • Health monitoring             │  │
│  │ • Parallel via tmux panes   │  │ │  │ • Workflow pipelines            │  │
│  └─────────────────────────────┘  │ │  │ • Same event schema as local    │  │
└───────────────────────────────────┘ │  └─────────────────────────────────┘  │
                                      └───────────────────────────────────────┘
                    │                             │
                    └──────────────┬──────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Claude Code Sessions (stream-json)                        │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │ claude -p --output-format stream-json                                 │  │
│  │                                                                       │  │
│  │ Normalized Events (both drivers emit same schema):                    │  │
│  │ • init: session started                                               │  │
│  │ • generating: active output (velocity > 10 chars/sec)                 │  │
│  │ • waiting: {reason: ask_user_question|agent_question|external_prompt} │  │
│  │ • complete: session finished                                          │  │
│  │ • error: error detected                                               │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Review Plan Artifact (.ru/)                           │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │ review-plan.json: items, questions, git, gh_actions                   │  │
│  │ repo-digest.md: cached codebase understanding                         │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 Data Flow (Work Item Queue → Plan → Apply)

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ GitHub API   │───▶│ Work Item    │───▶│ Worktree     │───▶│ Session      │
│ (GraphQL     │    │ Queue+Score  │    │ Preparation  │    │ Driver       │
│  Batched)    │    │ (Item-Level) │    │ (Isolation)  │    │ (Unified)    │
└──────────────┘    └──────────────┘    └──────────────┘    └──────┬───────┘
                                                                   │
                    ┌──────────────────────────────────────────────┤
                    ▼                                              ▼
            ┌──────────────┐                              ┌──────────────┐
            │ Rate-Limit   │◀────────────────────────────▶│ Question     │
            │ Governor     │                              │ Detector     │
            │ (Adaptive)   │                              │ (3 Reasons)  │
            └──────────────┘                              └──────┬───────┘
                                                                 │
┌──────────────┐    ┌──────────────┐    ┌──────────────┐         │
│ Apply Phase  │◀───│ Plan         │◀───│ TUI + Answer │◀────────┘
│ (Quality     │    │ Artifact     │    │ Router       │
│  Gates+Push) │    │ (.ru/*.json) │    │ (Enhanced)   │
└──────┬───────┘    └──────────────┘    └──────────────┘
       │
       ▼
┌──────────────┐    ┌──────────────┐
│ Item-Level   │───▶│ Repo Digest  │
│ Outcomes     │    │ Cache Update │
│ (State)      │    │              │
└──────────────┘    └──────────────┘
```

---

## 7. Implementation Plan

### 7.1 Phase 1: Core Infrastructure (Worktrees, GraphQL Batching, Work Items)

#### 7.1.1 Add `ru review` Command (Plan → Apply, Worktrees)

```bash
# In ru script - new command
cmd_review() {
    local mode="auto"
    local parallel=4
    local dry_run="false"
    local resume="false"
    local apply="false"
    local push="false"
    local priority_threshold="all"  # all, normal, high, critical
    local max_repos=""              # Cost budget: limit repos
    local max_runtime=""            # Cost budget: limit runtime
    local max_questions=""          # Cost budget: limit questions

    # Parse arguments
    parse_review_args

    # Check prerequisites
    check_review_prerequisites || exit 3

    # Generate unique run ID
    REVIEW_RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"

    # Acquire global lock (prevents concurrent ru review runs)
    acquire_review_lock || { log_error "Another review is running"; exit 1; }

    # Auto-detect driver
    if [[ "$mode" == "auto" ]]; then
        mode=$(detect_review_driver)  # returns "ntm" or "local"
    fi

    # Discovery phase (GraphQL batched)
    log_step "Scanning repositories for open issues and PRs (batched)..."
    local -a work_items
    discover_work_items work_items "$priority_threshold" "$max_repos"

    if [[ ${#work_items[@]} -eq 0 ]]; then
        log_success "No work items need review"
        release_review_lock
        return 0
    fi

    # Show discovery summary (item-level)
    show_discovery_summary "${work_items[@]}"

    if [[ "$dry_run" == "true" ]]; then
        log_info "Dry run - exiting without starting sessions"
        release_review_lock
        return 0
    fi

    # Derive repos from top work items
    local -a repos_to_review
    derive_repos_from_items repos_to_review "${work_items[@]}"

    # Ensure repos exist locally (auto-clone if needed)
    ensure_repos_exist "${repos_to_review[@]}"

    # Prepare isolated worktrees for each repo
    log_step "Preparing isolated worktrees..."
    prepare_review_worktrees "${repos_to_review[@]}"

    # Load/update repo digest cache for incremental understanding
    prepare_repo_digests "${repos_to_review[@]}"

    # Dispatch to driver (Plan Mode - no mutations)
    case "$mode" in
        ntm)   run_review_ntm_driver "${repos_to_review[@]}" ;;
        local) run_review_local_driver "${repos_to_review[@]}" ;;
    esac

    # Apply phase (optional, explicit)
    if [[ "$apply" == "true" ]]; then
        log_step "Apply phase: executing approved actions..."
        run_apply_phase "$push" "${repos_to_review[@]}"
    else
        log_info "Plan mode complete. Run with --apply to execute actions."
    fi

    # Update state with item-level outcomes
    update_review_state "${repos_to_review[@]}"

    # Cleanup
    release_review_lock
}

# Create per-repo worktrees to isolate AI edits
prepare_review_worktrees() {
    local repos=("$@")
    local base="$RU_STATE_DIR/worktrees/$REVIEW_RUN_ID"
    mkdir -p "$base"

    for repo_info in "${repos[@]}"; do
        local repo_spec issues prs updated_at oldest
        IFS='|' read -r repo_spec issues prs updated_at oldest <<< "$repo_info"

        local url branch custom_name local_path repo_id
        resolve_repo_spec "$repo_spec" "$PROJECTS_DIR" "$LAYOUT" \
            url branch custom_name local_path repo_id

        # Refuse to run on dirty trees
        ensure_clean_or_fail "$local_path"

        local wt_path="$base/${repo_id//\//_}"
        local wt_branch="ru/review/$REVIEW_RUN_ID/${repo_id//\//-}"

        # Fetch latest and create worktree
        git -C "$local_path" fetch --quiet 2>/dev/null || true

        # Respect branch pins from repo spec
        local base_ref="${branch:-HEAD}"
        git -C "$local_path" worktree add -b "$wt_branch" "$wt_path" "$base_ref" >/dev/null

        # Create .ru directory for artifacts
        mkdir -p "$wt_path/.ru"

        record_worktree_mapping "$repo_id" "$wt_path" "$wt_branch"
    done
}

# Apply phase: consume review-plan.json, run quality gates, execute mutations
run_apply_phase() {
    local push="$1"
    shift
    local repos=("$@")

    for repo_info in "${repos[@]}"; do
        local repo_id wt_path
        get_worktree_mapping "$repo_info" repo_id wt_path

        local plan_file="$wt_path/.ru/review-plan.json"
        if [[ ! -f "$plan_file" ]]; then
            log_warn "$repo_id: No review plan found, skipping"
            continue
        fi

        # Run quality gates (tests/lint)
        if ! run_quality_gates "$wt_path" "$plan_file"; then
            log_error "$repo_id: Quality gates failed, skipping apply"
            queue_question "quality_failed" "$repo_id" "Tests failed, proceed anyway?"
            continue
        fi

        # Execute gh_actions from plan (comment, close, label)
        execute_gh_actions "$repo_id" "$plan_file"

        # Push if allowed
        if [[ "$push" == "true" ]]; then
            push_worktree_changes "$repo_id" "$wt_path"
        fi
    done
}
```

#### 7.1.2 GitHub Activity Detection (True Batch, GraphQL Alias Chunks)

```bash
# Discover work items using GraphQL alias batching (10-100× fewer API calls)
discover_work_items() {
    local -n result_array=$1
    local priority_threshold="$2"
    local max_repos="${3:-}"

    local -a all_specs=()
    while IFS= read -r spec; do
        [[ -n "$spec" ]] && all_specs+=("$spec")
    done < <(get_all_repos)

    # Resolve specs -> owner/repo ids (skip non-GitHub hosts in discovery)
    local -a repo_ids=()
    local -A spec_by_repo=()
    for repo_spec in "${all_specs[@]}"; do
        local url branch custom_name local_path repo_id host
        if ! resolve_repo_spec "$repo_spec" "$PROJECTS_DIR" "$LAYOUT" \
            url branch custom_name local_path repo_id; then
            continue
        fi
        host=$(detect_repo_host "$url")
        [[ "$host" != "github" ]] && continue
        repo_ids+=("$repo_id")
        spec_by_repo["$repo_id"]="$repo_spec"
    done

    # GraphQL alias batching: query in chunks of 25 repos each
    local chunk_size=25
    local -a items=()

    for chunk in $(chunk_repo_ids "$chunk_size" "${repo_ids[@]}"); do
        local resp
        resp=$(gh_api_graphql_repo_batch "$chunk") || continue

        # Extract work items (issues + PRs) in one pass
        while IFS=$'\t' read -r repo_id item_type number title labels created_at updated_at is_draft; do
            # Skip archived repos (already filtered in query but double-check)
            [[ -z "$repo_id" ]] && continue

            # Calculate item-level priority score
            local score
            score=$(calculate_item_priority_score "$item_type" "$labels" "$created_at" "$updated_at" "$is_draft")

            # Apply threshold filter
            local level
            level=$(get_priority_level "$score")
            if ! passes_priority_threshold "$level" "$priority_threshold"; then
                continue
            fi

            # Format: repo_id|type|number|title|score|level|created_at|updated_at
            items+=("${repo_id}|${item_type}|${number}|${title}|${score}|${level}|${created_at}|${updated_at}")
        done < <(parse_graphql_work_items "$resp")
    done

    # Sort by priority score (descending) and apply max_repos limit
    local sorted_items
    sorted_items=$(printf '%s\n' "${items[@]}" | sort -t'|' -k5 -rn)

    if [[ -n "$max_repos" ]]; then
        # Derive unique repos from top items, limit to max_repos
        local -A seen_repos=()
        while IFS= read -r item; do
            local repo_id="${item%%|*}"
            if [[ -z "${seen_repos[$repo_id]:-}" ]]; then
                seen_repos["$repo_id"]=1
                if [[ ${#seen_repos[@]} -gt $max_repos ]]; then
                    break
                fi
            fi
            result_array+=("$item")
        done <<< "$sorted_items"
    else
        while IFS= read -r item; do
            [[ -n "$item" ]] && result_array+=("$item")
        done <<< "$sorted_items"
    fi
}

# GraphQL alias batching: build query with repo0/repo1/... aliases
# Returns issues + PRs with full metadata in one API call
gh_api_graphql_repo_batch() {
    local chunk="$1"
    local q="query {"
    local i=0

    while IFS= read -r repo_id; do
        [[ -z "$repo_id" ]] && continue
        local owner="${repo_id%%/*}"
        local name="${repo_id#*/}"

        q+=" repo${i}: repository(owner:\"${owner}\", name:\"${name}\") {"
        q+=" nameWithOwner isArchived isFork updatedAt"
        # Issues with metadata for scoring
        q+=" issues(states:OPEN, first:50, orderBy:{field:CREATED_AT, direction:DESC}) {"
        q+="   nodes { number title createdAt updatedAt"
        q+="     labels(first:10) { nodes { name } }"
        q+="   }"
        q+=" }"
        # PRs with metadata for scoring
        q+=" pullRequests(states:OPEN, first:20, orderBy:{field:CREATED_AT, direction:DESC}) {"
        q+="   nodes { number title createdAt updatedAt isDraft"
        q+="     labels(first:10) { nodes { name } }"
        q+="   }"
        q+=" }"
        # Oldest open issue for staleness scoring
        q+=" oldestIssue: issues(states:OPEN, first:1, orderBy:{field:CREATED_AT, direction:ASC}) {"
        q+="   nodes { createdAt }"
        q+=" }"
        q+=" }"
        ((i++))
    done <<< "$chunk"

    q+=" }"

    # Execute GraphQL query
    gh api graphql -f query="$q" 2>/dev/null
}

# Parse GraphQL response into work items (TSV format for easy Bash parsing)
parse_graphql_work_items() {
    local resp="$1"

    # Use jq to flatten the response into TSV lines
    echo "$resp" | jq -r '
        .data | to_entries[] | select(.value != null) |
        select(.value.isArchived != true) |
        select(.value.isFork != true) |
        .value as $repo |
        (
            # Issues
            ($repo.issues.nodes // [])[] |
            [$repo.nameWithOwner, "issue", .number, .title,
             ([.labels.nodes[].name] | join(",")),
             .createdAt, .updatedAt, "false"] | @tsv
        ),
        (
            # PRs
            ($repo.pullRequests.nodes // [])[] |
            [$repo.nameWithOwner, "pr", .number, .title,
             ([.labels.nodes[].name] | join(",")),
             .createdAt, .updatedAt, (.isDraft | tostring)] | @tsv
        )
    ' 2>/dev/null
}
```

#### 7.1.3 Priority Scoring (Item-Level)

```bash
# Calculate priority score for an individual work item (issue or PR)
# This is the primary scoring function - repo priority is derived from top items
calculate_item_priority_score() {
    local item_type="$1"        # issue or pr
    local labels="$2"           # comma-separated labels
    local created_at="$3"       # ISO timestamp
    local updated_at="$4"       # ISO timestamp
    local is_draft="${5:-false}"

    local score=0

    # Component 1: Type importance (0-20 points)
    # PRs indicate someone invested effort
    if [[ "$item_type" == "pr" ]]; then
        score=$((score + 20))
        # Draft PRs get penalized
        [[ "$is_draft" == "true" ]] && score=$((score - 15))
    else
        score=$((score + 10))
    fi

    # Component 2: Label-based priority (0-50 points)
    if echo "$labels" | grep -qiE 'security|critical'; then
        score=$((score + 50))
    elif echo "$labels" | grep -qiE 'bug|urgent'; then
        score=$((score + 30))
    elif echo "$labels" | grep -qiE 'enhancement|feature'; then
        score=$((score + 10))
    fi

    # Component 3: Age factor (0-50 points for bugs, penalty for old features)
    local age_days
    age_days=$(days_since_timestamp "$created_at")

    # Bug/security items: older = more urgent
    if echo "$labels" | grep -qiE 'bug|security|critical'; then
        if [[ $age_days -gt 60 ]]; then
            score=$((score + 50))
        elif [[ $age_days -gt 30 ]]; then
            score=$((score + 30))
        elif [[ $age_days -gt 14 ]]; then
            score=$((score + 15))
        fi
    else
        # Feature requests: very old ones should not dominate
        if [[ $age_days -gt 180 ]]; then
            score=$((score - 10))
        fi
    fi

    # Component 4: Recency bonus (0-15 points)
    # Recently updated items have active engagement
    local updated_days
    updated_days=$(days_since_timestamp "$updated_at")
    if [[ $updated_days -lt 3 ]]; then
        score=$((score + 15))
    elif [[ $updated_days -lt 7 ]]; then
        score=$((score + 10))
    fi

    # Component 5: Staleness penalty - already reviewed items (-20 points)
    local item_key="${repo_id}#${item_type}-${number}"
    if item_recently_reviewed "$item_key"; then
        score=$((score - 20))
    fi

    # Ensure non-negative
    [[ $score -lt 0 ]] && score=0

    echo "$score"
}

# Derive repo priority from its top work items
calculate_repo_priority() {
    local repo_id="$1"
    local -a item_scores=("${@:2}")

    # Repo priority = max(item_priority) + volume bonus
    local max_score=0
    local count=${#item_scores[@]}

    for score in "${item_scores[@]}"; do
        [[ $score -gt $max_score ]] && max_score=$score
    done

    # Volume bonus (capped at 30)
    local volume_bonus=$((count * 5))
    [[ $volume_bonus -gt 30 ]] && volume_bonus=30

    echo $((max_score + volume_bonus))
}

# Helper: days since ISO timestamp
days_since_timestamp() {
    local ts="$1"
    local now
    now=$(date +%s)
    local then
    then=$(date -d "$ts" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || echo "$now")
    echo $(( (now - then) / 86400 ))
}
```

### 7.2 Phase 2: Claude Code Integration (Week 2-3)

#### 7.2.1 Stream-JSON Mode Integration

```bash
# Launch Claude Code in stream-json mode for programmatic control
launch_claude_session() {
    local repo_path="$1"
    local session_id="$2"
    local prompt="$3"

    # Create named pipe for output
    local pipe_file="$RU_STATE_DIR/pipes/${session_id}.pipe"
    mkdir -p "$(dirname "$pipe_file")"
    mkfifo "$pipe_file" 2>/dev/null || true

    # Launch Claude Code with stream-json
    (
        cd "$repo_path" || exit 1
        claude -p "$prompt" --output-format stream-json 2>&1
    ) > "$pipe_file" &

    echo $!  # Return PID
}

# Parse stream-json events
parse_claude_stream() {
    local pipe_file="$1"
    local callback="$2"

    while IFS= read -r line; do
        # Skip empty lines
        [[ -z "$line" ]] && continue

        # Parse JSON event
        local event_type
        event_type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)

        case "$event_type" in
            system)
                # Initialization event
                local session_id
                session_id=$(echo "$line" | jq -r '.session_id')
                $callback "init" "$session_id" ""
                ;;
            assistant)
                # Check for tool_use (especially AskUserQuestion)
                local tool_name
                tool_name=$(echo "$line" | jq -r '.message.content[]? | select(.type=="tool_use") | .name // empty' 2>/dev/null)
                if [[ "$tool_name" == "AskUserQuestion" ]]; then
                    local question_data
                    question_data=$(echo "$line" | jq -r '.message.content[] | select(.name=="AskUserQuestion") | .input')
                    $callback "question" "" "$question_data"
                fi
                ;;
            result)
                # Session complete
                local status
                status=$(echo "$line" | jq -r '.status')
                $callback "complete" "$status" ""
                ;;
        esac
    done < "$pipe_file"
}
```

#### 7.2.2 Question Detection and Extraction

```bash
# Extract question from AskUserQuestion tool call
extract_question_info() {
    local question_json="$1"

    # Parse the question structure
    local question header options multi_select

    # AskUserQuestion format:
    # {
    #   "questions": [{
    #     "question": "Which approach?",
    #     "header": "Approach",
    #     "options": [{"label": "A", "description": "..."}],
    #     "multiSelect": false
    #   }]
    # }

    question=$(echo "$question_json" | jq -r '.questions[0].question // empty')
    header=$(echo "$question_json" | jq -r '.questions[0].header // empty')
    options=$(echo "$question_json" | jq -c '.questions[0].options // []')
    multi_select=$(echo "$question_json" | jq -r '.questions[0].multiSelect // false')

    # Format for display
    cat << EOF
{
  "question": $(echo "$question" | jq -R .),
  "header": $(echo "$header" | jq -R .),
  "options": $options,
  "multi_select": $multi_select
}
EOF
}
```

### 7.3 Phase 3: ntm Integration (Week 3-4)

#### 7.3.1 ntm Robot Mode API Usage

```bash
# Start review sessions using ntm
run_review_ntm_mode() {
    local repos=("$@")
    local session_name="ru-review-$$"
    local parallel_count="${REVIEW_PARALLEL:-4}"

    # Spawn ntm session with Claude agents
    local spawn_result
    spawn_result=$(ntm --robot-spawn "$session_name" \
        --cc="$parallel_count" \
        --working-dir="$PROJECTS_DIR" 2>/dev/null)

    if ! echo "$spawn_result" | jq -e '.success' >/dev/null; then
        log_error "Failed to spawn ntm session"
        log_error "$(echo "$spawn_result" | jq -r '.error // "Unknown error"')"
        return 1
    fi

    # Queue reviews using workflow pipelines
    local pane_index=1
    for repo_info in "${repos[@]}"; do
        local repo_spec issues prs
        IFS='|' read -r repo_spec issues prs <<< "$repo_info"

        local url branch custom_name local_path repo_id
        resolve_repo_spec "$repo_spec" "$PROJECTS_DIR" "$LAYOUT" \
            url branch custom_name local_path repo_id

        # Assign to pane using robot routing
        local route_result
        route_result=$(ntm --robot-route="$session_name" --type=cc 2>/dev/null)
        local target_pane
        target_pane=$(echo "$route_result" | jq -r '.recommendation.pane_id')

        # Send workflow to pane
        ntm workflow run github-review \
            --session="$session_name" \
            --pane="$target_pane" \
            --input repo_path="$local_path" \
            --input repo_name="$repo_id" \
            --async &

        ((pane_index++))
    done

    # Launch review dashboard
    run_review_dashboard "$session_name"
}

# Monitor session health
monitor_session_health() {
    local session_name="$1"

    while true; do
        local health
        health=$(ntm --robot-health="$session_name" 2>/dev/null)

        # Check for issues
        local alerts
        alerts=$(echo "$health" | jq -r '.alerts[]? // empty')

        if [[ -n "$alerts" ]]; then
            handle_health_alert "$session_name" "$alerts"
        fi

        # Check for rate limiting
        local rate_limited
        rate_limited=$(echo "$health" | jq -r '.sessions["'"$session_name"'"].agents | to_entries[] | select(.value.issue == "rate_limited") | .key')

        if [[ -n "$rate_limited" ]]; then
            handle_rate_limit "$session_name" "$rate_limited"
        fi

        sleep 10
    done
}
```

#### 7.3.2 Activity State Detection

ntm provides velocity-based activity detection with these thresholds:

```go
// From ntm internal/robot/activity.go
const (
    VelocityHighThreshold   = 10.0  // chars/sec - active generation
    VelocityMediumThreshold = 2.0   // chars/sec - some activity
    VelocityIdleThreshold   = 1.0   // chars/sec - considered idle
    DefaultStallThreshold   = 30 * time.Second
)
```

State classification priority:
1. **ERROR** (0.95 confidence): Error patterns detected immediately
2. **WAITING** (0.90 confidence): Idle prompt + velocity < 1.0 chars/sec
3. **THINKING** (0.80 confidence): Thinking indicators (spinners, "thinking...")
4. **GENERATING** (0.85 confidence): velocity > 10.0 chars/sec
5. **STALLED** (0.75 confidence): velocity == 0 for > 30 seconds while generating
6. **UNKNOWN** (0.50 confidence): Insufficient signals

### 7.4 Phase 4: TUI and Polish (Week 4-5)

See Section 12 for detailed TUI design.

---

## 8. Technical Deep Dive: Claude Code Automation

### 8.1 Claude Code Modes

| Mode | Command | Use Case |
|------|---------|----------|
| Interactive | `claude` | Normal human interaction |
| Headless/Print | `claude -p "prompt"` | Scriptable, non-interactive |
| Stream JSON | `claude -p "..." --output-format stream-json` | Programmatic monitoring |

### 8.2 Stream-JSON Event Types

```json
// Initialization
{"type":"system","subtype":"init","session_id":"abc123","tools":["Read","Write","Edit","Bash",...]}

// Assistant message with text
{"type":"assistant","message":{"content":[{"type":"text","text":"I'll analyze..."}]}}

// Assistant using a tool
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_123","name":"Read","input":{"file_path":"/path/to/file"}}]}}

// Tool result
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_123","content":"file contents..."}]}}

// AskUserQuestion tool (CRITICAL for our use case)
{"type":"assistant","message":{"content":[
  {"type":"tool_use","id":"toolu_456","name":"AskUserQuestion","input":{
    "questions":[{
      "question":"Should I refactor the entire auth module or just fix the specific bug?",
      "header":"Approach",
      "options":[
        {"label":"Quick fix","description":"Fix only the reported bug (5 lines)"},
        {"label":"Full refactor","description":"Modernize entire auth module (200+ lines)"},
        {"label":"Skip","description":"Not a priority right now"}
      ],
      "multiSelect":false
    }]
  }}
]}}

// Session complete
{"type":"result","status":"success","duration_ms":45000,"session_id":"abc123"}
```

### 8.3 Key Automation Patterns

```bash
# Pattern 1: Detect AskUserQuestion in stream
detect_question() {
    local line="$1"
    echo "$line" | jq -e '.message.content[]? | select(.name == "AskUserQuestion")' >/dev/null 2>&1
}

# Pattern 2: Extract question for display
format_question_for_display() {
    local question_json="$1"
    local repo_name="$2"

    local question options_text
    question=$(echo "$question_json" | jq -r '.questions[0].question')

    # Format options
    options_text=""
    local i=0
    while IFS= read -r opt; do
        local label desc
        label=$(echo "$opt" | jq -r '.label')
        desc=$(echo "$opt" | jq -r '.description // ""')
        options_text+="  $((++i))) $label"
        [[ -n "$desc" ]] && options_text+=" - $desc"
        options_text+=$'\n'
    done < <(echo "$question_json" | jq -c '.questions[0].options[]')

    cat << EOF
Repository: $repo_name

$question

Options:
$options_text
EOF
}

# Pattern 3: Send answer back to session
send_answer_to_session() {
    local session_id="$1"
    local pane_id="$2"
    local answer="$3"

    # Use ntm robot mode to send
    ntm --robot-send="$session_id" \
        --pane="$pane_id" \
        --msg="$answer"
}
```

### 8.4 Known Limitations and Workarounds

| Limitation | Workaround |
|------------|------------|
| `--output-format stream-json` may miss final event | Poll for completion, set timeout |
| Sessions degrade after 8-12 exchanges | Use `/compact` or start fresh |
| Rate limits (429) | Exponential backoff, rotate between sessions |
| Long thinking periods (10+ min) | Set `--max-turns`, implement timeout |
| Slash commands not available in `-p` mode | Describe task instead |

### 8.5 Review Plan Artifact (Required Output Contract)

Each repo review session MUST produce a machine-readable plan file at:
  `.ru/review-plan.json`

This file is the **single source of truth** for what happened in the session.
ru uses it to:
- Drive the Apply phase (push + gh mutations)
- Resume safely after interruption
- Compute metrics without transcript scraping
- Audit what was done

**Location (absolute):**
```
{worktree}/.ru/review-plan.json
```

**Schema (v1):**

Top-level contract notes:
- `schema_version` is an integer and must be `1` for this version.
- `repo` is `owner/repo` (GitHub shorthand).
- `worktree_path` is the absolute path of the isolated worktree for this repo.
- `items` must exist (may be empty if nothing was reviewed).
- `metadata` must exist (at minimum timestamps + model/driver info).

```json
{
  "schema_version": 1,
  "run_id": "20250104-103000-12345",
  "repo": "owner/repo",
  "worktree_path": "/home/user/.local/state/ru/worktrees/20250104-103000-12345/owner_repo",

  "items": [
    {
      "type": "issue",
      "number": 42,
      "title": "Authentication fails on Windows",
      "priority": "high",
      "decision": "fix",
      "notes": "Root cause: path separator in auth.py:234",
      "risk_level": "low",
      "files_changed": ["src/auth.py"],
      "lines_changed": 5
    },
    {
      "type": "pr",
      "number": 15,
      "title": "Add Redis caching",
      "priority": "normal",
      "decision": "skip",
      "notes": "Out of scope - adds dependency",
      "risk_level": "n/a"
    }
  ],

  "questions": [
    {
      "id": "q1",
      "prompt": "Should I refactor all path handling or just fix this specific case?",
      "options": [
        {"label": "Quick fix", "description": "Fix only auth.py (5 lines)"},
        {"label": "Full refactor", "description": "Modernize all path handling (45 lines)"},
        {"label": "Skip", "description": "Not a priority"}
      ],
      "recommended": "Quick fix",
      "answered": true,
      "answer": "Quick fix",
      "answered_at": "2025-01-04T10:35:00Z"
    }
  ],

  "git": {
    "branch": "ru/review/20250104-103000-12345/owner-repo",
    "base_ref": "main",
    "commits": [
      {
        "sha": "abc123def456",
        "subject": "Fix Windows path handling in auth.py",
        "files": ["src/auth.py"],
        "insertions": 3,
        "deletions": 2
      }
    ],
    "tests": {
      "ran": true,
      "ok": true,
      "command": "make test",
      "output_summary": "12 tests passed",
      "duration_seconds": 45
    }
  },

  "gh_actions": [
    {
      "op": "comment",
      "target": "issue#42",
      "body": "Fixed in commit abc123. The issue was path separators..."
    },
    {
      "op": "close",
      "target": "issue#42",
      "reason": "completed"
    },
    {
      "op": "label",
      "target": "issue#42",
      "labels": ["fixed-in-main"]
    },
    {
      "op": "comment",
      "target": "pr#15",
      "body": "Thank you for the suggestion. After review, I've decided..."
    }
  ],

  "metadata": {
    "started_at": "2025-01-04T10:30:00Z",
    "completed_at": "2025-01-04T10:45:00Z",
    "duration_seconds": 900,
    "context_usage_percent": 45,
    "model": "claude-sonnet-4",
    "driver": "local"
  }
}
```

**Field definitions**

Top level:
| Field | Type | Required | Notes |
|-------|------|----------|------|
| `schema_version` | int | yes | Must be `1` |
| `run_id` | string | yes | Unique run identifier for the overall review run |
| `repo` | string | yes | `owner/repo` |
| `worktree_path` | string | yes | Absolute path to isolated worktree |
| `items` | array | yes | Work items reviewed (may be empty) |
| `questions` | array | no | Questions asked/answered (optional) |
| `git` | object | no | Git summary (optional; absent if no commits) |
| `gh_actions` | array | no | GitHub mutations to apply later (optional; Plan mode must not execute them) |
| `metadata` | object | yes | Session metadata (timing + model/driver) |

Item object:
| Field | Type | Required | Notes |
|-------|------|----------|------|
| `type` | `"issue"`\|`"pr"` | yes | Work item type |
| `number` | int | yes | Issue/PR number |
| `title` | string | yes | Title as seen on GitHub |
| `priority` | string | yes | Suggested values: `critical` \| `high` \| `normal` \| `low` |
| `decision` | string | yes | `fix` \| `skip` \| `needs-info` \| `closed` |
| `notes` | string | no | Rationale / summary |
| `risk_level` | string | no | Suggested values: `low` \| `medium` \| `high` \| `n/a` |
| `files_changed` | array | no | Files touched for this item (best-effort) |
| `lines_changed` | int | no | Net lines changed (best-effort) |

Question object:
| Field | Type | Required | Notes |
|-------|------|----------|------|
| `id` | string | yes | Unique within plan file |
| `prompt` | string | yes | Question text |
| `options` | array | no | Options the user can choose from |
| `recommended` | string | no | Agent recommendation |
| `answered` | bool | yes | Whether answered during this run |
| `answer` | string | no | Required when `answered=true` |
| `answered_at` | string | no | ISO-8601 timestamp; required when `answered=true` |

`gh_actions` object:
| Field | Type | Required | Notes |
|-------|------|----------|------|
| `op` | string | yes | `comment` \| `close` \| `label` \| `merge` |
| `target` | string | yes | `issue#N` or `pr#N` |
| `body` | string | no | Required for `comment` |
| `reason` | string | no | Required for `close` (e.g. `completed`, `not_planned`) |
| `labels` | array | no | Required for `label` |

**Validation:**
```bash
validate_review_plan() {
    local plan_file="$1"

    # Must exist
    [[ -f "$plan_file" ]] || { echo "Plan file not found: $plan_file" >&2; return 1; }

    # We require jq for validation. ru can treat jq as optional for other flows,
    # but review-plan.json is an Apply-phase contract and must be machine-validated.
    command -v jq &>/dev/null || { echo "jq is required to validate review plans" >&2; return 3; }

    # Must be valid JSON
    jq empty "$plan_file" >/dev/null || { echo "Invalid JSON" >&2; return 1; }

    # Must have required fields
    jq -e '
      (.schema_version == 1)
      and (.run_id | type == "string" and length > 0)
      and (.repo | type == "string" and length > 0)
      and (.worktree_path | type == "string" and length > 0)
      and (.items | type == "array")
      and (.metadata | type == "object")
    ' "$plan_file" >/dev/null || { echo "Missing/invalid required top-level fields" >&2; return 1; }

    # Items must have required fields
    jq -e '
      .items
      | all(
          (.type | IN("issue","pr"))
          and (.number | type == "number" and . > 0)
          and (.title | type == "string" and length > 0)
          and (.decision | IN("fix","skip","needs-info","closed"))
        )
    ' "$plan_file" >/dev/null || { echo "One or more items are missing required fields" >&2; return 1; }

    # Questions (if present) must have required fields, and answered questions must include answer + answered_at
    jq -e '
      if has("questions") then
        (.questions | type == "array")
        and (.questions
          | all(
              (.id | type == "string" and length > 0)
              and (.prompt | type == "string" and length > 0)
              and (.answered | type == "boolean")
              and (if .answered then
                    (.answer | type == "string" and length > 0)
                    and (.answered_at | type == "string" and length > 0)
                  else true end)
            )
        )
      else true end
    ' "$plan_file" >/dev/null || { echo "Invalid questions section" >&2; return 1; }

    # gh_actions (if present) must have required fields and op-specific fields
    jq -e '
      if has("gh_actions") then
        (.gh_actions | type == "array")
        and (.gh_actions
          | all(
              (.op | IN("comment","close","label","merge"))
              and (.target | type == "string" and length > 0)
              and (if .op == "comment" then (.body | type == "string" and length > 0) else true end)
              and (if .op == "close" then (.reason | type == "string" and length > 0) else true end)
              and (if .op == "label" then (.labels | type == "array") else true end)
            )
        )
      else true end
    ' "$plan_file" >/dev/null || { echo "Invalid gh_actions section" >&2; return 1; }

    return 0
}
```

**Summary helper (for logs / TUI):**
```bash
summarize_review_plan() {
    local plan_file="$1"
    command -v jq &>/dev/null || { echo "jq is required" >&2; return 3; }

    jq -r '
      def c(decision): ([.items[]? | select(.decision == decision)] | length);
      def test_status: if (.git.tests.ok // false) then "PASS" else "FAIL/NOT RUN" end;
      "Repository: \(.repo)",
      "Items reviewed: \(.items | length)",
      "  - Fixed: \(c("fix"))",
      "  - Skipped: \(c("skip"))",
      "  - Needs info: \(c("needs-info"))",
      "  - Closed: \(c("closed"))",
      "Commits: \((.git.commits // []) | length)",
      "Tests: \(test_status)",
      "gh_actions pending: \((.gh_actions // []) | length)"
    ' "$plan_file"
}
```

---

## 9. Technical Deep Dive: ntm Integration

### 9.1 Robot Mode API Reference

| Command | Output Type | Key Fields |
|---------|-------------|------------|
| `--robot-status` | StatusOutput | sessions, agents, system info |
| `--robot-health=session` | HealthOutput | agent health matrix, alerts |
| `--robot-activity=paneID` | ActivityOutput | state, velocity, confidence |
| `--robot-route=session` | RouteOutput | best pane recommendation |
| `--robot-send` | SendOutput | delivery confirmation |
| `--robot-snapshot=session` | SnapshotOutput | full pane state |

### 9.2 Health Monitoring

ntm detects these conditions automatically:

| Condition | Detection | Recovery |
|-----------|-----------|----------|
| **Stall** | No output for 5+ minutes | Soft restart (Ctrl+C) |
| **Rate Limit** | Pattern: "rate limit", "429", "quota exceeded" | Backoff + alert |
| **Crash** | Pattern: "panic:", "SIGSEGV", "killed" | Auto-restart |
| **Auth Failure** | Pattern: "unauthorized", "invalid.*key" | Alert user |
| **Network Error** | Pattern: "connection refused", "timed out" | Retry with backoff |

### 9.3 Workflow Pipeline for Reviews (Plan Mode - No Direct Mutations)

```yaml
# ~/.config/ntm/workflows/github-review.yaml
schema_version: "2.0"
name: github-review
description: |
  Automated GitHub issue and PR review workflow (Plan Mode).
  Agent produces local patches + review-plan.json artifact.
  NO direct GitHub mutations - ru applies approved actions separately.

inputs:
  worktree_path:
    description: Path to isolated worktree (not main repo)
    required: true
  repo_name:
    description: GitHub repo identifier (owner/repo)
    required: true
  repo_digest_path:
    description: Path to cached repo digest (if exists)
    required: false
  work_items:
    description: JSON array of work items to review
    required: true

settings:
  timeout: "45m"
  on_error: "fail"
  notify_on_error: true

steps:
  - id: verify_prerequisites
    type: shell
    command: |
      gh auth status || exit 1
      # Verify worktree exists and is clean
      test -d "${inputs.worktree_path}/.git" || exit 1
      test -d "${inputs.worktree_path}/.ru" || mkdir -p "${inputs.worktree_path}/.ru"
    on_failure: abort

  - id: understand_codebase
    agent: claude
    depends_on: [verify_prerequisites]
    prompt: |
      First read ALL of AGENTS.md and README.md carefully.

      ${inputs.repo_digest_path ? "
      A prior repo digest exists at .ru/repo-digest.md - read it first.
      Then update it based on changes since last review:
        • inspect git log since the last review timestamp
        • inspect changed files and any new architecture decisions
      " : "
      No prior digest exists. Create a comprehensive repo digest covering:
        • Project purpose and architecture
        • Key files and modules
        • Patterns and conventions used
      "}

      Write the updated digest to .ru/repo-digest.md.
      Use ultrathink.
    working_dir: ${inputs.worktree_path}
    wait: completion
    timeout: 10m
    health_check:
      interval: 30s
      max_stalls: 3

  - id: review_issues_prs
    agent: claude
    depends_on: [understand_codebase]
    prompt: |
      POLICY: We don't allow PRs or outside contributions. The maintainer's
      disclosed policy:

      > *About Contributions:* I do not accept outside contributions. I don't
      have the mental bandwidth to review anything, and it's my name on the
      thing. Feel free to submit issues and PRs to illustrate fixes, but I
      won't merge them directly. Claude will review and independently decide
      whether and how to address them. Bug reports are welcome.

      TASK: Review the following work items using `gh` to read details:
      ${inputs.work_items}

      For each item:
      1. Read the issue/PR independently via `gh issue view` or `gh pr view`
      2. Verify claims independently - don't trust user reports blindly
      3. Check dates against recent commits (many issues may be stale)
      4. If actionable: create local commits with fixes/features
      5. If needs clarification: prepare a question for the maintainer

      CRITICAL RESTRICTIONS:
      - DO NOT run `gh issue comment`, `gh issue close`, `gh pr comment`, etc.
      - DO NOT push any changes
      - Only use `gh` for READ operations (view, list)
      - All mutations will be applied by ru in a separate phase

      REQUIRED OUTPUT:
      You MUST produce a structured review plan artifact at:
        .ru/review-plan.json

      Contract:
      - `.ru/review-plan.json` MUST be strictly valid JSON (no markdown fences, no trailing commas).
      - It MUST conform to Section 8.5 “Review Plan Artifact (schema v1)”.
      - Required decisions: `fix` | `skip` | `needs-info` | `closed`

      Minimum required shape (see Section 8.5 for full schema/fields):
      {
        "schema_version": 1,
        "run_id": "${env.REVIEW_RUN_ID}",
        "repo": "${inputs.repo_name}",
        "worktree_path": "${inputs.worktree_path}",
        "items": [
          {
            "type": "issue|pr",
            "number": 123,
            "title": "...",
            "priority": "critical|high|normal|low",
            "decision": "fix|skip|needs-info|closed",
            "notes": "..."
          }
        ],
        "questions": [
          {
            "id": "q1",
            "prompt": "...",
            "options": [{"label":"A","description":"..."},{"label":"B","description":"..."}],
            "recommended": "A",
            "answered": false
          }
        ],
        "git": {
          "branch": "current branch name",
          "base_ref": "main",
          "commits": [{"sha": "...", "subject": "..."}],
          "tests": {"ran": true, "ok": true, "command": "...", "output_summary": "..."}
        },
        "gh_actions": [
          {"op": "comment", "target": "issue#42", "body": "..."},
          {"op": "close", "target": "issue#42", "reason": "completed"}
        ],
        "metadata": {
          "started_at": "ISO-8601",
          "completed_at": "ISO-8601",
          "model": "model identifier",
          "driver": "ntm|local"
        }
      }

      Questions (interactive coordination):
      - When you need maintainer input, use the `AskUserQuestion` tool (see Section 8.2).
      - Provide 2–4 options with `label` + `description`, set `multiSelect=false`.
      - Mirror any asked question into `.ru/review-plan.json` under `questions[]` with `answered=false`.
        If the maintainer answers during the same run, set `answered=true`, add `answer` + `answered_at`.

      Use ultrathink.
    working_dir: ${inputs.worktree_path}
    wait: user_interaction
    timeout: 30m
    on_question:
      action: queue
      priority: ${question.urgency:-normal}
      metadata:
        repo: ${inputs.repo_name}
        worktree: ${inputs.worktree_path}

  - id: finalize_artifacts
    type: shell
    depends_on: [review_issues_prs]
    command: |
      # Verify review plan was created
      test -f "${inputs.worktree_path}/.ru/review-plan.json" || {
        echo "ERROR: Missing review plan artifact"
        exit 1
      }
      # Validate JSON
      jq empty "${inputs.worktree_path}/.ru/review-plan.json" || {
        echo "ERROR: Invalid JSON in review plan"
        exit 1
      }
      echo "Artifacts ready for apply phase"
    on_failure: abort

outputs:
  plan_path:
    value: ${inputs.worktree_path}/.ru/review-plan.json
  digest_path:
    value: ${inputs.worktree_path}/.ru/repo-digest.md
  items_reviewed:
    description: Number of items reviewed
    value: ${steps.review_issues_prs.items_count:-0}
```

### 9.3.1 Canonical Prompt Templates (ru-generated)

These templates are the recommended canonical prompts for both drivers (`ntm` and `local`).
They are designed to be copy-pasteable into `claude -p ... --output-format stream-json` and
to produce the artifacts ru needs without transcript scraping.

```bash
# Generate the “digest” prompt (writes/updates .ru/repo-digest.md)
generate_digest_prompt() {
  cat <<'EOF'
First read ALL of AGENTS.md and README.md carefully.

If a prior digest exists at `.ru/repo-digest.md`, read it first, then update it based on changes since the last review:
  - inspect `git log` since the last digest timestamp
  - inspect changed files and any new architecture decisions

If no digest exists, create a comprehensive digest covering:
  - project purpose and architecture
  - key files/modules and their roles
  - conventions, quality gates, and how to run tests

Write the updated digest to `.ru/repo-digest.md`.
EOF
}

# Generate the “review work items” prompt (must write .ru/review-plan.json)
# Args: repo_name worktree_path run_id work_items_json
generate_review_prompt() {
  local repo_name="$1"
  local worktree_path="$2"
  local run_id="$3"
  local work_items_json="$4"

  # NOTE: Avoid unquoted heredocs here so any backticks/$() inside $work_items_json
  # cannot trigger command substitution during prompt generation.
  printf '%s\n' \
    "POLICY: We don't allow PRs or outside contributions. Feel free to submit issues and PRs to illustrate fixes, but they will not be merged directly. The agent reviews and independently decides whether and how to address submissions. Bug reports are welcome." \
    "" \
    'TASK: Review the following work items using `gh` READ operations only:'

  printf '%s\n' "$work_items_json"

  printf '%s\n' \
    "" \
    "For each item:" \
    '1) Read the issue/PR independently via `gh issue view` or `gh pr view`.' \
    "2) Verify claims independently; do not trust reports blindly." \
    "3) Check dates against recent commits (issues/PRs may be stale)." \
    "4) If actionable: create local commits with focused fixes." \
    '5) If unclear: ask the maintainer using the `AskUserQuestion` tool (see Section 8.2).' \
    "" \
    "CRITICAL RESTRICTIONS (PLAN MODE):" \
    '- DO NOT run any `gh` mutation commands (comment/close/label/merge/etc).' \
    "- DO NOT push any changes." \
    "- Prefer minimal, reviewable commits; avoid broad refactors unless justified." \
    "" \
    "REQUIRED OUTPUT (contract):" \
    '- You MUST write `.ru/review-plan.json` as strictly valid JSON.' \
    "- It MUST conform to Section 8.5 (schema v1)." \
    "- Set:" \
    "  - schema_version: 1" \
    "  - run_id: \"$run_id\"" \
    "  - repo: \"$repo_name\"" \
    "  - worktree_path: \"$worktree_path\"" \
    "  - metadata.model: your model id" \
    "  - metadata.driver: \"ntm\" or \"local\"" \
    "" \
    "If you ask any maintainer questions:" \
    '- Use `AskUserQuestion` with 2–4 options (label+description), multiSelect=false.' \
    '- Mirror those into `.ru/review-plan.json` under `questions[]` with answered=false until answered.'
}
```

### 9.4 New ntm Components Needed

```
internal/
├── review/
│   ├── detector.go      # Question detection logic
│   ├── aggregator.go    # Question queue management
│   ├── router.go        # Answer routing
│   └── state.go         # Review state persistence
├── cli/
│   ├── review_dashboard.go  # TUI dashboard command
│   └── review_start.go      # Start review sessions
└── workflows/
    └── templates/
        └── github-review.yaml  # Built-in review workflow
```

### 9.5 Communication Protocol

```
ru (Bash) ←──────────────────────→ ntm (Go)
    │                                  │
    │  ntm --robot-spawn               │
    │  ──────────────────────────────▶│
    │                                  │
    │  {"status":"ok","session":"..."}│
    │◀──────────────────────────────── │
    │                                  │
    │  ntm --robot-status              │
    │  ──────────────────────────────▶│
    │                                  │
    │  {"sessions":[...],"questions":[...]}
    │◀──────────────────────────────── │
    │                                  │
    │  ntm --robot-answer              │
    │  --question-id=123               │
    │  --answer="a"                    │
    │  ──────────────────────────────▶│
    │                                  │
    │  {"status":"ok","routed":true}  │
    │◀──────────────────────────────── │
```

### 9.6 Question Context Extraction (ntm Go Code)

```go
// Extract relevant context around a question
func ExtractQuestionContext(output string, maxLines int) string {
    lines := strings.Split(output, "\n")

    // Find the question line
    questionIdx := -1
    for i := len(lines) - 1; i >= 0; i-- {
        if isQuestionLine(lines[i]) {
            questionIdx = i
            break
        }
    }

    if questionIdx == -1 {
        // No question found, return last N lines
        start := max(0, len(lines)-maxLines)
        return strings.Join(lines[start:], "\n")
    }

    // Get context before and after question
    start := max(0, questionIdx-10)
    end := min(len(lines), questionIdx+5)

    return strings.Join(lines[start:end], "\n")
}
```

### 9.7 Answer Routing (ntm Go Code)

```go
// Route answer back to appropriate session
func RouteAnswer(question *Question, answer string) error {
    // Get the tmux pane
    pane, err := tmux.GetPane(question.SessionID, question.PaneID)
    if err != nil {
        return err
    }

    // Send the answer
    return pane.SendKeys(answer + "\n")
}
```

### 9.8 Activity Detection (ntm Go Code + Wait Reasons)

```go
// Activity states for Claude Code
const (
    StateGenerating = "GENERATING"  // High output velocity (>10 chars/sec)
    StateWaiting    = "WAITING"     // Idle at prompt, ready for input
    StateThinking   = "THINKING"    // Low velocity, processing
    StateError      = "ERROR"       // Error patterns detected
    StateStalled    = "STALLED"     // No output for extended period
)

// Wait reasons: WHY the system believes we are waiting
// This is critical for proper question routing and UX
const (
    WaitAskUserQuestion = "ask_user_question"  // Structured tool call detected
    WaitAgentQuestion   = "agent_question_text" // Text-based question at prompt
    WaitExternalPrompt  = "external_prompt"     // Shell, git, auth prompt
    WaitUnknown         = "unknown"             // Waiting but reason unclear
)

// WaitInfo provides context about why a session is waiting
type WaitInfo struct {
    Reason      string   // One of Wait* constants
    Context     string   // Relevant output context
    Options     []string // Detected options if any
    Recommended string   // Suggested response if determinable
    RiskLevel   string   // low, medium, high
}

// Detection heuristics with wait reason extraction
func DetectClaudeState(pane *Pane) (state string, waitInfo *WaitInfo) {
    output := pane.CaptureLastN(50)  // Last 50 lines
    velocity := pane.OutputVelocity()
    lastActivity := pane.LastActivityTime()

    // Check for error patterns first (highest priority)
    if containsErrorPattern(output) {
        return StateError, nil
    }

    // Check for stall (no output for 5+ minutes while previously active)
    if velocity == 0 && time.Since(lastActivity) > 5*time.Minute {
        return StateStalled, nil
    }

    // Check for waiting state with reason detection
    if velocity < 1.0 && containsPromptPattern(output) {
        waitInfo := &WaitInfo{RiskLevel: "low"}

        // Priority 1: Structured AskUserQuestion tool call
        if askUserQ := extractAskUserQuestion(output); askUserQ != nil {
            waitInfo.Reason = WaitAskUserQuestion
            waitInfo.Context = askUserQ.Question
            waitInfo.Options = askUserQ.Options
            waitInfo.Recommended = askUserQ.Recommended
            return StateWaiting, waitInfo
        }

        // Priority 2: Agent asking a text-based question
        if questionText := extractQuestionText(output); questionText != "" {
            waitInfo.Reason = WaitAgentQuestion
            waitInfo.Context = questionText
            waitInfo.Options = extractInlineOptions(output)
            return StateWaiting, waitInfo
        }

        // Priority 3: External prompt (git conflict, auth, shell)
        if extPrompt := detectExternalPrompt(output); extPrompt != "" {
            waitInfo.Reason = WaitExternalPrompt
            waitInfo.Context = extPrompt
            waitInfo.RiskLevel = classifyExternalPromptRisk(extPrompt)
            return StateWaiting, waitInfo
        }

        // Unknown wait state
        waitInfo.Reason = WaitUnknown
        waitInfo.Context = output[len(output)-min(len(output), 500):]
        return StateWaiting, waitInfo
    }

    // Check for active generation
    if velocity > 10.0 {
        return StateGenerating, nil
    }

    return StateThinking, nil
}

// Detect external prompts that might block the agent
func detectExternalPrompt(output string) string {
    externalPatterns := []struct {
        pattern string
        desc    string
    }{
        {`CONFLICT.*Merge conflict`, "git merge conflict"},
        {`Please enter.*commit message`, "git commit prompt"},
        {`Enter passphrase`, "SSH key passphrase"},
        {`Password:`, "password prompt"},
        {`\(yes/no\)`, "SSH host verification"},
        {`error: cannot pull with rebase`, "git rebase conflict"},
        {`Username for`, "git credentials prompt"},
        {`gh auth login`, "gh auth required"},
    }

    for _, p := range externalPatterns {
        if regexp.MustCompile(p.pattern).MatchString(output) {
            return p.desc
        }
    }
    return ""
}

// Classify risk level of external prompts
func classifyExternalPromptRisk(prompt string) string {
    highRisk := []string{"password", "passphrase", "credential", "auth"}
    mediumRisk := []string{"conflict", "merge", "rebase"}

    lower := strings.ToLower(prompt)
    for _, pattern := range highRisk {
        if strings.Contains(lower, pattern) {
            return "high"
        }
    }
    for _, pattern := range mediumRisk {
        if strings.Contains(lower, pattern) {
            return "medium"
        }
    }
    return "low"
}

// Patterns indicating Claude is waiting for input
var waitingPatterns = []string{
    `^\s*>\s*$`,                    // Empty prompt
    `\[y/N\]`,                      // Yes/No prompt
    `\[Y/n\]`,                      // Yes/No prompt
    `Select.*:`,                    // Selection prompt
    `Enter.*:`,                     // Input prompt
    `Press Enter to continue`,     // Continuation prompt
}

// Patterns indicating a question in agent text
var questionPatterns = []string{
    `Should I`,
    `Do you want`,
    `Would you like`,
    `Please confirm`,
    `Choose.*:`,
    `Which.*\?`,
    `What.*\?`,
    `How should`,
}
```

### 9.9 Driver Selection (Unified Interface)

```bash
# Detect best available driver and validate prerequisites
check_review_prerequisites() {
    # Required: GitHub CLI
    if ! command -v gh &>/dev/null; then
        log_error "GitHub CLI (gh) is required for reviews"
        log_info "Install: https://cli.github.com/"
        return 3
    fi

    if ! gh auth status &>/dev/null; then
        log_error "GitHub CLI is not authenticated"
        log_info "Run: gh auth login"
        return 3
    fi

    # Required: Claude CLI with stream-json support
    if ! command -v claude &>/dev/null; then
        log_error "Claude CLI is required for reviews"
        log_info "Install: https://github.com/anthropics/claude-code"
        return 3
    fi

    # Required for local driver: tmux
    if ! command -v tmux &>/dev/null; then
        log_error "tmux is required for local driver"
        log_info "Install: brew install tmux (macOS) or apt install tmux (Linux)"
        return 3
    fi

    return 0
}

# Select the best available driver
# Both drivers implement the same interface and emit the same normalized events
detect_review_driver() {
    # Try ntm first (preferred - has advanced features)
    if command -v ntm &>/dev/null; then
        if ntm --robot-status &>/dev/null 2>&1; then
            log_verbose "Using ntm driver (robot mode available)"
            echo "ntm"
            return
        fi
        log_verbose "ntm found but robot mode unavailable"
    fi

    # Fall back to local driver (tmux + stream-json)
    if command -v tmux &>/dev/null && claude --version &>/dev/null; then
        log_verbose "Using local driver (tmux + stream-json)"
        echo "local"
        return
    fi

    log_error "No suitable driver available"
    echo "unsupported"
}

# Session Driver Interface (Bash implementation sketch)
# Both ntm and local drivers implement this interface

# start_session(repo_ctx) -> session_id
# send_to_session(session_id, message)
# stream_session(session_id) -> normalized events via callback
# interrupt_session(session_id)
# stop_session(session_id)

# Local driver implementation (tmux + stream-json)
local_driver_start() {
    local worktree_path="$1"
    local session_name="$2"
    local prompt="$3"

    # Create tmux session with Claude in stream-json mode
    tmux new-session -d -s "$session_name" -c "$worktree_path" \
        "claude -p '$prompt' --output-format stream-json 2>&1 | tee .ru/session.log"

    # Start background event parser
    start_event_parser "$session_name" "$worktree_path/.ru/session.log" &

    echo "$session_name"
}

local_driver_send() {
    local session_id="$1"
    local message="$2"
    tmux send-keys -t "$session_id" "$message" Enter
}

# Normalized event schema (same for both drivers)
# {
#   "type": "init|generating|waiting|complete|error",
#   "session_id": "...",
#   "wait_info": {          # only if type=waiting
#     "reason": "ask_user_question|agent_question_text|external_prompt|unknown",
#     "context": "...",
#     "options": [...],
#     "recommended": "...",
#     "risk_level": "low|medium|high"
#   },
#   "timestamp": "..."
# }
```

---

## 10. Performance Optimization Strategies

### 10.1 GitHub API Optimization (GraphQL Alias Batching)

Note: Discovery now uses true GraphQL alias batching (see Section 7.1.2).
This replaces the per-repo O(n) approach with chunked batch queries.

```bash
# GraphQL alias batching is implemented in gh_api_graphql_repo_batch()
# Key benefits:
# - 10-100× fewer API calls
# - Single round-trip per chunk of 25 repos
# - Returns all metadata needed for scoring in one response

# Cache discovery results (invalidated on config change)
CACHE_TTL_DISCOVERY=300  # 5 minutes
get_discovery_cache_key() {
    # Hash of repo list + config
    local config_hash
    config_hash=$(get_config_hash)
    echo "discovery-${config_hash}"
}
```

### 10.2 Parallel Session Management

```bash
# Initial parallelism calculation (adjusted by governor)
calculate_optimal_parallelism() {
    local total_repos="$1"

    # The real source of truth is the rate-limit governor (see 10.2.1)
    # This provides a starting point

    # Factors:
    # - API rate limits (read from gh api rate_limit, not guessed)
    # - Claude rate limits (detected via 429 responses)
    # - System resources (memory, CPU)
    # - Context quality (too many sessions = divided attention)

    local max_by_resources=8        # Based on typical system
    local max_by_quality=6          # Optimal for attention

    local optimal=$((total_repos < max_by_quality ? total_repos : max_by_quality))
    optimal=$((optimal < max_by_resources ? optimal : max_by_resources))

    echo "$optimal"
}
```

### 10.2.1 Adaptive Rate-Limit Governor (GitHub + Model)

The scheduler runs with a governor that dynamically adjusts concurrency based on
real rate limit data, not static heuristics.

```bash
# Governor state
declare -A GOVERNOR_STATE=(
    [github_remaining]=5000
    [github_reset]=0
    [model_in_backoff]=false
    [model_backoff_until]=0
    [effective_parallelism]=4
    [circuit_breaker_open]=false
)

# Start governor loop (runs in background during review)
start_rate_limit_governor() {
    local check_interval=30  # seconds

    while [[ -f "$RU_STATE_DIR/review.lock" ]]; do
        update_github_rate_limit
        check_model_rate_limit
        adjust_parallelism
        sleep "$check_interval"
    done &
    GOVERNOR_PID=$!
}

# Query actual GitHub rate limit
update_github_rate_limit() {
    local rate_info
    rate_info=$(gh api rate_limit 2>/dev/null) || return 1

    GOVERNOR_STATE[github_remaining]=$(echo "$rate_info" | jq '.resources.core.remaining')
    GOVERNOR_STATE[github_reset]=$(echo "$rate_info" | jq '.resources.core.reset')

    # Check if approaching limit
    if [[ ${GOVERNOR_STATE[github_remaining]} -lt 500 ]]; then
        log_warn "GitHub API rate limit low: ${GOVERNOR_STATE[github_remaining]} remaining"
        GOVERNOR_STATE[effective_parallelism]=1
    fi
}

# Detect model rate limits from session streams
check_model_rate_limit() {
    local now
    now=$(date +%s)

    # Check for recent 429 errors in session logs
    local recent_429s
    recent_429s=$(grep -l "rate.limit\|429\|quota.exceeded" \
        "$RU_STATE_DIR/worktrees/$REVIEW_RUN_ID"/*/.ru/session.log 2>/dev/null | wc -l)

    if [[ $recent_429s -gt 2 ]]; then
        GOVERNOR_STATE[model_in_backoff]=true
        GOVERNOR_STATE[model_backoff_until]=$((now + 60))
        log_warn "Model rate limit detected, backing off for 60s"
    elif [[ ${GOVERNOR_STATE[model_in_backoff]} == "true" ]] && \
         [[ $now -gt ${GOVERNOR_STATE[model_backoff_until]} ]]; then
        GOVERNOR_STATE[model_in_backoff]=false
    fi
}

# Adjust parallelism based on current conditions
adjust_parallelism() {
    local target=${REVIEW_PARALLEL:-4}

    # Reduce if GitHub rate limit low
    if [[ ${GOVERNOR_STATE[github_remaining]} -lt 1000 ]]; then
        target=$((target / 2))
        [[ $target -lt 1 ]] && target=1
    fi

    # Reduce if model in backoff
    if [[ ${GOVERNOR_STATE[model_in_backoff]} == "true" ]]; then
        target=1
    fi

    # Circuit breaker: too many errors in sliding window
    local recent_errors
    recent_errors=$(count_recent_session_errors 300)  # last 5 minutes
    if [[ $recent_errors -gt 5 ]]; then
        GOVERNOR_STATE[circuit_breaker_open]=true
        target=0
        log_error "Circuit breaker open: too many errors, pausing new sessions"
    fi

    GOVERNOR_STATE[effective_parallelism]=$target
}

# Called by scheduler before starting new session
can_start_new_session() {
    [[ ${GOVERNOR_STATE[circuit_breaker_open]} == "true" ]] && return 1
    [[ ${GOVERNOR_STATE[model_in_backoff]} == "true" ]] && return 1

    local active_sessions
    active_sessions=$(count_active_sessions)
    [[ $active_sessions -ge ${GOVERNOR_STATE[effective_parallelism]} ]] && return 1

    return 0
}
```

### 10.3 Pre-fetching Strategy

```bash
# While reviewing repo N, pre-fetch data for repo N+1, N+2
prefetch_next_repos() {
    local current_index="$1"
    local repos=("${@:2}")
    local prefetch_count=2

    for ((i=1; i<=prefetch_count; i++)); do
        local next_index=$((current_index + i))
        if [[ $next_index -lt ${#repos[@]} ]]; then
            local next_repo="${repos[next_index]}"

            # Background fetch
            (
                get_repo_activity_cached "$next_repo" >/dev/null
                # Also warm git fetch
                local local_path
                local_path=$(get_repo_local_path "$next_repo")
                [[ -d "$local_path" ]] && git -C "$local_path" fetch --quiet 2>/dev/null
            ) &
        fi
    done
}
```

### 10.4 Smart Session Reuse

```bash
# Reuse existing Claude sessions when possible
get_or_create_session() {
    local repo_path="$1"
    local session_id="$2"

    # Check for existing session with context
    if ntm --robot-status 2>/dev/null | jq -e ".sessions[\"$session_id\"]" >/dev/null 2>&1; then
        local context_usage
        context_usage=$(ntm --robot-activity="$session_id:1" 2>/dev/null | jq -r '.context_usage // 100')

        if (( $(echo "$context_usage < 70" | bc -l) )); then
            # Reuse existing session
            echo "$session_id"
            return 0
        fi
    fi

    # Create new session
    create_new_session "$repo_path" "$session_id"
}
```

---

## 11. Priority Scoring Algorithm

### 11.1 Score Components

```python
# Pseudo-code for clarity (implemented in Bash)

def calculate_priority_score(repo):
    score = 0

    # Component 1: Issue/PR Volume (0-100 points)
    score += min(repo.open_issues * 10, 50)
    score += min(repo.open_prs * 20, 50)

    # Component 2: Label-Based Priority (0-100 points)
    for label in repo.labels:
        if label in ['security', 'critical']:
            score += 50
        elif label in ['bug', 'urgent']:
            score += 30
        elif label in ['enhancement', 'feature']:
            score += 10

    # Component 3: Age Factor (0-50 points)
    oldest_issue_days = repo.get_oldest_issue_age_days()
    if oldest_issue_days > 60:
        score += 50
    elif oldest_issue_days > 30:
        score += 30
    elif oldest_issue_days > 14:
        score += 15

    # Component 4: Staleness Penalty (0-40 points)
    days_since_review = repo.get_days_since_last_review()
    if days_since_review > 60:
        score += 40
    elif days_since_review > 30:
        score += 25
    elif days_since_review > 14:
        score += 10

    # Component 5: Engagement Signal (0-30 points)
    # High engagement = users care about this repo
    recent_comments = repo.get_comment_count_last_7_days()
    if recent_comments > 10:
        score += 30
    elif recent_comments > 5:
        score += 15
    elif recent_comments > 0:
        score += 5

    # Component 6: PR vs Issue Preference (0-20 points)
    # PRs indicate someone invested effort
    if repo.open_prs > 0:
        score += 20

    return score
```

### 11.2 Priority Thresholds

| Score Range | Priority Level | Color | Behavior |
|-------------|----------------|-------|----------|
| 150+ | CRITICAL | Red | Process immediately |
| 100-149 | HIGH | Orange | Process in first batch |
| 50-99 | NORMAL | Yellow | Process when capacity available |
| 0-49 | LOW | Gray | Process last or skip if `--skip-low` |

### 11.3 Bash Implementation

```bash
calculate_priority_score() {
    local repo_id="$1"
    local issues="${2:-0}"
    local prs="${3:-0}"

    local score=0

    # Volume component
    local vol_issues=$((issues * 10))
    [[ $vol_issues -gt 50 ]] && vol_issues=50
    local vol_prs=$((prs * 20))
    [[ $vol_prs -gt 50 ]] && vol_prs=50
    score=$((score + vol_issues + vol_prs))

    # Label component (requires API call - cached)
    local label_score=0
    local labels
    labels=$(gh issue list -R "$repo_id" --state open --json labels --jq '.[].labels[].name' 2>/dev/null | sort -u)
    if echo "$labels" | grep -qiE 'security|critical'; then
        label_score=50
    elif echo "$labels" | grep -qiE 'bug|urgent'; then
        label_score=30
    elif echo "$labels" | grep -qiE 'enhancement|feature'; then
        label_score=10
    fi
    score=$((score + label_score))

    # Age component
    local oldest_days
    oldest_days=$(get_oldest_issue_age "$repo_id")
    if [[ $oldest_days -gt 60 ]]; then
        score=$((score + 50))
    elif [[ $oldest_days -gt 30 ]]; then
        score=$((score + 30))
    elif [[ $oldest_days -gt 14 ]]; then
        score=$((score + 15))
    fi

    # Staleness component
    local days_since_review
    days_since_review=$(get_days_since_review "$repo_id")
    if [[ $days_since_review -gt 60 ]]; then
        score=$((score + 40))
    elif [[ $days_since_review -gt 30 ]]; then
        score=$((score + 25))
    elif [[ $days_since_review -gt 14 ]]; then
        score=$((score + 10))
    fi

    # PR bonus
    [[ $prs -gt 0 ]] && score=$((score + 20))

    echo "$score"
}

get_priority_level() {
    local score="$1"
    if [[ $score -ge 150 ]]; then echo "CRITICAL"
    elif [[ $score -ge 100 ]]; then echo "HIGH"
    elif [[ $score -ge 50 ]]; then echo "NORMAL"
    else echo "LOW"
    fi
}
```

---

## 12. TUI Design

### 12.1 Main Dashboard (ntm Mode)

```
╭───────────────────────────────────────────────────────────────────────────────╮
│  🔍 ru review                                              Progress: 5/8  ████░│
│  Session: ru-review-12345                                    Runtime: 12:34   │
╰───────────────────────────────────────────────────────────────────────────────╯

╭─ PENDING QUESTIONS (3) ───────────────────────────────────────────────────────╮
│                                                                               │
│  [1] ● project-alpha        Issue #42        Priority: ██████████ CRITICAL   │
│      ────────────────────────────────────────────────────────────────────    │
│      Context: Authentication failing on Windows                               │
│                                                                               │
│      I found the root cause in auth.py:234 - path handling uses forward      │
│      slashes which fail on Windows. Should I:                                │
│                                                                               │
│      ▸ a) Quick fix      Fix only this path (5 lines, minimal risk)         │
│        b) Full refactor  Modernize all path handling (45 lines)             │
│        c) Skip           Not a priority right now                            │
│                                                                               │
│  ─────────────────────────────────────────────────────────────────────────── │
│                                                                               │
│  [2] ○ project-beta         PR #15           Priority: ██████░░░░ NORMAL     │
│      PR proposes Redis caching. Verified approach is sound but adds dep.    │
│      [Press Enter to expand]                                                  │
│                                                                               │
│  [3] ○ project-gamma        Issue #7         Priority: ███░░░░░░░ LOW        │
│      Feature request: dark mode support                                      │
│      [Press Enter to expand]                                                  │
│                                                                               │
╰───────────────────────────────────────────────────────────────────────────────╯

╭─ ACTIVE SESSIONS ─────────────────────────────────────────────────────────────╮
│  Repo               State         Progress  ETA       Health                 │
│  ─────────────────────────────────────────────────────────────────────────── │
│  project-delta      GENERATING    ████████░░ 80%     ~2m       ● Healthy     │
│  project-epsilon    THINKING      ██████░░░░ 60%     ~5m       ● Healthy     │
│  project-zeta       WAITING       ████░░░░░░ 40%     ~8m       ● Healthy     │
│  project-eta        QUEUED        ░░░░░░░░░░  0%     ~12m      ○ Pending     │
╰───────────────────────────────────────────────────────────────────────────────╯

╭─ SUMMARY ─────────────────────────────────────────────────────────────────────╮
│  Completed: 4  │  Issues Resolved: 7  │  PRs Closed: 1  │  Commits: 12       │
╰───────────────────────────────────────────────────────────────────────────────╯

 [1-9] Answer  [↵] Expand  [d] Drill  [s] Skip  [a] Skip All  [p] Pause  [q] Quit
```

### 12.2 Drill-Down View

```
╭─ project-alpha ─ Session Detail ──────────────────────────────────────── [ESC]╮
│                                                                               │
│  Repository:  https://github.com/owner/project-alpha                          │
│  Local Path:  ~/projects/project-alpha                                        │
│  Session ID:  ru-review-project-alpha                                         │
│  Duration:    12m 34s                                                         │
│  Context:     45% used (estimated 18K tokens)                                 │
│                                                                               │
│  ═══════════════════════════════════════════════════════════════════════════ │
│  ISSUE #42: Authentication failing on Windows                                 │
│  ═══════════════════════════════════════════════════════════════════════════ │
│                                                                               │
│  Reported by: @user123 on 2025-12-15 (20 days ago)                           │
│                                                                               │
│  User's description:                                                          │
│  > When I try to login on Windows 11, I get "path not found" error.          │
│  > Works fine on Linux and macOS.                                            │
│                                                                               │
│  ─────────────────────────────────────────────────────────────────────────── │
│  CLAUDE'S ANALYSIS                                                            │
│  ─────────────────────────────────────────────────────────────────────────── │
│                                                                               │
│  I've independently verified this issue. The root cause is in auth.py:234:   │
│                                                                               │
│    config_path = home_dir + "/config/auth.json"  # Uses forward slash        │
│                                                                               │
│  On Windows, this creates an invalid path. The pathlib migration in commit   │
│  abc123 (2025-11-20) didn't fully address this.                              │
│                                                                               │
│  Two options:                                                                 │
│                                                                               │
│  Option A: Minimal fix                                                        │
│    - Add: config_path = os.path.join(home_dir, "config", "auth.json")        │
│    - 5 lines changed, 1 file                                                  │
│    - Risk: Low                                                                │
│                                                                               │
│  Option B: Full refactor                                                      │
│    - Convert all path handling to pathlib                                     │
│    - 45 lines changed, 3 files                                                │
│    - Risk: Medium (more surface area)                                         │
│    - Benefit: Consistent, future-proof                                        │
│                                                                               │
│  ─────────────────────────────────────────────────────────────────────────── │
│                                                                               │
│   [a] Quick fix    [b] Full refactor    [c] Skip    [v] View full session    │
╰───────────────────────────────────────────────────────────────────────────────╯
```

### 12.3 Basic Mode (gum-based)

```bash
show_question_basic_mode() {
    local repo="$1"
    local question="$2"
    local options_json="$3"

    echo ""
    gum style --border rounded --padding "1 2" --border-foreground "#fab387" \
        "Question from: $repo"
    echo ""
    echo "$question"
    echo ""

    # Build options array
    local -a option_labels=()
    while IFS= read -r opt; do
        local label desc
        label=$(echo "$opt" | jq -r '.label')
        desc=$(echo "$opt" | jq -r '.description // ""')
        if [[ -n "$desc" ]]; then
            option_labels+=("$label - $desc")
        else
            option_labels+=("$label")
        fi
    done < <(echo "$options_json" | jq -c '.[]')

    gum choose "${option_labels[@]}"
}
```

### 12.4 Keyboard Shortcuts (Enhanced)

| Key | Action | Context |
|-----|--------|---------|
| `1-9` | Select and answer question | Main |
| `Enter` | Expand/collapse question | Main |
| `d` | Drill-down to full session | Main |
| `s` | Skip current question | Main |
| `S` | Skip all questions (with confirm) | Main |
| `z` | Snooze item/question (1d/7d/30d) | Main |
| `t` | Insert response template | Main |
| `b` | Bulk apply safe approvals (low-risk + tests pass) | Main |
| `a` | Apply approved changes (Plan → Apply) | Main |
| `p` | Pause new sessions | Main |
| `r` | Resume paused sessions | Main |
| `h` | Show help overlay | Any |
| `q` | Quit (with confirm if active) | Any |
| `Esc` | Back / Cancel | Drill-down |
| `v` | View raw session output | Drill-down |
| `P` | View patch summary (changed files, LOC, test status) | Drill-down |
| `a`/`b`/`c` | Quick answer selection | Drill-down |
| `j`/`k` or `↑`/`↓` | Navigate questions | Main |
| `/` | Search questions | Main |
| `Tab` | Switch between panels | Main |

### 12.4.1 Snooze Feature

Snooze allows deferring items without skipping them permanently:

```bash
# Snooze durations
SNOOZE_1D=86400      # 1 day
SNOOZE_7D=604800     # 7 days
SNOOZE_30D=2592000   # 30 days

snooze_item() {
    local item_key="$1"
    local duration="$2"

    local until_ts
    until_ts=$(($(date +%s) + duration))

    write_json_atomic "$RU_STATE_DIR/snoozed.json" \
        "$(jq --arg key "$item_key" --arg until "$until_ts" \
            '.[$key] = $until' "$RU_STATE_DIR/snoozed.json")"
}

is_snoozed() {
    local item_key="$1"
    local now
    now=$(date +%s)

    local until_ts
    until_ts=$(jq -r --arg key "$item_key" '.[$key] // 0' "$RU_STATE_DIR/snoozed.json")

    [[ $until_ts -gt $now ]]
}
```

### 12.4.2 Response Templates

Pre-configured responses for common patterns:

```bash
# ~/.config/ru/templates/
# ├── stale-issue.md
# ├── duplicate.md
# ├── needs-info.md
# ├── wontfix.md
# └── thank-you.md

load_response_templates() {
    local templates_dir="$RU_CONFIG_DIR/templates"
    declare -gA RESPONSE_TEMPLATES

    for file in "$templates_dir"/*.md; do
        [[ -f "$file" ]] || continue
        local name="${file##*/}"
        name="${name%.md}"
        RESPONSE_TEMPLATES["$name"]=$(cat "$file")
    done
}

show_template_picker() {
    local selected
    selected=$(printf '%s\n' "${!RESPONSE_TEMPLATES[@]}" | gum choose)
    echo "${RESPONSE_TEMPLATES[$selected]}"
}
```

### 12.4.3 Bulk Apply (Safe Approvals)

Apply all low-risk changes that pass quality gates:

```bash
bulk_apply_safe() {
    local -a safe_plans=()

    # Find plans that are safe to auto-apply
    for plan_file in "$RU_STATE_DIR/worktrees/$REVIEW_RUN_ID"/*/.ru/review-plan.json; do
        [[ -f "$plan_file" ]] || continue

        local risk_level tests_ok
        risk_level=$(jq -r '.git.tests.risk_level // "medium"' "$plan_file")
        tests_ok=$(jq -r '.git.tests.ok // false' "$plan_file")

        # Only auto-apply if:
        # - All items are low-risk
        # - Tests ran and passed
        # - No unanswered questions
        if [[ "$risk_level" == "low" ]] && [[ "$tests_ok" == "true" ]]; then
            local unanswered
            unanswered=$(jq '[.questions[] | select(.answered != true)] | length' "$plan_file")
            if [[ $unanswered -eq 0 ]]; then
                safe_plans+=("$plan_file")
            fi
        fi
    done

    if [[ ${#safe_plans[@]} -eq 0 ]]; then
        log_info "No plans qualify for bulk apply"
        return 0
    fi

    log_info "Found ${#safe_plans[@]} plans eligible for bulk apply"

    if gum_confirm "Apply ${#safe_plans[@]} safe plans?"; then
        for plan_file in "${safe_plans[@]}"; do
            local wt_path="${plan_file%/.ru/review-plan.json}"
            apply_single_plan "$wt_path" "$plan_file"
        done
    fi
}
```

### 12.4.4 Patch Summary View

Show what changed before approving:

```bash
show_patch_summary() {
    local plan_file="$1"
    local wt_path="${plan_file%/.ru/review-plan.json}"

    # Extract summary from plan
    local branch commits_count files_changed lines_added lines_removed test_status

    branch=$(jq -r '.git.branch' "$plan_file")
    commits_count=$(jq '.git.commits | length' "$plan_file")
    test_status=$(jq -r 'if .git.tests.ok then "PASS" else "FAIL" end' "$plan_file")

    # Get diff stats
    local diff_stat
    diff_stat=$(git -C "$wt_path" diff --stat HEAD~"$commits_count"..HEAD 2>/dev/null || echo "No changes")

    gum style --border rounded --padding "1 2" << EOF
PATCH SUMMARY: $(basename "$wt_path")
═══════════════════════════════════════════════════════════════

Branch: $branch
Commits: $commits_count
Tests: $test_status

Changed Files:
$diff_stat

Items Addressed:
$(jq -r '.items[] | "  • \(.type) #\(.number): \(.decision)"' "$plan_file")

gh_actions Pending:
$(jq -r '.gh_actions[] | "  • \(.op) \(.target)"' "$plan_file")
EOF
}

### 12.5 Accessibility Considerations

```yaml
# Accessibility settings in ~/.config/ru/config
REVIEW_ACCESSIBLE_MODE="auto"  # auto, true, false
# When enabled:
# - No animations
# - High contrast colors
# - Screen reader hints
# - Simplified layout
# - Clear focus indicators
```

---

## 13. Error Handling and Recovery

### 13.1 Error Categories

| Category | Examples | Recovery Strategy |
|----------|----------|-------------------|
| **Transient** | Network timeout, API 500 | Retry with exponential backoff |
| **Rate Limit** | API 429, Claude quota | Backoff, rotate sessions, alert |
| **Auth** | Token expired, invalid key | Alert user, pause session |
| **Session** | Claude crash, OOM | Auto-restart, preserve state |
| **User** | Invalid input, cancel | Graceful handling, resume |
| **Fatal** | Disk full, permissions | Abort with clear message |

### 13.2 Retry Strategy

```bash
# Exponential backoff with jitter
retry_with_backoff() {
    local cmd="$1"
    local max_attempts="${2:-5}"
    local base_delay="${3:-1}"

    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        if eval "$cmd"; then
            return 0
        fi

        local delay=$((base_delay * (2 ** (attempt - 1))))
        # Add jitter (±25%)
        local jitter=$((delay / 4))
        delay=$((delay + RANDOM % (jitter * 2) - jitter))

        log_warn "Attempt $attempt failed, retrying in ${delay}s..."
        sleep "$delay"
        ((attempt++))
    done

    return 1
}
```

### 13.3 Session Recovery

```bash
# Checkpoint state periodically
checkpoint_review_state() {
    local state_file="$RU_STATE_DIR/review-checkpoint.json"

    local state
    state=$(cat << EOF
{
  "version": 1,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "run_id": "$REVIEW_RUN_ID",
  "mode": "$REVIEW_MODE",
  "repos_total": ${#REVIEW_REPOS[@]},
  "repos_completed": ${#COMPLETED_REPOS[@]},
  "repos_pending": $(printf '%s\n' "${PENDING_REPOS[@]}" | jq -R . | jq -s .),
  "questions_pending": $(echo "$QUESTIONS_JSON" | jq .),
  "sessions": $(get_active_sessions_json)
}
EOF
)
    echo "$state" > "$state_file"
}

# Resume from checkpoint
resume_from_checkpoint() {
    local checkpoint_file="$RU_STATE_DIR/review-checkpoint.json"

    if [[ ! -f "$checkpoint_file" ]]; then
        log_error "No checkpoint found to resume"
        return 1
    fi

    local state
    state=$(cat "$checkpoint_file")

    # Restore state
    REVIEW_RUN_ID=$(echo "$state" | jq -r '.run_id')
    REVIEW_MODE=$(echo "$state" | jq -r '.mode')

    # Restore pending repos
    PENDING_REPOS=()
    while IFS= read -r repo; do
        PENDING_REPOS+=("$repo")
    done < <(echo "$state" | jq -r '.repos_pending[]')

    log_info "Resumed from checkpoint: ${#PENDING_REPOS[@]} repos remaining"
}
```

### 13.4 Graceful Degradation

```bash
# Fallback chain for mode selection
select_best_mode() {
    # Try ntm first
    if command -v ntm &>/dev/null; then
        if ntm --robot-status &>/dev/null; then
            echo "ntm"
            return
        fi
        log_warn "ntm available but not responding, falling back"
    fi

    # Try stream-json mode
    if claude --version &>/dev/null; then
        echo "stream"
        return
    fi

    # Fall back to basic
    echo "basic"
}
```

---

## 14. Security Considerations

### 14.1 Authentication and Tokens

| Token | Storage | Risk | Mitigation |
|-------|---------|------|------------|
| GitHub (gh) | gh's secure store | Medium | Use gh CLI, never store raw |
| Anthropic API | System keychain | High | Environment variable, not file |
| ntm sessions | Local only | Low | Tmux session security |

### 14.2 Code Execution Safety (Plan Mode Restrictions)

Claude operates under an explicit execution policy enforced by the workflow:

**Plan Mode (default):**
- Read/Write/Edit files in the isolated worktree only
- Run local commands (git, grep, make, npm test, etc.)
- `gh` is READ-ONLY: `gh issue view`, `gh pr view`, `gh issue list` allowed
- `gh` MUTATIONS BLOCKED: `gh issue comment`, `gh issue close`, `gh pr merge` etc.
- NO direct push to remote
- All mutations are deferred to Apply phase

**Apply Mode (--apply):**
- ru (not the agent) executes approved actions from review-plan.json
- Quality gates run before any push
- Human confirmation required for high-risk operations

```bash
# Safe Bash command allowlist for agent
SAFE_BASH_COMMANDS=(
    "git" "grep" "rg" "ag" "find" "ls" "cat" "head" "tail"
    "make" "npm" "yarn" "pnpm" "cargo" "go" "python" "pytest"
    "shellcheck" "eslint" "prettier" "black" "ruff"
    "jq" "yq" "sed" "awk" "sort" "uniq" "wc" "diff"
)

# Commands that require human approval
APPROVAL_REQUIRED_COMMANDS=(
    "rm" "mv" "cp"  # File operations
    "curl" "wget"   # Network operations
    "docker" "kubectl"  # Container operations
)

# Blocked commands (never allowed)
BLOCKED_COMMANDS=(
    "sudo" "su"
    "chmod +x" "chown"
    "eval" "exec"
)

# Validate command before execution (called by pre-exec hook)
validate_agent_command() {
    local cmd="$1"
    local first_word="${cmd%% *}"

    # Check blocked list
    for blocked in "${BLOCKED_COMMANDS[@]}"; do
        if [[ "$cmd" == *"$blocked"* ]]; then
            log_error "Blocked command: $cmd"
            return 1
        fi
    done

    # Check gh mutations
    if [[ "$first_word" == "gh" ]]; then
        if echo "$cmd" | grep -qE 'comment|close|merge|label|edit|delete'; then
            log_error "gh mutations blocked in Plan mode: $cmd"
            return 1
        fi
    fi

    # Check approval required
    for approval in "${APPROVAL_REQUIRED_COMMANDS[@]}"; do
        if [[ "$first_word" == "$approval" ]]; then
            queue_command_approval_question "$cmd"
            return 2  # Pending approval
        fi
    done

    return 0
}
```

### 14.2.1 Quality Gates Before Push (Tests/Lint)

ru supports per-repo quality gates that must pass before pushing:

```bash
# Quality gate configuration (per-repo or global)
# ~/.config/ru/review-policies.d/<owner>_<repo>.conf
# or ~/.config/ru/config

# Example:
# REVIEW_TEST_CMD="make test"
# REVIEW_LINT_CMD="npm run lint"
# REVIEW_REQUIRE_TESTS=true

run_quality_gates() {
    local wt_path="$1"
    local plan_file="$2"

    # Load per-repo policy if exists
    local repo_id
    repo_id=$(jq -r '.repo' "$plan_file")
    local policy_file="$RU_CONFIG_DIR/review-policies.d/${repo_id//\//_}.conf"
    [[ -f "$policy_file" ]] && source "$policy_file"

    local test_cmd="${REVIEW_TEST_CMD:-}"
    local lint_cmd="${REVIEW_LINT_CMD:-}"
    local require_tests="${REVIEW_REQUIRE_TESTS:-false}"

    # Run lint if configured
    if [[ -n "$lint_cmd" ]]; then
        log_step "Running lint: $lint_cmd"
        if ! (cd "$wt_path" && eval "$lint_cmd"); then
            log_error "Lint failed"
            return 1
        fi
    fi

    # Run tests if configured
    if [[ -n "$test_cmd" ]]; then
        log_step "Running tests: $test_cmd"
        if ! (cd "$wt_path" && eval "$test_cmd"); then
            log_error "Tests failed"
            return 1
        fi
    elif [[ "$require_tests" == "true" ]]; then
        # Auto-detect test command
        if [[ -f "$wt_path/Makefile" ]] && grep -q "^test:" "$wt_path/Makefile"; then
            test_cmd="make test"
        elif [[ -f "$wt_path/package.json" ]]; then
            test_cmd="npm test"
        elif [[ -f "$wt_path/Cargo.toml" ]]; then
            test_cmd="cargo test"
        fi

        if [[ -n "$test_cmd" ]]; then
            log_step "Auto-detected test command: $test_cmd"
            if ! (cd "$wt_path" && eval "$test_cmd"); then
                log_error "Tests failed"
                return 1
            fi
        fi
    fi

    # Secret scanning (optional: use gitleaks if available)
    if command -v gitleaks &>/dev/null; then
        log_step "Scanning for secrets with gitleaks"
        if ! gitleaks detect --source "$wt_path" --no-git; then
            log_error "Secrets detected in changes"
            return 1
        fi
    else
        # Fallback to regex scan
        if git -C "$wt_path" diff HEAD~1..HEAD | grep -qiE \
            'password\s*=|api.?key\s*=|secret\s*=|token\s*=|private.?key'; then
            log_warn "Potential secrets detected (install gitleaks for better detection)"
            queue_question "secrets_warning" "$repo_id" "Potential secrets detected. Review and proceed?"
            return 2  # Pending human review
        fi
    fi

    log_success "Quality gates passed"
    return 0
}
```

### 14.3 Data Privacy

```bash
# What's logged (review-state.json)
# - Repo names (public info)
# - Issue/PR numbers (public info)
# - Decision metadata (your choices)
# - Timestamps

# What's NOT logged
# - Full issue content
# - PR code
# - API tokens
# - File contents
# - Session transcripts (stored separately with restricted permissions)
```

### 14.4 Rate Limit Management

```bash
# Track API usage to avoid rate limiting
track_api_usage() {
    local api="$1"  # github, anthropic
    local cost="${2:-1}"

    local usage_file="$RU_STATE_DIR/api-usage-${api}.json"
    local now
    now=$(date +%s)

    # Clean old entries (older than 1 hour)
    if [[ -f "$usage_file" ]]; then
        jq --arg cutoff "$((now - 3600))" \
           '[.[] | select(.ts > ($cutoff | tonumber))]' \
           "$usage_file" > "${usage_file}.tmp"
        mv "${usage_file}.tmp" "$usage_file"
    else
        echo "[]" > "$usage_file"
    fi

    # Add new entry
    jq --arg ts "$now" --arg cost "$cost" \
       '. + [{"ts": ($ts | tonumber), "cost": ($cost | tonumber)}]' \
       "$usage_file" > "${usage_file}.tmp"
    mv "${usage_file}.tmp" "$usage_file"

    # Check if approaching limit
    local total
    total=$(jq '[.[].cost] | add // 0' "$usage_file")

    case "$api" in
        github)
            if [[ $total -gt 4500 ]]; then  # 5000/hour limit
                log_warn "Approaching GitHub API rate limit: $total/5000"
            fi
            ;;
        anthropic)
            if [[ $total -gt 900 ]]; then  # Varies by tier
                log_warn "Approaching Anthropic rate limit"
            fi
            ;;
    esac
}
```

---

## 15. Metrics, Analytics, and Learning

### 15.1 Metrics Collection

```json
// ~/.local/state/ru/metrics/2025-01.json
{
  "period": "2025-01",
  "reviews": {
    "total": 45,
    "repos_reviewed": 23,
    "issues_processed": 89,
    "prs_processed": 12,
    "issues_resolved": 67,
    "prs_closed": 8,
    "questions_asked": 34,
    "questions_answered": 32,
    "questions_skipped": 2
  },
  "timing": {
    "total_duration_minutes": 340,
    "avg_per_repo_minutes": 14.8,
    "avg_question_response_seconds": 45
  },
  "decisions": {
    "by_type": {
      "quick_fix": 23,
      "full_refactor": 8,
      "skip": 12,
      "implement_feature": 5
    },
    "by_repo": {
      "project-alpha": {"quick_fix": 5, "skip": 2},
      "project-beta": {"full_refactor": 3}
    }
  },
  "errors": {
    "rate_limits": 2,
    "session_crashes": 1,
    "network_failures": 3
  }
}
```

### 15.2 Learning from Decisions

```bash
# Track decision patterns for future suggestions
record_decision() {
    local repo_id="$1"
    local issue_type="$2"      # bug, feature, question, security
    local decision="$3"        # fix, skip, defer, discuss
    local labels="$4"          # comma-separated

    local decisions_file="$RU_STATE_DIR/decisions.jsonl"

    local entry
    printf -v entry '{"ts":"%s","repo":"%s","type":"%s","decision":"%s","labels":[%s]}' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$repo_id" \
        "$issue_type" \
        "$decision" \
        "$(echo "$labels" | sed 's/,/","/g' | sed 's/^/"/' | sed 's/$/"/')"

    echo "$entry" >> "$decisions_file"
}

# Suggest based on past patterns
suggest_decision() {
    local issue_type="$1"
    local labels="$2"

    local decisions_file="$RU_STATE_DIR/decisions.jsonl"
    [[ ! -f "$decisions_file" ]] && return

    # Find similar past decisions
    local similar_decisions
    similar_decisions=$(grep "\"type\":\"$issue_type\"" "$decisions_file" | tail -20)

    # Count most common decision
    local most_common
    most_common=$(echo "$similar_decisions" | jq -r '.decision' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')

    if [[ -n "$most_common" ]]; then
        echo "Based on past similar issues, you usually choose: $most_common"
    fi
}
```

### 15.3 Analytics Dashboard

```bash
ru review --analytics

╭─ Review Analytics ─ Last 30 Days ────────────────────────────────────────────╮
│                                                                               │
│  OVERVIEW                                                                     │
│  ─────────────────────────────────────────────────────────────────────────── │
│  Reviews:      45                    Issues Resolved:    67                   │
│  Repos:        23                    PRs Handled:        12                   │
│  Avg Time:     14.8 min/repo         Questions:          34                   │
│                                                                               │
│  DECISION BREAKDOWN                                                           │
│  ─────────────────────────────────────────────────────────────────────────── │
│  Quick Fix       ███████████████████████░░░░░  68%                           │
│  Full Refactor   ████████░░░░░░░░░░░░░░░░░░░░  24%                           │
│  Skip            ███░░░░░░░░░░░░░░░░░░░░░░░░░   8%                           │
│                                                                               │
│  TOP REPOS BY ACTIVITY                                                        │
│  ─────────────────────────────────────────────────────────────────────────── │
│  1. project-alpha      12 issues, 3 PRs                                       │
│  2. project-beta        8 issues, 2 PRs                                       │
│  3. project-gamma       5 issues, 0 PRs                                       │
│                                                                               │
│  EFFICIENCY TREND                                                             │
│  ─────────────────────────────────────────────────────────────────────────── │
│  Week 1:  18 min/repo                                                         │
│  Week 2:  16 min/repo    ↓ 11%                                               │
│  Week 3:  14 min/repo    ↓ 13%                                               │
│  Week 4:  12 min/repo    ↓ 14%                                               │
│                                                                               │
╰───────────────────────────────────────────────────────────────────────────────╯
```

---

## 16. Real-World Edge Cases

### 16.1 Stale Issues

**Scenario**: Issue reports bug that was already fixed.

```
Claude's approach:
1. Check issue date against recent commits
2. Search for related fixes in git log
3. Attempt to reproduce the bug
4. If fixed: Comment explaining fix commit, close issue
5. If still present: Proceed with fix
```

### 16.2 Duplicate Issues

**Scenario**: Multiple issues report same problem.

```
Claude's approach:
1. Search for similar issue titles/descriptions
2. Check if issues share keywords/symptoms
3. If duplicates found:
   - Keep oldest issue as primary
   - Comment on duplicates linking to primary
   - Close duplicates with "Duplicate of #X"
```

### 16.3 Can't Reproduce Bug

**Scenario**: Issue describes problem Claude can't verify.

```
Claude's approach:
1. Document reproduction attempts
2. Ask specific questions via gh comment:
   - OS/environment details
   - Steps to reproduce
   - Error messages/logs
3. Add "needs-info" label
4. Queue for follow-up in next review
```

### 16.4 Hostile/Rude Users

**Scenario**: User is aggressive or disrespectful.

```
Claude's approach:
1. Focus only on technical content
2. Respond professionally, ignore tone
3. If purely hostile with no content:
   - Close without engagement
   - Don't explain or justify
4. Flag for human review if threatening
```

### 16.5 Scope Creep in Feature Requests

**Scenario**: Feature request is large/invasive.

```
Claude's approach:
1. Acknowledge the idea's merits
2. Explain scope concerns
3. Ask maintainer for direction:
   "This would add 500+ lines and a new dependency.
    Options:
    a) Implement as proposed
    b) Implement minimal version
    c) Decline as out of scope"
```

### 16.6 PR with Good Idea, Bad Implementation

**Scenario**: PR concept is good but code is wrong.

```
Claude's approach:
1. Thank user for the idea
2. Explain the policy (no direct merges)
3. Describe what will happen:
   "I'll implement this independently,
    incorporating your concept with
    proper error handling/tests."
4. Implement from scratch
5. Credit user in commit message
6. Close PR referencing new commit
```

### 16.7 Security Vulnerability

**Scenario**: Issue reports security problem.

```
Claude's approach:
1. CRITICAL priority - process immediately
2. Verify independently
3. If valid:
   - Implement fix without public details
   - Coordinate disclosure with maintainer
   - Credit reporter appropriately
4. If not valid:
   - Explain why (without confirming specifics)
   - Thank for responsible disclosure attempt
```

---

## 17. Risk Mitigation

### 17.1 Technical Risks

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Claude API changes | Medium | High | Version detection, fallback modes |
| ntm incompatibility | Low | Medium | Graceful degradation to basic mode |
| Rate limiting | High | Medium | Backoff, caching, quota tracking |
| Session instability | Medium | Medium | Checkpointing, auto-recovery |
| Output parsing errors | Low | Low | Pattern validation, graceful handling |

### 17.2 User Experience Risks

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Information overload | Medium | Medium | Priority scoring, progressive disclosure |
| Lost context | Low | High | Full session drill-down, output logging |
| Accidental answers | Low | Medium | Confirmation for destructive actions |
| Interrupted sessions | Medium | Medium | State persistence, resume capability |

### 17.3 Operational Risks

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Wrong fix deployed | Low | High | Dry-run mode, push confirmation |
| Offensive response | Very Low | High | Policy in prompt, human review flag |
| Missed security issue | Low | Critical | Security label priority boost |
| Over-automation | Medium | Medium | Human-in-the-loop for all decisions |

---

## 18. Future Enhancements

### 18.1 Short-term (v1.1)

- [ ] Batch answers: Answer similar questions across repos at once
- [ ] Answer templates: Pre-configured responses for common patterns
- [ ] Notification integration: Desktop/Slack/webhook alerts
- [ ] Improved caching: Smarter TTL based on repo activity

### 18.2 Medium-term (v1.5)

- [ ] Learning suggestions: "You usually choose X for this type"
- [ ] Multi-model support: Use Claude for review, GPT for responses
- [ ] Scheduled reviews: Cron-based automatic runs
- [ ] Team support: Multiple maintainers, role-based decisions
- [ ] Web dashboard: Browser-based alternative to TUI

### 18.3 Long-term (v2.0)

- [ ] Autonomous mode: AI handles routine issues without input
- [ ] Cross-repo intelligence: Learn patterns across all repositories
- [ ] Community interaction: Auto-respond to common questions
- [ ] Predictive prioritization: ML-based priority scoring
- [ ] Integration marketplace: Plugins for different workflows

---

## Appendix A: Command Reference

### A.1 `ru review` (Plan → Apply)

```
ru review - Review GitHub issues and PRs using Claude Code

USAGE:
    ru review [options]

EXECUTION MODES:
    --plan              Generate plans/patches only (default, safe)
    --apply             Apply approved plans (push, gh comments, close, labels)

OPTIONS:
    --mode=MODE         Driver mode: auto, ntm, local (default: auto)
    --parallel=N        Parallel sessions (default: 4, adjusted by governor)
    --repos=PATTERN     Only review repos matching pattern
    --skip-days=N       Skip repos reviewed within N days (default: 7)
    --priority=LEVEL    Min priority: all, normal, high, critical (default: all)
    --dry-run           Discovery only, don't start sessions
    --resume            Resume interrupted session
    --push              Allow pushing changes (only valid with --apply)
    --no-push           Don't push changes (default)
    --json              Output progress as JSON

COST BUDGET OPTIONS:
    --max-repos=N       Limit to N repositories
    --max-runtime=MIN   Stop after N minutes
    --max-questions=N   Limit human questions to N

EXAMPLES:
    ru review                              # Plan-only review (safe default)
    ru review --dry-run                    # Preview what would be reviewed
    ru review --apply --push               # Apply approved changes + push
    ru review --repos="myorg/*"            # Only repos in myorg
    ru review --priority=high              # Only high/critical priority
    ru review --parallel=8                 # More parallel sessions
    ru review --resume                     # Resume interrupted review
    ru review --max-repos=5 --max-questions=10  # Limited run
```

### A.2 `ru review-status`

```
ru review-status - Show review session status

USAGE:
    ru review-status [options]

OPTIONS:
    --active            Show active sessions only
    --history           Show review history
    --repo=REPO         Status for specific repo
    --json              Output as JSON
```

### A.3 `ru review --analytics`

```
ru review --analytics - Show review analytics

OPTIONS:
    --days=N            Show last N days (default: 30)
    --repo=REPO         Analytics for specific repo
    --export=FILE       Export to JSON file
```

---

## Appendix B: Configuration Reference

```bash
# ~/.config/ru/config

#==============================================================================
# Review Settings
#==============================================================================

# Orchestration mode: auto, ntm, basic
REVIEW_MODE="auto"

# Number of parallel sessions (ntm mode)
REVIEW_PARALLEL=4

# Skip repos reviewed within N days
REVIEW_SKIP_DAYS=7

# Minimum priority level: all, normal, high, critical
REVIEW_MIN_PRIORITY="all"

# Custom prompts directory
REVIEW_PROMPTS_DIR="$RU_CONFIG_DIR/review-prompts"

# Phase timeouts (seconds)
REVIEW_UNDERSTAND_TIMEOUT=600
REVIEW_REVIEW_TIMEOUT=1800

# API rate limit safety margin (percentage)
REVIEW_RATE_LIMIT_MARGIN=10

# Enable analytics collection
REVIEW_ANALYTICS="true"

# Checkpoint interval (seconds)
REVIEW_CHECKPOINT_INTERVAL=60

# Accessible mode: auto, true, false
REVIEW_ACCESSIBLE_MODE="auto"

# Desktop notifications
REVIEW_NOTIFY="true"
```

---

## Appendix C: State File Formats (Atomic + Item-Level)

State files use atomic writes with flock to prevent corruption from concurrent access
or interrupted writes. Item-level tracking enables accurate per-issue/PR analytics.

### C.0 State Locking

```bash
# Global lock for all state file operations
acquire_state_lock() {
    local lock_file="$RU_STATE_DIR/review.lock"
    exec 200>"$lock_file"
    flock -n 200 || return 1
}

release_state_lock() {
    flock -u 200 2>/dev/null || true
}

# Atomic JSON write helper
write_json_atomic() {
    local file="$1"
    local content="$2"
    local tmp_file="${file}.tmp.$$"

    echo "$content" > "$tmp_file"
    mv "$tmp_file" "$file"
}
```

### C.1 Review State (`~/.local/state/ru/review-state.json`)

```json
{
  "version": 2,
  "lock": {
    "path": "~/.local/state/ru/review.lock",
    "strategy": "flock"
  },
  "repos": {
    "owner/repo": {
      "last_review": "2025-01-04T10:30:00Z",
      "last_review_run_id": "abc123",
      "issues_reviewed": 3,
      "prs_reviewed": 1,
      "issues_resolved": 2,
      "prs_closed": 0,
      "outcome": "completed",
      "duration_seconds": 847,
      "digest_hash": "sha256:..."
    }
  },
  "items": {
    "owner/repo#issue-42": {
      "type": "issue",
      "number": 42,
      "last_review": "2025-01-04T10:30:00Z",
      "outcome": "fixed",
      "plan_hash": "sha256:abc123...",
      "notes": "Path handling fixed for Windows"
    },
    "owner/repo#pr-15": {
      "type": "pr",
      "number": 15,
      "last_review": "2025-01-04T10:35:00Z",
      "outcome": "closed",
      "plan_hash": "sha256:def456...",
      "notes": "Idea implemented independently"
    }
  },
  "runs": {
    "abc123": {
      "started_at": "2025-01-04T10:00:00Z",
      "completed_at": "2025-01-04T11:30:00Z",
      "repos_processed": 8,
      "items_processed": 14,
      "questions_asked": 12,
      "questions_answered": 10,
      "questions_skipped": 2,
      "mode": "ntm",
      "driver": "ntm",
      "worktrees_path": "~/.local/state/ru/worktrees/abc123"
    }
  }
}
```

### C.2 Question Queue (`~/.local/state/ru/review-questions.json`)

```json
{
  "version": 1,
  "questions": [
    {
      "id": "q_abc123",
      "run_id": "run_xyz",
      "repo": "owner/repo",
      "session_id": "ru-review-owner-repo",
      "pane_id": "1",
      "context": "Should I refactor...",
      "options": ["a) Minimal fix", "b) Full refactor", "c) Skip"],
      "priority": "normal",
      "detected_at": "2025-01-04T10:45:00Z",
      "status": "pending"
    }
  ]
}
```

---

## Appendix D: Workflow Template

The canonical ntm workflow template now lives in `examples/github-review.yaml`.
Copy it to `~/.config/ntm/workflows/github-review.yaml` before running ntm workflows.

```yaml
# see examples/github-review.yaml for full template
```

---

## Appendix E: Glossary

| Term | Definition |
|------|------------|
| **ntm** | Named Tmux Manager - Go-based multi-agent orchestration tool |
| **Robot Mode** | ntm's JSON API for programmatic control |
| **Stream-JSON** | Claude Code output mode for programmatic parsing |
| **Activity Detection** | ntm's velocity-based agent state classification |
| **Hysteresis** | Stability filter preventing rapid state flapping |
| **Priority Score** | Calculated importance of reviewing a work item |
| **Work Item** | Individual issue or PR being reviewed |
| **Drill-down** | Viewing full session details from summary |
| **Checkpoint** | Saved state for session recovery |
| **Worktree** | Isolated git working tree for safe edits |
| **Session Driver** | Unified interface for ntm and local execution |
| **Review Plan Artifact** | Structured JSON output from agent session |
| **Quality Gate** | Test/lint checks before apply phase |
| **Rate-Limit Governor** | Adaptive concurrency controller |
| **Repo Digest** | Cached codebase understanding for incremental reviews |

---

## Appendix F: Repo Digest Cache

The repo digest cache eliminates repetitive "understand the codebase" work by
maintaining a persistent summary of each repository.

### F.1 Digest Storage

```
~/.local/state/ru/repo-digests/
├── owner_repo.md          # Cached digest
├── owner_repo.meta.json   # Metadata (last update, commit range)
└── owner_other.md
```

### F.2 Digest Format

```markdown
# Repo Digest: owner/repo

**Last Updated:** 2025-01-04T10:30:00Z
**Commit Range:** abc123..def456
**Review Run:** 20250104-103000-12345

## Purpose
Brief description of what this project does.

## Architecture
- Main entry point: src/main.py
- Key modules: auth/, api/, models/
- Database: SQLite with SQLAlchemy

## Patterns & Conventions
- Uses type hints throughout
- Tests in tests/ directory (pytest)
- CI: GitHub Actions (.github/workflows/)

## Recent Changes (since last review)
- Added new auth module (commit def456)
- Refactored API endpoints (commit cde789)

## Notes for Future Reviews
- Consider updating deprecated dependency X
- User #42 reported Windows issue (investigate)
```

### F.3 Digest Update Logic

```bash
prepare_repo_digests() {
    local repos=("$@")

    for repo_info in "${repos[@]}"; do
        local repo_id wt_path
        get_worktree_mapping "$repo_info" repo_id wt_path

        local digest_cache="$RU_STATE_DIR/repo-digests/${repo_id//\//_}.md"
        local meta_cache="$RU_STATE_DIR/repo-digests/${repo_id//\//_}.meta.json"

        if [[ -f "$digest_cache" ]] && [[ -f "$meta_cache" ]]; then
            # Copy cached digest to worktree
            cp "$digest_cache" "$wt_path/.ru/repo-digest.md"

            # Record commit range for delta update
            local last_commit
            last_commit=$(jq -r '.last_commit' "$meta_cache")
            local current_commit
            current_commit=$(git -C "$wt_path" rev-parse HEAD)

            # Provide delta info to agent
            if [[ "$last_commit" != "$current_commit" ]]; then
                local changes
                changes=$(git -C "$wt_path" log --oneline "$last_commit".."$current_commit" 2>/dev/null || echo "")
                echo -e "\n## Changes Since Last Review\n$changes" >> "$wt_path/.ru/repo-digest.md"
            fi
        fi
    done
}

# After successful review, update cache
update_digest_cache() {
    local wt_path="$1"
    local repo_id="$2"

    local digest_file="$wt_path/.ru/repo-digest.md"
    if [[ -f "$digest_file" ]]; then
        local cache_dir="$RU_STATE_DIR/repo-digests"
        mkdir -p "$cache_dir"

        cp "$digest_file" "$cache_dir/${repo_id//\//_}.md"

        local current_commit
        current_commit=$(git -C "$wt_path" rev-parse HEAD)

        cat > "$cache_dir/${repo_id//\//_}.meta.json" << EOF
{
  "last_commit": "$current_commit",
  "last_update": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "run_id": "$REVIEW_RUN_ID"
}
EOF
    fi
}
```

---

## Appendix G: Testing & Verification

### G.1 Bash Unit Tests (bats)

Key areas requiring comprehensive tests:

```bash
# test/test_graphql_batching.bats

@test "gh_api_graphql_repo_batch generates valid query" {
    local chunk=$'owner1/repo1\nowner2/repo2'
    local query
    query=$(gh_api_graphql_repo_batch "$chunk" --dry-run)

    [[ "$query" == *"repo0: repository(owner:\"owner1\", name:\"repo1\")"* ]]
    [[ "$query" == *"repo1: repository(owner:\"owner2\", name:\"repo2\")"* ]]
}

@test "calculate_item_priority_score returns expected scores" {
    # Security label should score highest
    local score
    score=$(calculate_item_priority_score "issue" "security,bug" "2024-12-01" "2025-01-01" "false")
    [[ $score -ge 80 ]]

    # Draft PR should score lower
    score=$(calculate_item_priority_score "pr" "enhancement" "2024-12-01" "2025-01-01" "true")
    [[ $score -lt 30 ]]
}

@test "write_json_atomic is atomic" {
    local file="$BATS_TMPDIR/test.json"
    echo '{"version":1}' > "$file"

    # Simulate concurrent write
    (
        sleep 0.1
        write_json_atomic "$file" '{"version":2}'
    ) &

    write_json_atomic "$file" '{"version":3}'
    wait

    # File should be valid JSON (not corrupted)
    jq empty "$file"
}
```

### G.2 Test Fixtures

Store NDJSON fixture streams for parsing tests:

```
test/fixtures/
├── claude_stream/
│   ├── basic_session.ndjson
│   ├── ask_user_question.ndjson
│   ├── external_prompt.ndjson
│   └── error_session.ndjson
├── gh/
│   ├── graphql_batch_response.json
│   ├── rate_limit_response.json
│   └── issue_list.json
└── plans/
    ├── simple_fix.json
    ├── multiple_items.json
    └── with_questions.json
```

### G.3 Integration Smoke Tests

```bash
# test/integration/test_review_flow.sh

setup() {
    # Create sandbox repos
    SANDBOX="$BATS_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"

    # Create test repo with fake issue
    create_test_repo "$SANDBOX/test-repo" "owner/test-repo"
}

@test "dry-run discovery finds test repo" {
    run ru review --dry-run --repos="owner/test-repo"
    [[ $status -eq 0 ]]
    [[ "$output" == *"test-repo"* ]]
}

@test "plan mode creates artifacts without pushing" {
    run ru review --mode=local --repos="owner/test-repo" --plan
    [[ $status -eq 0 ]]

    # Verify worktree was created
    [[ -d "$RU_STATE_DIR/worktrees"/*/"owner_test-repo" ]]

    # Verify plan artifact exists
    [[ -f "$RU_STATE_DIR/worktrees"/*/"owner_test-repo/.ru/review-plan.json" ]]

    # Verify nothing was pushed
    local remote_head
    remote_head=$(git -C "$SANDBOX/test-repo" rev-parse origin/main)
    local local_head
    local_head=$(git -C "$SANDBOX/test-repo" rev-parse main)
    [[ "$remote_head" == "$local_head" ]]
}

@test "apply mode requires explicit flag" {
    # Run plan first
    ru review --mode=local --repos="owner/test-repo" --plan

    # Apply without --push should not push
    run ru review --apply --no-push
    [[ $status -eq 0 ]]

    # Verify gh_actions were NOT executed
    # (would require mocking gh)
}
```

### G.4 Mocking External Dependencies

```bash
# test/mocks/gh_mock.sh

# Set up mock gh command
setup_gh_mock() {
    export GH_MOCK_DIR="$BATS_TMPDIR/gh_mock"
    mkdir -p "$GH_MOCK_DIR"

    # Create mock gh script
    cat > "$GH_MOCK_DIR/gh" << 'EOF'
#!/bin/bash
case "$*" in
    "api rate_limit")
        cat "$GH_MOCK_DIR/responses/rate_limit.json"
        ;;
    "api graphql"*)
        cat "$GH_MOCK_DIR/responses/graphql.json"
        ;;
    "issue list"*)
        cat "$GH_MOCK_DIR/responses/issues.json"
        ;;
    *)
        echo "Mock: unknown command: $*" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$GH_MOCK_DIR/gh"

    export PATH="$GH_MOCK_DIR:$PATH"
}
```

### G.5 Golden Plan Artifacts

Store expected plan outputs for regression testing:

```bash
@test "review produces expected plan for fixture repo" {
    # Run review on fixture
    ru review --mode=local --repos="fixture/simple-bug" --plan

    # Compare plan to golden file
    local plan_file
    plan_file=$(find "$RU_STATE_DIR/worktrees" -name "review-plan.json" | head -1)

    # Use jq to compare (ignore timestamps)
    local actual expected
    actual=$(jq 'del(.run_id, .git.commits[].sha)' "$plan_file")
    expected=$(jq 'del(.run_id, .git.commits[].sha)' "test/golden/simple-bug-plan.json")

    [[ "$actual" == "$expected" ]]
}
```

---

*Document Version: 3.0*
*Last Updated: January 2025*
*Author: Claude (Opus 4.5)*
*Word Count: ~15,000*
*Revision: Integrated 14 architectural improvements for production-grade reliability*
