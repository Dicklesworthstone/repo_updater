---
name: ru-review
description: Review GitHub issues and PRs across repositories using the ru CLI tool. Use when asked to review issues, PRs, or run ru review. CRITICAL - never stash or discard user changes; commit them first if needed.
---

# ru review - GitHub Issues/PRs Review Process

## Overview

The `ru` (Repo Updater) CLI has a built-in `ru review` command that reviews GitHub issues and PRs across all configured repositories using Claude. It includes the project's contribution policy automatically.

## ⚠️ CRITICAL RULES - NEVER VIOLATE THESE ⚠️

### 1. NEVER Stash User Changes
If repositories have uncommitted changes, **NEVER use `git stash`**. This risks losing user work and is extremely dangerous. Stashed changes can be difficult to recover, especially untracked files which require `git show stash@{0}^3:path` to extract.

### 2. NEVER Modify Working Tree State Without Permission
Do not run `git checkout`, `git reset`, `git clean`, or any command that modifies uncommitted changes without explicit user permission.

### 3. Commit Changes First (The Correct Approach)
If repos have uncommitted changes and the user wants to proceed with review, **commit the changes first**. Use this exact approach:

```
Now, based on your knowledge of the project, commit all changed files now in a series of logically connected groupings with super detailed commit messages for each and then push. Take your time to do it right. Don't edit the code at all. Don't commit obviously ephemeral files. Use ultrathink.
```

**How to group commits logically:**
- Group by feature/subsystem (e.g., all sync-related files together)
- Group by type of change (e.g., all test files together if they test one feature)
- Keep config/infrastructure changes separate from feature changes
- Use clear commit message format: `feat(scope): description` or `fix(scope): description`

**Skip ephemeral files (do NOT commit):**
- `target/`, `target_*/` - Rust build directories
- `node_modules/`, `web/node_modules/` - npm packages
- `*.pyc`, `__pycache__/` - Python bytecode
- `playwright-report/`, `test-results/` - Test artifacts
- `.coverage`, `htmlcov/` - Coverage reports
- `*.log` files

### 4. Skip Dirty Repos - ru Handles This
The `ru review` command automatically skips repositories with uncommitted changes. This is the correct behavior. Let it skip them rather than trying to force them clean.

## Decision Tree: Handling Dirty Repos

```
Found uncommitted changes in repos?
├── User wants to proceed with ru review?
│   ├── YES → Ask: "Should I commit these changes first?"
│   │   ├── User says YES → Commit with logical groupings, push, then run ru review
│   │   └── User says NO → Let ru skip those repos, review clean repos only
│   └── NO → Stop, let user handle their changes
└── No uncommitted changes → Run ru review normally
```

## How ru review Works

### Discovery Phase
```bash
ru review --dry-run  # See what issues/PRs exist without starting sessions
```

### Plan Mode (Default)
```bash
ru review --plan  # Generate review plans, no mutations
```

### Apply Mode
```bash
ru review --apply  # Execute approved plans from previous --plan run
```

### Key Options
- `--mode=local` - Use local Claude instead of ntm
- `--max-repos=N` - Limit number of repos to review
- `--repos=PATTERN` - Filter repos by pattern (regex)
- `--skip-days=N` - Skip repos reviewed within N days
- `--parallel=N` - Concurrent review sessions (default: 4)
- `--push` - Allow pushing changes (with --apply)

## Built-in Contribution Policy

The `ru review` command automatically includes this contribution policy in its prompts (see `generate_review_prompt()` in the ru script around line 16162):

> We don't allow PRs or outside contributions to this project as a matter of policy. Feel free to submit issues, and even PRs if you want to illustrate a proposed fix, but know I won't merge them directly. Instead, I'll have Claude or Codex review submissions via `gh` and independently decide whether and how to address them.

The key principle: **Independently verify and validate** all user reports. Don't trust submitted fixes blindly - use them as inspiration but verify everything against actual code and documentation.

## Coordinating with Other Agents

When multiple agents are reviewing repos simultaneously:

1. **Use alphabetical ordering** - One agent works forward (A→Z), another works reverse (Z→A)
2. **Check which repos are already in progress** - Look for uncommitted changes or lock files
3. **Skip repos being worked on** - Don't try to review a repo another agent is actively modifying

Example: If another agent is working on `beads_viewer`, start from `xf` and work backwards through `wasm_cmaes`, `ultrasearch`, etc.

## Typical Workflow

1. **Check what needs review**
   ```bash
   ru review --dry-run
   ```

2. **Start plan-mode review**
   ```bash
   ru review --plan --mode=local
   ```

3. **If repos have uncommitted changes:**
   - Let ru skip them automatically
   - OR ask user if they want to commit changes first
   - NEVER stash or discard changes

4. **After review plans are approved:**
   ```bash
   ru review --apply --push
   ```

## Troubleshooting

### "Repository has uncommitted changes"
This is normal and expected. Options:
- Let ru skip those repos (recommended)
- Ask user to commit their changes first
- Wait for other agents to finish their work

### "Failed to prepare worktrees"
This often means some repos were skipped due to uncommitted changes but others succeeded. The review will still run on the successfully prepared repos.

### Checkpoint Issues
If you see "Invalid JSON, refusing to write checkpoint":
```bash
rm -f ~/.local/state/ru/review/review-checkpoint.json
```

## What NOT to Do

- ❌ `git stash` - NEVER stash user changes
- ❌ `git checkout -- .` - NEVER discard changes
- ❌ `git reset --hard` - NEVER reset working tree
- ❌ `git clean -fd` - NEVER clean untracked files
- ❌ Shell loops to iterate repos - ru handles iteration internally
- ❌ Direct `gh` commands for bulk operations - use ru's orchestration

## What TO Do

- ✅ Use `ru review --dry-run` to discover work items
- ✅ Let ru skip repos with uncommitted changes
- ✅ Ask user before modifying their working tree state
- ✅ Commit changes (with user permission) before review if needed
- ✅ Use `--mode=local` if ntm has issues
- ✅ Work in reverse alphabetical order when coordinating with other agents

## Emergency: Recovering from Accidental Stash

If someone accidentally stashed changes, here's how to recover:

### Tracked Files (Easy)
```bash
git stash pop  # Restore tracked changes
```

### Untracked Files (Harder - requires extraction)
Untracked files in a stash are stored in the third parent commit. To recover:

```bash
# List untracked files in stash
git show stash@{0}^3 --name-only

# Extract a specific untracked file
git show stash@{0}^3:path/to/file.rs > path/to/file.rs
```

### If Stash Was Dropped
```bash
# Find dangling stash commits
git fsck --unreachable | grep commit

# For each commit, check if it's your stash
git show <commit-hash>

# Recover if found
git stash apply <commit-hash>
```

## Example: Complete Review Session

```bash
# 1. Discovery - see what needs review
ru review --dry-run

# 2. Check for dirty repos
for repo in /data/projects/*/; do
  (cd "$repo" && [ -n "$(git status --porcelain)" ] && echo "$repo has changes")
done

# 3. If dirty repos exist, commit them first (with user permission)
# Use logical groupings, detailed messages, push each repo

# 4. Run the review
ru review --plan --mode=local

# 5. After plans approved
ru review --apply --push
```

## Review Response Guidelines

When reviewing issues and PRs, remember:
- **Verify independently** - Don't trust submitted code blindly
- **Check actual behavior** - Run tests, verify against docs
- **Use gh commands** to respond on behalf of the user
- **Close issues** that are resolved or invalid
- **Request clarification** if issue is unclear
