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

**Prompt 1: Codebase Understanding**
```
First read ALL of the AGENTS.md file and README.md file super carefully
and understand ALL of both! Then use your code investigation agent mode
to fully understand the code, and technical architecture and purpose of
the project. Use ultrathink.
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

### 4.1 High-Level Vision

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              ru review                                       │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ PHASE 1: Discovery & Prioritization                                     ││
│  │  • Scan all repos for open issues/PRs via gh API                       ││
│  │  • Check last-review timestamps                                         ││
│  │  • Calculate priority scores                                            ││
│  │  • Build prioritized work queue                                         ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                     │                                        │
│                                     ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ PHASE 2: Parallel Orchestration                                         ││
│  │  • Launch Claude Code sessions (stream-json mode)                       ││
│  │  • Send understanding prompts                                           ││
│  │  • Monitor via ntm activity detection                                   ││
│  │  • Send review prompts upon completion                                  ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                     │                                        │
│                                     ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ PHASE 3: Question Aggregation                                           ││
│  │  • Detect AskUserQuestion tool calls in stream                          ││
│  │  • Extract question context and options                                 ││
│  │  • Score and prioritize questions                                       ││
│  │  • Queue for human review                                               ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                     │                                        │
│                                     ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ PHASE 4: Unified TUI                                                    ││
│  │  • Present aggregated questions with context                            ││
│  │  • Allow drill-down to full session                                     ││
│  │  • Route answers back to sessions                                       ││
│  │  • Track decisions for future learning                                  ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                     │                                        │
│                                     ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ PHASE 5: Completion & Reporting                                         ││
│  │  • Wait for session completion                                          ││
│  │  • Update review timestamps                                             ││
│  │  • Generate summary report                                              ││
│  │  • Clean up sessions                                                    ││
│  │  • Update analytics                                                     ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Key Requirements

| Requirement | Description | Priority |
|-------------|-------------|----------|
| **Selective Processing** | Only process repos with new/open issues or PRs | P0 |
| **Parallel Execution** | Run multiple reviews concurrently | P0 |
| **Question Aggregation** | Collect questions from all sessions | P0 |
| **Priority Scoring** | Handle important issues first | P1 |
| **Context Preservation** | Show enough context for decisions | P0 |
| **Drill-Down** | View full session for more detail | P1 |
| **State Persistence** | Resume after interruption | P1 |
| **Progress Tracking** | Show overall progress | P1 |
| **Error Recovery** | Handle Claude crashes, rate limits | P0 |
| **Metrics Collection** | Learn from decisions over time | P2 |

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
cmd_review() {
    # Scan repos, launch tmux sessions, poll output, show gum prompts
}
```

| Pros | Cons |
|------|------|
| Keeps ru as pure Bash | Bash awkward for complex TUI |
| No new dependencies | Limited concurrency control |
| Simple deployment | Output parsing is fragile |
| | No real-time monitoring |
| | Reinvents ntm functionality |

**Verdict**: ❌ Not recommended for full implementation.

### 5.2 Option B: Standalone Go/Rust Helper Binary

**Approach**: Create `ru-review` as a separate binary.

| Pros | Cons |
|------|------|
| Proper TUI support | New codebase to maintain |
| Better parsing/state | Duplicates ntm functionality |
| Good concurrency | More complex build/install |
| Type safety | Different language from ru |

**Verdict**: ⚠️ Reasonable but suboptimal given ntm exists.

### 5.3 Option C: Deep ntm Integration

**Approach**: Use ntm as orchestration engine, ru as repo management.

| Pros | Cons |
|------|------|
| Mature orchestration (~29K lines Go) | Adds ntm as dependency |
| Beautiful TUI already exists | Requires ntm setup |
| Health monitoring, restart | Two-language coordination |
| Robot mode for Bash→Go communication | |
| Workflow pipelines | |
| Session persistence | |

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

### 6.1 Component Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            User: ru review                                   │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         ru (Bash Layer)                                      │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  • Repo configuration and git operations                              │  │
│  │  • GitHub API queries via gh CLI                                      │  │
│  │  • Priority scoring and queue building                                │  │
│  │  • State persistence (review-state.json)                              │  │
│  │  • Mode detection (ntm vs basic)                                      │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │
                    ┌──────────────┴──────────────┐
                    │                             │
                    ▼                             ▼
┌───────────────────────────────────┐ ┌───────────────────────────────────────┐
│      Basic Mode (no ntm)          │ │         ntm Mode (full power)         │
│  ┌─────────────────────────────┐  │ │  ┌─────────────────────────────────┐  │
│  │ • Sequential processing     │  │ │  │ • Parallel sessions             │  │
│  │ • tmux + claude -p          │  │ │  │ • Stream-json monitoring        │  │
│  │ • Simple gum prompts        │  │ │  │ • Activity detection            │  │
│  │ • Regex output parsing      │  │ │  │ • Robot mode API                │  │
│  └─────────────────────────────┘  │ │  │ • Rich TUI dashboard            │  │
└───────────────────────────────────┘ │  │ • Health monitoring             │  │
                                      │  │ • Workflow pipelines            │  │
                                      │  └─────────────────────────────────┘  │
                                      └───────────────────────────────────────┘
                                                       │
                                                       ▼
                                      ┌───────────────────────────────────────┐
                                      │        Claude Code Sessions           │
                                      │  ┌─────────────────────────────────┐  │
                                      │  │ claude -p --output-format       │  │
                                      │  │   stream-json                   │  │
                                      │  │                                 │  │
                                      │  │ Events:                         │  │
                                      │  │ • assistant (text, tool_use)    │  │
                                      │  │ • user (tool_result)            │  │
                                      │  │ • result (completion)           │  │
                                      │  └─────────────────────────────────┘  │
                                      └───────────────────────────────────────┘
```

### 6.2 Data Flow

```
┌────────────┐    ┌────────────┐    ┌────────────┐    ┌────────────┐
│ GitHub API │───▶│  Priority  │───▶│  Session   │───▶│  Question  │
│  (gh CLI)  │    │  Scoring   │    │ Launcher   │    │  Detector  │
└────────────┘    └────────────┘    └────────────┘    └─────┬──────┘
                                                            │
┌────────────┐    ┌────────────┐    ┌────────────┐          │
│  Metrics   │◀───│   Answer   │◀───│    TUI     │◀─────────┘
│  Storage   │    │   Router   │    │  Display   │
└────────────┘    └────────────┘    └────────────┘
```

---

## 7. Implementation Plan

### 7.1 Phase 1: Core Infrastructure (Week 1-2)

#### 7.1.1 Add `ru review` Command

```bash
# In ru script - new command
cmd_review() {
    local mode="auto"
    local parallel=4
    local dry_run="false"
    local resume="false"
    local priority_threshold="all"  # all, normal, high

    # Parse arguments
    parse_review_args

    # Check prerequisites
    check_review_prerequisites || exit 3

    # Auto-detect mode
    if [[ "$mode" == "auto" ]]; then
        mode=$(detect_review_mode)
    fi

    # Discovery phase
    log_step "Scanning repositories for open issues and PRs..."
    local -a repos_needing_review
    discover_repos_needing_review repos_needing_review "$priority_threshold"

    if [[ ${#repos_needing_review[@]} -eq 0 ]]; then
        log_success "No repositories need review"
        return 0
    fi

    # Show discovery summary
    show_discovery_summary "${repos_needing_review[@]}"

    # Dispatch to mode
    case "$mode" in
        ntm)   run_review_ntm_mode "${repos_needing_review[@]}" ;;
        basic) run_review_basic_mode "${repos_needing_review[@]}" ;;
    esac
}
```

#### 7.1.2 GitHub Activity Detection

```bash
# Efficient batch query using gh
get_repos_with_activity() {
    local -n result_array=$1
    local repos_json

    # Get all configured repos
    local all_repos=()
    while IFS= read -r spec; do
        [[ -n "$spec" ]] && all_repos+=("$spec")
    done < <(get_all_repos)

    # Batch query GitHub (up to 100 repos per query)
    local batch_size=100
    local batch_start=0

    while [[ $batch_start -lt ${#all_repos[@]} ]]; do
        local batch=("${all_repos[@]:batch_start:batch_size}")

        for repo_spec in "${batch[@]}"; do
            local url branch custom_name local_path repo_id
            if ! resolve_repo_spec "$repo_spec" "$PROJECTS_DIR" "$LAYOUT" \
                url branch custom_name local_path repo_id; then
                continue
            fi

            # Get issue and PR counts with minimal API calls
            local activity
            activity=$(get_repo_activity_cached "$repo_id")

            local issues prs
            issues=$(echo "$activity" | jq -r '.issues')
            prs=$(echo "$activity" | jq -r '.prs')

            if [[ $((issues + prs)) -gt 0 ]]; then
                # Check if needs review (not recently reviewed)
                if needs_review "$repo_id" "$activity"; then
                    result_array+=("$repo_spec|$issues|$prs")
                fi
            fi
        done

        ((batch_start += batch_size))
    done
}

# Cache GitHub API responses (5-minute TTL)
get_repo_activity_cached() {
    local repo_id="$1"
    local cache_file="$RU_CACHE_DIR/activity/${repo_id//\//_}.json"
    local cache_ttl=300  # 5 minutes

    # Check cache
    if [[ -f "$cache_file" ]]; then
        local cache_age
        cache_age=$(($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file")))
        if [[ $cache_age -lt $cache_ttl ]]; then
            cat "$cache_file"
            return 0
        fi
    fi

    # Fetch fresh data
    mkdir -p "$(dirname "$cache_file")"
    local issues prs

    issues=$(gh issue list -R "$repo_id" --state open --json number,title,createdAt,labels,author \
        --jq 'length' 2>/dev/null || echo "0")
    prs=$(gh pr list -R "$repo_id" --state open --json number,title,createdAt,labels,author \
        --jq 'length' 2>/dev/null || echo "0")

    local result
    printf -v result '{"issues":%d,"prs":%d,"fetched_at":"%s"}' \
        "$issues" "$prs" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    echo "$result" > "$cache_file"
    echo "$result"
}
```

#### 7.1.3 Priority Scoring

```bash
# Calculate priority score for a repository
calculate_priority_score() {
    local repo_id="$1"
    local issues="$2"
    local prs="$3"

    local score=0

    # Base score from volume
    score=$((score + issues * 10))
    score=$((score + prs * 20))  # PRs weighted higher

    # Check for high-priority labels
    local high_priority_labels
    high_priority_labels=$(gh issue list -R "$repo_id" --state open \
        --label "bug,critical,security,urgent" --json number --jq 'length' 2>/dev/null || echo "0")
    score=$((score + high_priority_labels * 50))

    # Check issue age (older = higher priority)
    local oldest_issue_days
    oldest_issue_days=$(gh issue list -R "$repo_id" --state open --json createdAt \
        --jq 'map(.createdAt | fromdateiso8601) | min | (now - .) / 86400 | floor' 2>/dev/null || echo "0")
    if [[ $oldest_issue_days -gt 30 ]]; then
        score=$((score + 30))
    elif [[ $oldest_issue_days -gt 7 ]]; then
        score=$((score + 15))
    fi

    # Boost for repos not reviewed recently
    local days_since_review
    days_since_review=$(get_days_since_review "$repo_id")
    if [[ $days_since_review -gt 30 ]]; then
        score=$((score + 40))
    elif [[ $days_since_review -gt 14 ]]; then
        score=$((score + 20))
    fi

    echo "$score"
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

### 9.3 Workflow Pipeline for Reviews

```yaml
# ~/.config/ntm/workflows/github-review.yaml
schema_version: "2.0"
name: github-review
description: Review GitHub issues and PRs for a repository

inputs:
  repo_path:
    description: Path to local repository
    required: true
  repo_name:
    description: GitHub repo identifier (owner/repo)
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
      issues=$(gh issue list -R ${inputs.repo_name} --state open --json number --jq 'length')
      prs=$(gh pr list -R ${inputs.repo_name} --state open --json number --jq 'length')
      [ "$((issues + prs))" -gt 0 ] || { echo "No activity"; exit 0; }
    on_failure: abort

  - id: update_repo
    type: shell
    command: git -C "${inputs.repo_path}" pull --ff-only 2>/dev/null || true
    depends_on: [verify_prerequisites]

  - id: understand_codebase
    agent: claude
    depends_on: [update_repo]
    prompt: |
      First read ALL of the AGENTS.md file and README.md file super carefully
      and understand ALL of both! Then use your code investigation agent mode
      to fully understand the code, and technical architecture and purpose of
      the project. Use ultrathink.
    working_dir: ${inputs.repo_path}
    wait: completion
    timeout: 10m
    health_check:
      interval: 30s
      max_stalls: 3

  - id: review_issues_prs
    agent: claude
    depends_on: [understand_codebase]
    prompt: |
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
    working_dir: ${inputs.repo_path}
    wait: user_interaction
    timeout: 30m
    on_question:
      action: queue
      priority: normal

  - id: push_changes
    type: shell
    depends_on: [review_issues_prs]
    command: git -C "${inputs.repo_path}" push 2>/dev/null || true
    on_failure: warn

outputs:
  issues_addressed:
    value: ${steps.review_issues_prs.issues_count:-0}
  prs_reviewed:
    value: ${steps.review_issues_prs.prs_count:-0}
```

---

## 10. Performance Optimization Strategies

### 10.1 GitHub API Optimization

```bash
# Batch queries to reduce API calls
batch_fetch_repo_activity() {
    local repos=("$@")

    # Use GraphQL for batch queries (much faster than REST)
    local query='query($repos: [String!]!) {
      repositories: nodes(ids: $repos) {
        ... on Repository {
          nameWithOwner
          issues(states: OPEN) { totalCount }
          pullRequests(states: OPEN) { totalCount }
        }
      }
    }'

    # Execute batch query
    gh api graphql -f query="$query" \
        -f repos="$(printf '%s\n' "${repos[@]}" | jq -R . | jq -s .)"
}

# Cache with intelligent TTL
CACHE_TTL_ACTIVE=300     # 5 min for repos with activity
CACHE_TTL_INACTIVE=3600  # 1 hour for repos without activity
```

### 10.2 Parallel Session Management

```bash
# Optimal parallelism calculation
calculate_optimal_parallelism() {
    local total_repos="$1"

    # Factors:
    # - API rate limits (5000/hour for authenticated)
    # - Claude rate limits (varies by tier)
    # - System resources (memory, CPU)
    # - Context quality (too many sessions = divided attention)

    local max_by_rate_limit=10      # Conservative API limit
    local max_by_resources=8        # Based on typical system
    local max_by_quality=6          # Optimal for attention

    local optimal=$((total_repos < max_by_quality ? total_repos : max_by_quality))
    optimal=$((optimal < max_by_resources ? optimal : max_by_resources))
    optimal=$((optimal < max_by_rate_limit ? optimal : max_by_rate_limit))

    echo "$optimal"
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

### 12.4 Keyboard Shortcuts

| Key | Action | Context |
|-----|--------|---------|
| `1-9` | Select and answer question | Main |
| `Enter` | Expand/collapse question | Main |
| `d` | Drill-down to full session | Main |
| `s` | Skip current question | Main |
| `S` | Skip all questions (with confirm) | Main |
| `p` | Pause new sessions | Main |
| `r` | Resume paused sessions | Main |
| `h` | Show help overlay | Any |
| `q` | Quit (with confirm if active) | Any |
| `Esc` | Back / Cancel | Drill-down |
| `v` | View raw session output | Drill-down |
| `a`/`b`/`c` | Quick answer selection | Drill-down |
| `j`/`k` or `↑`/`↓` | Navigate questions | Main |
| `/` | Search questions | Main |
| `Tab` | Switch between panels | Main |

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

### 14.2 Code Execution Safety

```bash
# Claude operates in sandboxed repos
# - Only allowed tools: Read, Write, Edit, Bash, gh
# - Bash commands reviewed before execution
# - No network access except gh API
# - Changes are local until pushed

# Validation before push
validate_before_push() {
    local repo_path="$1"

    # Check for sensitive patterns
    if git -C "$repo_path" diff --cached | grep -qiE 'password|secret|api.?key|token'; then
        log_warn "Potential sensitive data detected in changes"
        return 1
    fi

    # Run any configured pre-push hooks
    if [[ -x "$repo_path/.git/hooks/pre-push" ]]; then
        "$repo_path/.git/hooks/pre-push"
    fi
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

### A.1 `ru review`

```
ru review - Review GitHub issues and PRs using Claude Code

USAGE:
    ru review [options]

OPTIONS:
    --mode=MODE         Orchestration mode: auto, ntm, basic (default: auto)
    --parallel=N        Parallel sessions in ntm mode (default: 4)
    --repos=PATTERN     Only review repos matching pattern
    --skip-days=N       Skip repos reviewed within N days (default: 7)
    --priority=LEVEL    Min priority: all, normal, high, critical (default: all)
    --dry-run           Preview without starting
    --resume            Resume interrupted session
    --no-push           Don't push changes (review only)
    --json              Output progress as JSON

EXAMPLES:
    ru review                              # Review all repos
    ru review --dry-run                    # Preview what would be reviewed
    ru review --repos="myorg/*"            # Only repos in myorg
    ru review --priority=high              # Only high/critical priority
    ru review --parallel=8                 # More parallel sessions
    ru review --resume                     # Resume interrupted review
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

## Appendix C: State File Formats

### C.1 Review State (`~/.local/state/ru/review-state.json`)

```json
{
  "version": 1,
  "repos": {
    "owner/repo": {
      "last_review": "2025-01-04T10:30:00Z",
      "last_review_run_id": "abc123",
      "issues_reviewed": 3,
      "prs_reviewed": 1,
      "issues_resolved": 2,
      "prs_closed": 0,
      "outcome": "completed",
      "duration_seconds": 847
    }
  },
  "runs": {
    "abc123": {
      "started_at": "2025-01-04T10:00:00Z",
      "completed_at": "2025-01-04T11:30:00Z",
      "repos_processed": 8,
      "questions_answered": 12,
      "mode": "ntm"
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

Full `github-review.yaml` workflow for ntm:

```yaml
schema_version: "2.0"
name: github-review
description: |
  Automated GitHub issue and PR review workflow.
  Uses Claude Code to understand codebase, review issues/PRs,
  implement fixes, and respond via gh CLI.

inputs:
  repo_path:
    description: Absolute path to local repository
    required: true
  repo_name:
    description: GitHub repository identifier (owner/repo)
    required: true
  understand_prompt:
    description: Custom codebase understanding prompt
    required: false
  review_prompt:
    description: Custom review prompt
    required: false

defaults:
  working_dir: ${inputs.repo_path}
  agent: claude

steps:
  - id: verify_prerequisites
    type: shell
    command: |
      # Verify gh is authenticated
      gh auth status || exit 1

      # Verify repo has issues or PRs
      issues=$(gh issue list -R ${inputs.repo_name} --state open --json number --jq 'length')
      prs=$(gh pr list -R ${inputs.repo_name} --state open --json number --jq 'length')

      if [ "$((issues + prs))" -eq 0 ]; then
        echo "No open issues or PRs"
        exit 0
      fi

      echo "Found $issues issues and $prs PRs"
    on_failure: abort

  - id: update_repo
    type: shell
    command: git pull --ff-only || true
    depends_on: [verify_prerequisites]

  - id: understand_codebase
    agent: claude
    depends_on: [update_repo]
    prompt: |
      ${inputs.understand_prompt:-
      First read ALL of the AGENTS.md file and README.md file super carefully
      and understand ALL of both! Then use your code investigation agent mode
      to fully understand the code, and technical architecture and purpose of
      the project. Use ultrathink.
      }
    wait: completion
    timeout: 10m
    health_check:
      interval: 30s
      max_stalls: 3

  - id: review_issues_prs
    agent: claude
    depends_on: [understand_codebase]
    prompt: |
      ${inputs.review_prompt:-
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
      }
    wait: user_interaction
    timeout: 30m
    on_question:
      action: queue
      priority: ${question.urgency:-normal}
      metadata:
        repo: ${inputs.repo_name}
        issue_context: true

  - id: finalize
    type: shell
    depends_on: [review_issues_prs]
    command: |
      # Push any commits made
      git push || true

      # Log completion
      echo "Review completed for ${inputs.repo_name}"
    on_failure: warn

outputs:
  issues_addressed:
    description: Number of issues that were addressed
    value: ${steps.review_issues_prs.issues_count:-0}
  prs_reviewed:
    description: Number of PRs that were reviewed
    value: ${steps.review_issues_prs.prs_count:-0}
  commits_made:
    description: Number of commits created
    value: ${steps.finalize.commit_count:-0}
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
| **Priority Score** | Calculated importance of reviewing a repo |
| **Drill-down** | Viewing full session details from summary |
| **Checkpoint** | Saved state for session recovery |

---

*Document Version: 2.0*
*Last Updated: January 2025*
*Author: Claude (Opus 4.5)*
*Word Count: ~10,000*
