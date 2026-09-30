# Changelog

All notable changes to [ru (Repo Updater)](https://github.com/Dicklesworthstone/repo_updater) are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/).

Links point to individual commits on GitHub. Version headers link to comparison views between tags.

---

## [Unreleased](https://github.com/Dicklesworthstone/repo_updater/compare/v1.4.0...HEAD)

### Changed

- **`ru prune --delete` keeps orphans that hold work found nowhere else**: uncommitted changes, untracked files that are not ignored, stashes, commits not on any remote-tracking branch (including a detached HEAD and repos with no remote at all), files marked assume-unchanged or skip-worktree, and linked worktrees. Each kept orphan is named with the reason. A clone git cannot open (corrupted, bare-ish, owned by another user) is kept too: an inspection error never counts as clean. `--archive` still moves such orphans, since archiving loses nothing.
- **`ru prune --archive` and `--delete` keep an orphan whose `origin` is a configured repo** (compared across https, ssh and scp-style URLs, `.git`, ports and letter case). That is a configured repo's clone left at an old path by a layout change or an `as` rename, and prune reports it as `clone of configured repo X ... at an old path`.
- New `ru prune --force` includes both kinds of kept orphan. The dry-run listing and `--json` output show the same notes (`clone_of`, `unsaved_work`, `check_error`).

### Upgrade notes

- `ru prune --archive` / `--delete` now exit 1 when any orphan was kept or failed to archive or delete (before: 0).

---

## [v1.4.0](https://github.com/Dicklesworthstone/repo_updater/compare/v1.3.1...v1.4.0) -- 2026-09-29

Repo lists can now group related repos under a subfolder, and `ru prune` no longer treats a configured repo as an orphan when its path is spelled differently or its list cannot be read. Also fixes the stash-and-pull hint that could pop an unrelated older stash.

### Added

- **Group repos under a subfolder with `in <group>`** (GH #16). A repo line such as `owner/repo in work` puts the clone in a folder between the layout prefix and the repo folder, for every layout: `flat` gives `$PROJECTS_DIR/work/repo`, `owner-repo` gives `$PROJECTS_DIR/owner/work/repo`, `full` gives `$PROJECTS_DIR/host/owner/work/repo`. Groups can be nested (`in a/b`), and `in` and `as` can appear in either order; inside a group, `as` renames only the repo folder. `ru add --group NAME` writes the `in NAME` form and `ru import` keeps groups. A repo listed twice with the same folder name in different groups is cloned once, with a warning, and ru refuses to clone into a folder that sits inside another repo's working tree ([dd210a6](https://github.com/Dicklesworthstone/repo_updater/commit/dd210a694982ffa210a37bfcdf36ca9a7f1f098d)).
- `antigravity` / `agy` agent types map to ntm's `--agy` flags for ru-driven sessions ([e84763f](https://github.com/Dicklesworthstone/repo_updater/commit/e84763fa2ef9919e93af9d25cc90e57c332b9bc7)).

### Fixed

- **The stash-and-pull hint could apply and drop an unrelated older stash** (GH #15). ru counts untracked files as dirty, but `git stash` does not save them, so the suggested `git stash && git pull && git stash pop` stashed nothing and then popped whatever stash was already on top. The conflict report now suggests `git pull --autostash`, which only restores a stash it created ([0d1813d](https://github.com/Dicklesworthstone/repo_updater/commit/0d1813db82574ea03bb320e37b3cb5256d47e456)).
- **`ru prune` could report, archive or delete configured repos as orphans** when the configured path and the clone on disk were spelled differently: an owner folder reached through a symlink, a different letter case on a case-insensitive filesystem (macOS), a different Unicode normalization of the same name, or a `PROJECTS_DIR` with a trailing slash. Prune now compares physical, case-folded paths and then file identity (device and inode), so a clone that is the same folder as a configured path is never an orphan ([dbf455e](https://github.com/Dicklesworthstone/repo_updater/commit/dbf455e954fde6f5291cc198ca876f9e3573081e), [e243a98](https://github.com/Dicklesworthstone/repo_updater/commit/e243a980c312592c9f3b2993aa42e873cb54ef74), [ed42656](https://github.com/Dicklesworthstone/repo_updater/commit/ed4265607f1936beeed1769113861325b5526e98)).
- `ru prune --archive` / `--delete` now refuse (exit 4) when they cannot know the full configured set: a list line that cannot be resolved, an unreadable list file, a `repos.d` directory that is missing or cannot be listed, a dangling symlinked list, or no configured repos at all. Before, every clone such a list names was treated as an orphan. The dry-run listing is unchanged ([dbf455e](https://github.com/Dicklesworthstone/repo_updater/commit/dbf455e954fde6f5291cc198ca876f9e3573081e), [e243a98](https://github.com/Dicklesworthstone/repo_updater/commit/e243a980c312592c9f3b2993aa42e873cb54ef74), [20b37e2](https://github.com/Dicklesworthstone/repo_updater/commit/20b37e22358ea5efe2e164123ef7c4911c50a0e2), [ed42656](https://github.com/Dicklesworthstone/repo_updater/commit/ed4265607f1936beeed1769113861325b5526e98)).
- Prune never acts on a repo that contains configured repos, never on fragments of a folder name that contains a newline, and only scans one level deeper inside group folders rather than across the whole projects directory ([c5af33c](https://github.com/Dicklesworthstone/repo_updater/commit/c5af33cd5e6391b2f7240a0f2a690412f09d55f5), [e243a98](https://github.com/Dicklesworthstone/repo_updater/commit/e243a980c312592c9f3b2993aa42e873cb54ef74)).
- Archiving two same-named orphans in the same second (`owner-a/tool`, `owner-b/tool`) moved the second into the first one's working tree. Each archive now gets its own `_1`, `_2`, ... suffix ([20b37e2](https://github.com/Dicklesworthstone/repo_updater/commit/20b37e22358ea5efe2e164123ef7c4911c50a0e2)).
- Repo specs whose name still contains whitespace after parsing (`owner/repo in a in b`) are rejected instead of resolving to a folder named `repo in a` ([c5af33c](https://github.com/Dicklesworthstone/repo_updater/commit/c5af33cd5e6391b2f7240a0f2a690412f09d55f5)).
- README: removed the Scoop install instructions. ru is a bash script and there is no Scoop manifest; Windows users should use WSL2 with Homebrew or the install script ([b5fe013](https://github.com/Dicklesworthstone/repo_updater/commit/b5fe0131d3bb53fe311f6ebfc54d60fbc2404c73)).

### Upgrade notes

- Scripts that run `ru prune --delete` or `--archive` right after `ru init`, or with a list that fails to parse, now get exit code 4 instead of a prune.
- A list line that an older ru accepted but that is now rejected (for example `owner/repo as x as y`) makes destructive prune modes refuse until the line is fixed; `ru prune` without flags lists it.

---

## [v1.3.1](https://github.com/Dicklesworthstone/repo_updater/compare/v1.2.1...v1.3.1) -- 2026-04-25

Covers v1.3.0 (tagged 2026-04-24, no GitHub Release) and v1.3.1 (2026-04-25), which re-released the same code after a release workflow fix. Changes since v1.2.1 (2026-01-09). Includes new commands, output formats, fork management groundwork, and significant test hardening.

### New Commands

- **`commit-sweep`** -- Groups dirty worktrees into logical commits, useful for multi-agent workflows where many repos accumulate changes simultaneously ([d3dab9e](https://github.com/Dicklesworthstone/repo_updater/commit/d3dab9efe781b75680c59fed24e4fb2e088e9d9e))
- **`robot-docs`** -- Machine-readable CLI documentation emitted as JSON; covers topics: commands, quickstart, examples, exit-codes, formats, schemas ([0ebe82d](https://github.com/Dicklesworthstone/repo_updater/commit/0ebe82d139356dceef4efcf0b4e805bd99f73cbe))
- **`--schema` shortcut** -- Equivalent to `ru robot-docs schemas` for quick schema access ([10f504e](https://github.com/Dicklesworthstone/repo_updater/commit/10f504ef808e1e050366231fa58e7909a61c529b))
- **`ai-sync`** -- AI-assisted sync that analyzes repo state and suggests next steps ([5db62f2](https://github.com/Dicklesworthstone/repo_updater/commit/5db62f25757c23df6d3c7799ec905cff3c046951))
- **`dep-update`** -- Dependency update scanning with package manager auto-detection (npm, cargo, go, pip, etc.) ([5db62f2](https://github.com/Dicklesworthstone/repo_updater/commit/5db62f25757c23df6d3c7799ec905cff3c046951))

### Output & Structured Data

- **TOON output format** -- `--format json|toon` flag for structured output in both JSON and TOON encodings ([22cd33f](https://github.com/Dicklesworthstone/repo_updater/commit/22cd33f706124f51dd91ad31b67f8c102ef17f2b))
- Normalized JSON output envelope across sync/status/list commands for consistent parsing ([40b40b1](https://github.com/Dicklesworthstone/repo_updater/commit/40b40b154cb5ac58c7d8226841ccceed3b30bfd1))
- README: replaced `--format json` references with `--json` ([2595153](https://github.com/Dicklesworthstone/repo_updater/commit/259515368449fc3f7144250a85e12c07a49fd354))

### Fork Management (Groundwork)

- Argument parsing for fork management commands: `fork-status`, `fork-sync`, `fork-clean` ([a7aa3d5](https://github.com/Dicklesworthstone/repo_updater/commit/a7aa3d54b2b55fd6a6e521b0fc964d63aa87fe9c))
- Extended fork command argument parser with additional option handling ([89f89f2](https://github.com/Dicklesworthstone/repo_updater/commit/89f89f27a2ac542422185f0cb84a2c9de4fee317))
- Fork management E2E test scaffolding ([1e0fa15](https://github.com/Dicklesworthstone/repo_updater/commit/1e0fa15f182c5d63bb1a4d6bf9f5fb040489462c))

### Agent & Automation Integration

- Claude Code SKILL.md for automatic capability discovery ([c1e1601](https://github.com/Dicklesworthstone/repo_updater/commit/c1e160154269c0ee20f32f0ab1560dbac742c34f))
- `ru-review` skill: Twitter check requirement, NO MERGING policy enforcement ([6d88bcd](https://github.com/Dicklesworthstone/repo_updater/commit/6d88bcd7d196f3ee7bb0a4d3bc651ac4390779c3), [86c76e8](https://github.com/Dicklesworthstone/repo_updater/commit/86c76e82ddc61c1bbf704cf85a63496bec551879))
- AGENT_FRIENDLINESS_REPORT.md for discoverability assessment ([0cb7d16](https://github.com/Dicklesworthstone/repo_updater/commit/0cb7d16577a254cd356978ff28c5348960bb39cc))
- Agent quickstart documentation in README ([793492a](https://github.com/Dicklesworthstone/repo_updater/commit/793492a79a5879ff034ea563717351c370be8468))
- ACFS notification workflow for installer changes ([e269146](https://github.com/Dicklesworthstone/repo_updater/commit/e269146b954e6c4286546e1da79ef8e7780a23a2))
- ACFS checksum dispatch workflow ([676c9f5](https://github.com/Dicklesworthstone/repo_updater/commit/676c9f59fcf4c0df8dfa564a09cd80c62fffd8ff))

### Testing

- 55 unit tests for previously untested parsing/resolution functions ([ce5ac34](https://github.com/Dicklesworthstone/repo_updater/commit/ce5ac349b7a5e0621c17269537465c99dea2ab8b))
- Unit tests for review policy functions ([201d1c8](https://github.com/Dicklesworthstone/repo_updater/commit/201d1c83c561b38ed095614e9315b5297a780ca3))
- Unit tests for dirty repo detection, test runner detection, package manager detection ([c0e31e9](https://github.com/Dicklesworthstone/repo_updater/commit/c0e31e98a96f87357f1453a6d1da1a4c05ddd1d1), [a3b2ce8](https://github.com/Dicklesworthstone/repo_updater/commit/a3b2ce8d9fa87e631258de6cdfc3c231c3b14412), [da9c3eb](https://github.com/Dicklesworthstone/repo_updater/commit/da9c3eb34a8b35714c3ca9bd4d45239d2f342d59))
- TOON E2E test scripts ([fe93794](https://github.com/Dicklesworthstone/repo_updater/commit/fe937947a03e64a2bf85276031e9b11779ff4c7b), [b67e6f5](https://github.com/Dicklesworthstone/repo_updater/commit/b67e6f5dad554aab55d7abcd19bb82076aaeb724))
- Real-world JSON fixture outputs for TOON testing ([a3d1048](https://github.com/Dicklesworthstone/repo_updater/commit/a3d1048f07120a3fb1e38d618978088711e638f0))
- Lifecycle unit tests, formula/manifest script tests ([3e77a07](https://github.com/Dicklesworthstone/repo_updater/commit/3e77a07caf4cddb57fd3ac6d38bd938c7f1d80ac), [25d24f1](https://github.com/Dicklesworthstone/repo_updater/commit/25d24f183e670e43806e3d32091e6600ac4a7401))
- Migrated all E2E tests to unified `test_e2e_framework.sh` ([b90c2b3](https://github.com/Dicklesworthstone/repo_updater/commit/b90c2b3d253ee50f00fcf83168561d1807921ab0), [fc4f0dc](https://github.com/Dicklesworthstone/repo_updater/commit/fc4f0dc54b8c95a30fb3e0776818c0592d449e91), [a258cf9](https://github.com/Dicklesworthstone/repo_updater/commit/a258cf9be306f86de108efd8c496a64c993efe0b))
- Quality gate debug script and mock inspection helpers ([c9c698e](https://github.com/Dicklesworthstone/repo_updater/commit/c9c698e1185dfb71424849243f93592bc7ffa6df))

### Project & Licensing

- License updated to MIT with OpenAI/Anthropic Rider ([6f2db83](https://github.com/Dicklesworthstone/repo_updater/commit/6f2db83a58bff8ed96da67f0a682749f37d5e877))
- CONTRIBUTING.md and PR template ([9eaae97](https://github.com/Dicklesworthstone/repo_updater/commit/9eaae97d967acbf595d94c92d935b5b6a8b836f3))
- GitHub social preview image ([8ac879f](https://github.com/Dicklesworthstone/repo_updater/commit/8ac879f4f5908d9ca02ee25a715a0448ecd6a7c7))
- Homebrew installation option documented ([bd1d4e5](https://github.com/Dicklesworthstone/repo_updater/commit/bd1d4e5519c5d7d60bde9c4d666cc8e9ca936e1c))
- Improved GitHub Actions workflows with security and performance best practices ([cd4ffa6](https://github.com/Dicklesworthstone/repo_updater/commit/cd4ffa6be4361b82d59ef7f7a94308325112e3a0))

### Bug Fixes

- Three bugs breaking `ru review` discovery summary ([21e2c21](https://github.com/Dicklesworthstone/repo_updater/commit/21e2c21578757f352c4b45e43f51ced78183077f))
- JSON structure in dep-update helpers ([1c66a95](https://github.com/Dicklesworthstone/repo_updater/commit/1c66a95d2128a56df51ffe0a9a755b4e79b965fb))
- Dep-update bugs found in code review ([fa8a243](https://github.com/Dicklesworthstone/repo_updater/commit/fa8a24399eeeeadbd2a3aeaca7645c9071d98c6c))
- Agent-sweep specific options added to global arg parser ([871b0c3](https://github.com/Dicklesworthstone/repo_updater/commit/871b0c366b37536dbf58c10f82451abf25e3c47b))
- Merge conflict in review driver loading ([f0ff0ad](https://github.com/Dicklesworthstone/repo_updater/commit/f0ff0ad2afe706c9e59a06d4cd76d492762b5ef6))
- Wait for full ntm cycle to prevent premature state reads ([15480c5](https://github.com/Dicklesworthstone/repo_updater/commit/15480c5396655c10e8510ce22bbfceee737da970))
- macOS Bash 5 installation in CI -- ncurses dependency, PATH handling, linking ([cf7f027](https://github.com/Dicklesworthstone/repo_updater/commit/cf7f0277fc8ffc19d5bfd1074f30b55fae853322), [c8c07fa](https://github.com/Dicklesworthstone/repo_updater/commit/c8c07fa86635d04c0f75cbd8868280cb2179ec53), [d0a3f9c](https://github.com/Dicklesworthstone/repo_updater/commit/d0a3f9c499446bdb653404727f669c9048fecf88), [e1445fa](https://github.com/Dicklesworthstone/repo_updater/commit/e1445fac452a345818c8b96a1fb95b6564b3c53c))
- EXIT trap collision and redundant cleanup in tests ([5aafc5c](https://github.com/Dicklesworthstone/repo_updater/commit/5aafc5c720d9010a2615edbcf59a654179d3ef8c))
- HOME restored before deleting temp directory in tests ([6b82479](https://github.com/Dicklesworthstone/repo_updater/commit/6b82479680d580a2dc9f6cbeac0ca79729b566fd))
- Quality-gate tests guarded with fresh function source to prevent mock leaking ([6313be9](https://github.com/Dicklesworthstone/repo_updater/commit/6313be9510e6881a5ebc68da5905c5bfe6689723), [b990404](https://github.com/Dicklesworthstone/repo_updater/commit/b99040428961fdbc234bf26a60c7efd6dacdc121))
- Fork management E2E test assertions and edge cases ([b90ad10](https://github.com/Dicklesworthstone/repo_updater/commit/b90ad10b1798ddaa813fc0a63abbe09914b14915))
- Recovered files deleted by bd daemon sync ([2fcdca5](https://github.com/Dicklesworthstone/repo_updater/commit/2fcdca584c1d2b9d1c5f91a09e4ddb5f593ee7a3))

---

## [v1.2.1](https://github.com/Dicklesworthstone/repo_updater/compare/v1.2.0...v1.2.1) -- 2026-01-09

Stability release focused on review orchestration reliability and security hardening. Published as [GitHub Release](https://github.com/Dicklesworthstone/repo_updater/releases/tag/v1.2.1) (Latest). All 83 test files passing.

### Review Orchestration

- Session queue management for coordinating multiple review sessions ([14d2f1e](https://github.com/Dicklesworthstone/repo_updater/commit/14d2f1e9067a4f1ea9bb92b64ffe913a97d2b9cd))
- Unified session log discovery and multi-day rate limit scanning ([ffa3c84](https://github.com/Dicklesworthstone/repo_updater/commit/ffa3c8404dd850cafb89f128fa28d7f1b6879159))
- `start_next_queued_session` with work items support ([832da3b](https://github.com/Dicklesworthstone/repo_updater/commit/832da3b3c9dea21d417986b42bc8b79775f42a64))
- Session monitor implementation for tracking active review sessions ([e33a954](https://github.com/Dicklesworthstone/repo_updater/commit/e33a9543ff327773f6d85cbe68068bcf767803e3))
- Output variable support for `apply_state_hysteresis` ([5dfe0d5](https://github.com/Dicklesworthstone/repo_updater/commit/5dfe0d5fba8bcf38cd98760fa072224d90117a6e))
- Review prompt updated to full verbatim policy ([94cc1b7](https://github.com/Dicklesworthstone/repo_updater/commit/94cc1b7508ede77b30782c0fa6b89b21216bfde3))
- Proper state file for session-repo mapping ([5cba804](https://github.com/Dicklesworthstone/repo_updater/commit/5cba80442c4cb7768b1c13d88bb56eaf151d422e))

### Security

- Reject newline-separated commands in validation to prevent injection ([032c4ee](https://github.com/Dicklesworthstone/repo_updater/commit/032c4ee18b41f9ef49fa5863a71a6d63bc267d29))
- Pre-escape newlines for valid JSON output ([5d33c7b](https://github.com/Dicklesworthstone/repo_updater/commit/5d33c7bac513115bf20ff970fc747f6aa528e4bc))

### Orchestration Bug Fixes

- `self-update` EXIT trap: expand `temp_dir` immediately -- was empty due to single quotes around the local variable ([9640be4](https://github.com/Dicklesworthstone/repo_updater/commit/9640be465c7744c18d328762b68648165f986e2e))
- Mark repo as error when driver load fails instead of leaving inconsistent state ([a5f062b](https://github.com/Dicklesworthstone/repo_updater/commit/a5f062bd8431bfa6b568c9bcd577f694a2ed34b5))
- Properly pass output to `detect_wait_reason` (argument order fix) ([18584ec](https://github.com/Dicklesworthstone/repo_updater/commit/18584ec6875af6cdfab8e54999c638e54b215567))
- Skip missing worktrees and add velocity division guard ([7aee933](https://github.com/Dicklesworthstone/repo_updater/commit/7aee9335b935c83482c88dca440c08e8b92b63fb))
- Count questions only once per session (fixed double-counting) ([95dcc22](https://github.com/Dicklesworthstone/repo_updater/commit/95dcc22eb962224d3ca3fecf70a33e2001742fb7))
- Session state tracking in orchestration loop ([bd7c832](https://github.com/Dicklesworthstone/repo_updater/commit/bd7c832398ec919d0ae60f6736541e0f287804f1))
- Governor: pass active session count to `can_start_new_session` ([ad0d8e7](https://github.com/Dicklesworthstone/repo_updater/commit/ad0d8e74c90e503334ba763bfb440071cc09b90b))
- `start_next_queued_session` signature fix in monitor ([1f11652](https://github.com/Dicklesworthstone/repo_updater/commit/1f11652eadc5b4f5e0da7e8a04ebabdd6b783aea))
- Worktree branch pin handling improvements ([7109a6d](https://github.com/Dicklesworthstone/repo_updater/commit/7109a6d518a5f573a65b2eca123120618259acce))
- Portable date comparison in `is_recently_reviewed` ([3697b03](https://github.com/Dicklesworthstone/repo_updater/commit/3697b03c460f1bb65ed86a064448344173d4eaf5))
- macOS `timeout` command compatibility ([39beb8d](https://github.com/Dicklesworthstone/repo_updater/commit/39beb8d84d5b5b2f3fa7b3add4c7a9fb169a0eaa))
- Replace heredoc with printf for test compatibility ([2b700d4](https://github.com/Dicklesworthstone/repo_updater/commit/2b700d40889b69631ceb5ba60ff822fbec9f54a6))

### Testing

- Comprehensive test suites for review orchestration -- unit and E2E ([f036abd](https://github.com/Dicklesworthstone/repo_updater/commit/f036abd77ceefe9b49e43f85f10fbd20b5528343), [7e0e953](https://github.com/Dicklesworthstone/repo_updater/commit/7e0e95310cc82f90675dabf1818b23fdf708745a))
- Completion phase tests ([764e9e0](https://github.com/Dicklesworthstone/repo_updater/commit/764e9e0a470614c50355f552cc637a15b2f179ee))
- Apply phase E2E tests ([31298c9](https://github.com/Dicklesworthstone/repo_updater/commit/31298c98c5b58f7b139732d90e7ee8a9af3650b4))
- Question TUI tests ([591f162](https://github.com/Dicklesworthstone/repo_updater/commit/591f162d1bc4a0fa50c9b6a5ce6c07f03725cf51))
- Session monitor tests ([7b7c33e](https://github.com/Dicklesworthstone/repo_updater/commit/7b7c33e620f6bcc69e25e9bb19071a090b7356f7))
- Session driver E2E tests ([c472906](https://github.com/Dicklesworthstone/repo_updater/commit/c47290671c7f56ef7e7486205a792fac4d3b0749))
- Checkpoint/resume unit and E2E tests ([58547db](https://github.com/Dicklesworthstone/repo_updater/commit/58547dbfd15cddb066b9920c261aa26e4dd0ee11))
- Integration tests and session log improvements ([90ae04a](https://github.com/Dicklesworthstone/repo_updater/commit/90ae04aafde4559d5adbf247cbe47c25f6576fd4))

---

## [v1.2.0](https://github.com/Dicklesworthstone/repo_updater/compare/v1.1.0...v1.2.0) -- 2026-01-08

Major release introducing Agent Sweep for automated multi-repository AI code review, the git harness for deterministic offline testing, and comprehensive Bash 4.0 compatibility fixes. ~17,700 lines of pure Bash across ~198 commits. Published as [GitHub Release (Draft)](https://github.com/Dicklesworthstone/repo_updater/releases/tag/v1.2.0).

### Agent Sweep -- AI-Powered Multi-Repository Review

The headline feature: orchestrate AI-assisted code review across many repositories simultaneously.

- **`agent-sweep` command** -- parallel AI code review with work-stealing queue ([6164c57](https://github.com/Dicklesworthstone/repo_updater/commit/6164c5768443e1ab4aeeb89ad05944d985f3a231))
- NTM driver and utility functions for tmux session management ([df1b0fe](https://github.com/Dicklesworthstone/repo_updater/commit/df1b0fe358da968db21973f7bfb90f29117683ab))
- Per-repository configuration loading via `.ru-review.yml` ([8d8dbc5](https://github.com/Dicklesworthstone/repo_updater/commit/8d8dbc56756cb4a1ad25895c3c78ff1c8a58ccca))
- Parallel preflight checks and secret scanning ([8ebd776](https://github.com/Dicklesworthstone/repo_updater/commit/8ebd77601ce4515eab8c6e5babb757c1da706ce8))
- Plan extraction from agent pane output ([96111c9](https://github.com/Dicklesworthstone/repo_updater/commit/96111c9a2844ea698008b2d04feb4e9bb6c3adf9))
- Phase prompts with structured output markers ([fe0c0bb](https://github.com/Dicklesworthstone/repo_updater/commit/fe0c0bb18859ae851df3f5e6fa78aeea412a7b42))
- Global rate limit backoff coordination across parallel workers ([bbcf212](https://github.com/Dicklesworthstone/repo_updater/commit/bbcf212377d5b3f1a9f8a1a050ff439aedca1f36))
- Release workflow detection and execution ([0a08f1c](https://github.com/Dicklesworthstone/repo_updater/commit/0a08f1c15133b096fe12aad81e48e7a568fc5db5))
- Release plan validation and execution ([807e72a](https://github.com/Dicklesworthstone/repo_updater/commit/807e72a6b609de29d41b5d00d97e5f9e096ba657))
- Commit plan validation and execution with quality gates ([e31a6ea](https://github.com/Dicklesworthstone/repo_updater/commit/e31a6eabdb3ab4b584a974ccac1d2581df95d635))
- File size/binary validation to prevent accidental large commits ([cc10475](https://github.com/Dicklesworthstone/repo_updater/commit/cc10475e6cf77b356f94c95184880158bf78569c))
- Artifact capture functions ([21ce3d2](https://github.com/Dicklesworthstone/repo_updater/commit/21ce3d248363988921a2c10617e75802b919de2b))
- User-friendly error messages ([70085c3](https://github.com/Dicklesworthstone/repo_updater/commit/70085c36c19f4ea627bbc826bc04f19706d23383))
- Verbose and debug logging modes ([cf1873b](https://github.com/Dicklesworthstone/repo_updater/commit/cf1873b5c8277af4bd4c90732051a7854f9f962e))
- Real-time progress display during sweep ([4d8f5bb](https://github.com/Dicklesworthstone/repo_updater/commit/4d8f5bb702dae6bc3227ab6eae641e51e6acb1db))
- Enhanced summary with full spec display ([dacfba6](https://github.com/Dicklesworthstone/repo_updater/commit/dacfba6e3e4bcda2f57098f0e5c719db0d2ee834))
- State recovery with `--resume` for interrupted sweeps ([590a7c3](https://github.com/Dicklesworthstone/repo_updater/commit/590a7c39d8ebeecdd98c7d42a7ec62f13124f47d))
- ntm integration in installer for agent-sweep support ([c42973c](https://github.com/Dicklesworthstone/repo_updater/commit/c42973c19b79fc69b7d9be7b8f7136d9defd6d0a))

### Quality Gates

Validation layer for agent-generated commit plans:

- File size limits, binary file detection, file denylist, test requirements ([e31a6ea](https://github.com/Dicklesworthstone/repo_updater/commit/e31a6eabdb3ab4b584a974ccac1d2581df95d635))
- Nested directory pattern matching in denylist ([2a2f146](https://github.com/Dicklesworthstone/repo_updater/commit/2a2f1469df22b03570e36f579b972c3d9b5626b8))
- Secret scan: skip detect-secrets gracefully when jq is missing ([b83617f](https://github.com/Dicklesworthstone/repo_updater/commit/b83617f58f233185b30e9874b16628ad9e835b99))

### Testing Infrastructure

- **Git harness library** -- create temporary git repos with precisely controlled states (ahead, behind, diverged, dirty, shallow, detached) for offline deterministic testing ([f3ed8dc](https://github.com/Dicklesworthstone/repo_updater/commit/f3ed8dc23b7e8370cce99acf239dd00f7b4a2d2e))
- Comprehensive testing guide (TESTING.md) ([4ed5826](https://github.com/Dicklesworthstone/repo_updater/commit/4ed582670238f9985f291dac02fef3205ab93002))
- Parallel mode tests ([944e65a](https://github.com/Dicklesworthstone/repo_updater/commit/944e65aae095a32d902a81dde4762c381ca46faf))
- E2E agent-sweep tests ([91249ae](https://github.com/Dicklesworthstone/repo_updater/commit/91249ae7f5576fa317289b55404f8522ce934aa6))
- State management tests ([e0de8a1](https://github.com/Dicklesworthstone/repo_updater/commit/e0de8a16b53ec42a4663109b7ca3e272336550d9))
- NTM driver unit tests ([4c0d005](https://github.com/Dicklesworthstone/repo_updater/commit/4c0d005ba0367156195075310a2d0a4091eb3262))
- Security guardrail tests ([4db8f7e](https://github.com/Dicklesworthstone/repo_updater/commit/4db8f7e814d6d3eb80c17e40b1706d83407da5f7))
- Plan validation tests ([7433e06](https://github.com/Dicklesworthstone/repo_updater/commit/7433e061a6ad2cebf9d2e1f387bf7bf37b3ac99a))
- Unit tests for parse_*/extract_* functions ([c7d51dd](https://github.com/Dicklesworthstone/repo_updater/commit/c7d51dd0252ff177b5594dff4e3eb1d5e69b05b0))
- Consistent `get_exit_code()` usage across all test files ([0425685](https://github.com/Dicklesworthstone/repo_updater/commit/0425685ad2956d178ea1e795ddcf5f80828ed89c))
- Consistent assertion API in git harness tests ([2e36cbb](https://github.com/Dicklesworthstone/repo_updater/commit/2e36cbb4be995dacf32aeba00b9f7cc32c4ed65a))
- 70+ test files total (36 unit, 20 E2E, plus integration), ~700+ assertions

### Bash Compatibility

- **Bash 4.0-4.3 safe empty array pattern** -- `${arr[@]+...}` prevents unbound variable errors ([8e25313](https://github.com/Dicklesworthstone/repo_updater/commit/8e2531398b3a7401b07d6a5efcbd55999d39bef5))
- Prevented glob expansion in word-split iterations ([f1fec49](https://github.com/Dicklesworthstone/repo_updater/commit/f1fec49a44f34ac28233fe41cf09b7ade5f7cfe3))
- Git harness: Bash 4.0 compat and git plumbing for shallow check ([d6a340c](https://github.com/Dicklesworthstone/repo_updater/commit/d6a340ce1b8fabafa846924c8817b7fdcf23f569))
- Boolean exit codes in test scripts ([674c397](https://github.com/Dicklesworthstone/repo_updater/commit/674c397a43ed10085852d32da74265c2a84fa048))
- Empty array safety in `save_agent_sweep_state` ([f2d426e](https://github.com/Dicklesworthstone/repo_updater/commit/f2d426ea4a16e50202e527a3f32527a1fde12447))
- Portable `drop_last_lines` for macOS compatibility ([5872086](https://github.com/Dicklesworthstone/repo_updater/commit/5872086e1726c60c65c4740ab8f19bb8789dd55e))

### Sync & Configuration Fixes

- `no_upstream` status handling and `write_json_atomic` error propagation ([f6e91f1](https://github.com/Dicklesworthstone/repo_updater/commit/f6e91f1bbc7905f44e17805dac1a2c3fd9b35348), [613a69e](https://github.com/Dicklesworthstone/repo_updater/commit/613a69eb9e146e98dc7c4cf874f7489b6e4fd4b0))
- Regex safety and lock timeout warnings in sync ([0b26864](https://github.com/Dicklesworthstone/repo_updater/commit/0b26864855d1f8a4d6ed1be400f8262bd55b89b6))
- Default projects directory aligned with README ([15cb25c](https://github.com/Dicklesworthstone/repo_updater/commit/15cb25c609350af34664cfbcc3e97500194420ce))
- `repo_spec_to_path` respects resolved `PROJECTS_DIR` config ([c7cc90c](https://github.com/Dicklesworthstone/repo_updater/commit/c7cc90cb701fe25a582033795487fe3db5419342))
- `resolve_repo_spec` respects `RU_CONFIG_DIR` ([ed21ed8](https://github.com/Dicklesworthstone/repo_updater/commit/ed21ed8e3418f16f9c28993d5e2386165343dc7a))
- Installer: correct regex escaping in checksum pattern ([41730c1](https://github.com/Dicklesworthstone/repo_updater/commit/41730c1e0f189404159f43e69d32e55cf960c66f))

### Other Fixes

- Circular nameref and test race condition in parallel mode ([3df3c13](https://github.com/Dicklesworthstone/repo_updater/commit/3df3c13a4e22291d44b88f14b6b7daae530559f6))
- Numeric `-1` for unknown AHEAD/BEHIND values ([ddd4ed1](https://github.com/Dicklesworthstone/repo_updater/commit/ddd4ed1ad242e6e03a1d77890b72414c374812f2))
- `json_get_field` sed fallback for arrays and booleans ([5f26878](https://github.com/Dicklesworthstone/repo_updater/commit/5f26878178b7eedbb870e4adf03175c230c518f7))
- Agent-sweep: repo path validation and resume with-release flag ([76480ec](https://github.com/Dicklesworthstone/repo_updater/commit/76480ec7ebed80746365605a7d2a628f3b9fc524))
- Lock directories cleaned up in parallel sync and global cleanup ([4f3c625](https://github.com/Dicklesworthstone/repo_updater/commit/4f3c62569b4281dfc7381caf04caef3c87482e21))
- Multiple UX issues found during real-world testing ([3ad9bf3](https://github.com/Dicklesworthstone/repo_updater/commit/3ad9bf313fc7318713211f107dfd11597549f9cd))
- Empty array in `discover_tests` ([8b7878e](https://github.com/Dicklesworthstone/repo_updater/commit/8b7878e267ef9cc5e5f0c8825b711745faaf7780))

### Documentation

- Architecture and testing sections expanded in README ([537b957](https://github.com/Dicklesworthstone/repo_updater/commit/537b95741aeeb0586a800b004ab72553a68caf84), [f68b22a](https://github.com/Dicklesworthstone/repo_updater/commit/f68b22a1cda9357a9aac343a84a9fb0b3bb41e67))
- Documented previously undocumented features ([fc31bab](https://github.com/Dicklesworthstone/repo_updater/commit/fc31babf2e10a509702ce99e9af5b16c7f764917))
- AGENTS.md: workspace hygiene rules for worktrees ([1c6edfa](https://github.com/Dicklesworthstone/repo_updater/commit/1c6edfa2837b6e72866e0fd4fdad00ddfd8daae9))
- Agent-sweep command documentation in README ([a4572e4](https://github.com/Dicklesworthstone/repo_updater/commit/a4572e44be64bf0630ac1d71748022582fb71ea1))
- Testing tiers and logging documentation ([f29847d](https://github.com/Dicklesworthstone/repo_updater/commit/f29847d170fa6bbe67ffcb6d419db2ecfa3dcdd2))

---

## [v1.1.0](https://github.com/Dicklesworthstone/repo_updater/compare/v1.0.1...v1.1.0) -- 2026-01-05

Comprehensive testing and documentation release. Introduces 58 test files, portable directory-based locking, Bash 4.0 compatibility via nameref removal, and extensive README expansion. ~120 commits. [GitHub Release](https://github.com/Dicklesworthstone/repo_updater/releases/tag/v1.1.0).

### Testing Infrastructure

- **E2E test framework** with comprehensive logging and test isolation ([792cbcc](https://github.com/Dicklesworthstone/repo_updater/commit/792cbcc29f1cba698084693c46f4e6d4f4c6df54))
- **Test coverage tracking and reporting** system ([a66d867](https://github.com/Dicklesworthstone/repo_updater/commit/a66d867cd1812ccf13bc15c7b11f80b0f4a60f55))
- **Test log viewer/filter tool** for debugging ([327d2f7](https://github.com/Dicklesworthstone/repo_updater/commit/327d2f7cd5186f67e044dc2c7033150c0dd716b5))
- JSON logging for test framework ([daee60b](https://github.com/Dicklesworthstone/repo_updater/commit/daee60b8efab0025c22b5cd33a3815767cf5f9d1))
- Parallel test execution with job limiting ([9edf815](https://github.com/Dicklesworthstone/repo_updater/commit/9edf81552f5feee7b3378009576f04705289aa6f))
- Enhanced test isolation functions ([e6159d2](https://github.com/Dicklesworthstone/repo_updater/commit/e6159d25dc8df7e63ae164b7798aba476bd96bb3))
- Standardized assert function signatures (message-first pattern) ([851ad88](https://github.com/Dicklesworthstone/repo_updater/commit/851ad884b8d4247ab4252fbe9d9a2c4dee7001ec))
- Auto-load directory lock helpers in test framework ([fe679cc](https://github.com/Dicklesworthstone/repo_updater/commit/fe679cc28f5a20a8ea06f29173b270d5c3cf1958))

### E2E Tests Added

- Review workflows ([52a799d](https://github.com/Dicklesworthstone/repo_updater/commit/52a799d089d7e2b96f71cf3cbb1c2179a78babaf))
- Sync workflows ([be77c77](https://github.com/Dicklesworthstone/repo_updater/commit/be77c777c9917a223abd923e8b7f62a6e2a77b6d))
- Clone drivers ([a5ea194](https://github.com/Dicklesworthstone/repo_updater/commit/a5ea194a85bceb5e7d66f2397b1b47dfad27a93b))
- Worktree management ([27f28c1](https://github.com/Dicklesworthstone/repo_updater/commit/27f28c1dcb39fccca741db2ecefa4b7b56d7d74d))
- Configuration and environment ([d39216e](https://github.com/Dicklesworthstone/repo_updater/commit/d39216e1d891f0db0be6ca271cae3f768fb31755))
- Error handling and recovery ([3aff887](https://github.com/Dicklesworthstone/repo_updater/commit/3aff8870ad0e41567aaa03ff38c0cc52d5b5a316))

### Unit Tests Added

- Driver interface layer ([90eb5da](https://github.com/Dicklesworthstone/repo_updater/commit/90eb5da3b81a057db5897e0eaf6922dfe5035110))
- Local session driver ([627c877](https://github.com/Dicklesworthstone/repo_updater/commit/627c8777ba870d1b79f6832c25eaaacc28d0548f))
- Rate limiting ([6398ba2](https://github.com/Dicklesworthstone/repo_updater/commit/6398ba2360bbb6ddbce069b01573ca7f343c7cf2))
- Metrics and analytics ([7352ae6](https://github.com/Dicklesworthstone/repo_updater/commit/7352ae62986ce3f7be13f0c54374744d7a62a32e))
- Quality gates ([6e86fba](https://github.com/Dicklesworthstone/repo_updater/commit/6e86fbac1e94ef10d5a10119c4bc4700ed8ff557))
- GitHub Actions execution ([437da26](https://github.com/Dicklesworthstone/repo_updater/commit/437da266674970df90e21b2b5f0c1518a104e337))
- Worktree operations ([887e2de](https://github.com/Dicklesworthstone/repo_updater/commit/887e2de2d32723b555ecf0b8198c0a19a6b3276e))
- Review state management ([6674688](https://github.com/Dicklesworthstone/repo_updater/commit/667468887de493228cf9bf414a3c321148f16be7))
- Locking ([2d8cfec](https://github.com/Dicklesworthstone/repo_updater/commit/2d8cfec96b9b0329088779fbea184200ba775eeb))

### Compatibility & Portability

- **Bash 4.0-4.2 compatibility** -- removed all nameref usage ([1ec7fd2](https://github.com/Dicklesworthstone/repo_updater/commit/1ec7fd28bdffec4ee42c5bbd1b5518fd282c34a7), [95101b1](https://github.com/Dicklesworthstone/repo_updater/commit/95101b1fb92ae31491193a356f080dadd76c9683))
- Bash 4.0-4.2 compatibility for parallel execution ([2226a28](https://github.com/Dicklesworthstone/repo_updater/commit/2226a2859359fb56dc4a621dbdb079316cb7277b))
- **Flock auto-install** -- prompt/auto-install flock when required ([b515377](https://github.com/Dicklesworthstone/repo_updater/commit/b5153772ba71a30d9585e290e1d1779791aa0afa))

### Installer Hardening

- Self-refresh for piped stdin ([f0c6a93](https://github.com/Dicklesworthstone/repo_updater/commit/f0c6a9318adc00f06665353177431b4c473569c9))
- Removed flock dependency, avoid GitHub API for version detection ([1d7521b](https://github.com/Dicklesworthstone/repo_updater/commit/1d7521b737ffe438c9ea75c67c728a63a02a10f7))
- Self-refresh + lock cleanup ([c4ce425](https://github.com/Dicklesworthstone/repo_updater/commit/c4ce425db5d8b417c526b31751debd27a733a7b2))
- Robust latest release detection ([6cac5c2](https://github.com/Dicklesworthstone/repo_updater/commit/6cac5c241b92a37dc1b31ffea61f3780c0469da9))
- Harden installer/self-update + flock diagnostics ([88317de](https://github.com/Dicklesworthstone/repo_updater/commit/88317de264042c12bdbc27904ea22eff3c5fbc43))
- Stream separation + robustness improvements ([96be9a1](https://github.com/Dicklesworthstone/repo_updater/commit/96be9a1fa272bbad04c69236971a9517feff4959))
- Printf for safer output + redirect-based version detection ([1ec7e4a](https://github.com/Dicklesworthstone/repo_updater/commit/1ec7e4aad0a3ee85ff4a2545fd4bf7586be974e9))

### Bug Fixes

- Variable shadowing in `resolve_repo_spec`, `parse_stream_json_event`, `get_worktree_path` ([f4508ff](https://github.com/Dicklesworthstone/repo_updater/commit/f4508ff822cc8269035868312adc930b2e48cd20), [8db0025](https://github.com/Dicklesworthstone/repo_updater/commit/8db0025434a426ab11fd4b5f06bf6ea5e390224b), [8864169](https://github.com/Dicklesworthstone/repo_updater/commit/88641694f194613c45d087ff4f58e0c0d7d47a85))
- Worktrees: lock mapping + normalize repo IDs ([c875870](https://github.com/Dicklesworthstone/repo_updater/commit/c875870da7dd329b1d9b2f85efe61c11ff6ceb33))
- Prune: delete confirmation prompt no longer hangs ([4cdf885](https://github.com/Dicklesworthstone/repo_updater/commit/4cdf88563aeddf8ff33355799a9581a3ffdf40ec))
- Review worktree cleanup path safety hardened ([8047efd](https://github.com/Dicklesworthstone/repo_updater/commit/8047efd2f11f3b18f09813d2811ce6f96c976dba))
- Tests: directory-based locking and return code fixes ([959112f](https://github.com/Dicklesworthstone/repo_updater/commit/959112fcc3854df5ec90e90ea6a066209182b875))

### Documentation

- Expanded README with advanced review features, import, locking, testing docs ([180342a](https://github.com/Dicklesworthstone/repo_updater/commit/180342ade4b06444e1b7e246556df69cd5e852b8), [0660aa8](https://github.com/Dicklesworthstone/repo_updater/commit/0660aa8b31b6440eff85417c114dd9c0a87e743b))

---

## [v1.0.1](https://github.com/Dicklesworthstone/repo_updater/compare/12ba14ce09a1...v1.0.1) -- 2026-01-05

First official release. Pure Bash CLI for synchronizing GitHub repositories with automation-grade exit codes, JSON output, and a gum-powered terminal UI. ~295 commits from initial commit to first tag over two days of intensive development. [GitHub Release](https://github.com/Dicklesworthstone/repo_updater/releases/tag/v1.0.1).

### Repository Synchronization

- **`sync`** -- Clone missing repos and pull updates with conflict detection; supports `--autostash`, `--dry-run` ([ec2cef5](https://github.com/Dicklesworthstone/repo_updater/commit/ec2cef5943b26ac0bd2b335b1fce0e9e4590b226))
- **Parallel sync** with worker pool (`--parallel N`, `-jN`) for concurrent processing ([72752d2](https://github.com/Dicklesworthstone/repo_updater/commit/72752d242b2d2b80cbde39b61b468b8302d89544))
- **Resume support** for interrupted syncs (`--resume`) ([b14cdac](https://github.com/Dicklesworthstone/repo_updater/commit/b14cdacfba267a3702f18e6a630896188cd0a01f))
- Branch pinning in ad-hoc sync ([29e1ce7](https://github.com/Dicklesworthstone/repo_updater/commit/29e1ce7fe17842fca7616c6c2b321156d0297004))
- Network timeout handling ([20441c1](https://github.com/Dicklesworthstone/repo_updater/commit/20441c11fe41a2e1a5fd5a9210600ed672650f24))

### Repository Management

- **`status`** -- Show repository status (read-only) with JSON output ([8dc6e0e](https://github.com/Dicklesworthstone/repo_updater/commit/8dc6e0ef4b957fe156ead0565c27b435625f08f8))
- **`init`** -- Initialize configuration directory with `--example` flag ([69bce88](https://github.com/Dicklesworthstone/repo_updater/commit/69bce88ba95850b2886f4a0719f8a5491ab6b22a))
- **`add` / `remove`** -- Manage repository list with `--private` and `--from-cwd` options ([65ae2b4](https://github.com/Dicklesworthstone/repo_updater/commit/65ae2b456edc1d987699ae6841e8c86844cae24d), [98fa533](https://github.com/Dicklesworthstone/repo_updater/commit/98fa533f72bbcf0bac0be36ca3f5ae2703825a0a))
- **`list`** -- Show configured repositories with `--paths` output ([41ff89e](https://github.com/Dicklesworthstone/repo_updater/commit/41ff89eddb011a00942704b6a150a09ac5dddbb9))
- **`import`** -- Bulk repository import from file with auto visibility detection and deduplication ([24db5b9](https://github.com/Dicklesworthstone/repo_updater/commit/24db5b904c3175452ef568727903226c434d82c3), [c1998ac](https://github.com/Dicklesworthstone/repo_updater/commit/c1998ace02280e1345345dc5e3e275d904292cd3))
- **`prune`** -- Find and manage orphan repositories ([81106eb](https://github.com/Dicklesworthstone/repo_updater/commit/81106eba98f8c2ffc28e0bdcfcbeac1408121ad8))
- **`config`** -- Show/set configuration ([3b7fd5b](https://github.com/Dicklesworthstone/repo_updater/commit/3b7fd5b1f77ab0d56318f4a2448386ce730c8ff5))

### Diagnostics & Maintenance

- **`doctor`** -- System diagnostics with review-specific health checks ([926919f](https://github.com/Dicklesworthstone/repo_updater/commit/926919ff5ba159a29e670f5e32093239882a68f4), [344ba67](https://github.com/Dicklesworthstone/repo_updater/commit/344ba67afd43c3bee4640b88e35a478cdbbe6dcd))
- **`self-update`** -- Update ru to latest version with checksum verification ([ddaf9df](https://github.com/Dicklesworthstone/repo_updater/commit/ddaf9df8d829383b0d838dde3e81c8b5c754bb88))
- Stylish quick menu when `ru` invoked with no arguments ([a629dc2](https://github.com/Dicklesworthstone/repo_updater/commit/a629dc2e4e1f332cd0340beb368e54e25d4a0ebc))

### AI-Assisted Review System

- **`review`** -- AI-assisted review of issues and PRs with priority scoring ([def74c7](https://github.com/Dicklesworthstone/repo_updater/commit/def74c7cf8a96cc6b630177b864579e825b4ce1d))
- GraphQL batched repository discovery for 50x API efficiency ([2760fe8](https://github.com/Dicklesworthstone/repo_updater/commit/2760fe879bb42451b42d9a1281c4b763ef232adb))
- Wait reason detection with three categories ([b2c8ed2](https://github.com/Dicklesworthstone/repo_updater/commit/b2c8ed27e9bb19a6d65a8675b7a6edf395c28e9f))
- ntm driver using robot mode API for tmux session management ([8540eba](https://github.com/Dicklesworthstone/repo_updater/commit/8540eba169678c8126838d1a8a13482fca08263f))
- Unified driver interface and local driver ([a5efcdb](https://github.com/Dicklesworthstone/repo_updater/commit/a5efcdb0af021c41363d8d8aece8386ea2590d6f))
- Git worktree preparation for isolated reviews ([1166009](https://github.com/Dicklesworthstone/repo_updater/commit/1166009b1cf00b18a3c9c9f488f4f43088b5098f))
- Command validation and blocking for agent sessions ([3b939ac](https://github.com/Dicklesworthstone/repo_updater/commit/3b939ac221b61641ab9862641ebfa8637d32e37c))
- Discovery summary display with priority breakdown ([371b422](https://github.com/Dicklesworthstone/repo_updater/commit/371b422f55dfc523da203e4b33825e1871ffdb96))
- Quality gates framework ([bf7f3cb](https://github.com/Dicklesworthstone/repo_updater/commit/bf7f3cbc3b49d1cccda6801f75188049497fb458))
- Per-repo review policy configuration ([0e0e1ec](https://github.com/Dicklesworthstone/repo_updater/commit/0e0e1ec981337ed21acf49a5ba24143a35e62c49))
- Non-interactive mode for CI/automation ([6696e56](https://github.com/Dicklesworthstone/repo_updater/commit/6696e56da611d090909a615959d4cf502ad3000d))
- GitHub Actions execution from review plan ([8f9c68d](https://github.com/Dicklesworthstone/repo_updater/commit/8f9c68d8bff308fd3ac7de23505cf534cf001e91))
- Review `--status` for lock/checkpoint inspection ([cb5e9dd](https://github.com/Dicklesworthstone/repo_updater/commit/cb5e9ddb4a41e7aa6046d31c53767b41f6315e5f))
- Rate-limit governor for adaptive concurrency ([3a3b289](https://github.com/Dicklesworthstone/repo_updater/commit/3a3b2893cf4edb124c730c4099e307f528eb2084))
- Exponential backoff retry helper ([17b6945](https://github.com/Dicklesworthstone/repo_updater/commit/17b6945724ebe995c93b47f1a944753ba19fc0c8))

### Output & Automation

- **Meaningful exit codes**: 0=ok, 1=partial, 2=conflicts, 3=system, 4=bad args, 5=interrupted ([c1cd4f5](https://github.com/Dicklesworthstone/repo_updater/commit/c1cd4f52713f92de322d8c736024b0c9c9827b53))
- **JSON output** (`--json`) for structured scripting integration ([39707be](https://github.com/Dicklesworthstone/repo_updater/commit/39707beb298702090bdd2b277ade94aa3967868f))
- NDJSON logging with path field for conflict help ([ea11057](https://github.com/Dicklesworthstone/repo_updater/commit/ea11057660e9e64c9e037d58baec2eab8371127d))
- Gum-powered terminal UI with ANSI fallbacks ([8a39add](https://github.com/Dicklesworthstone/repo_updater/commit/8a39add7229e3d7aab77354f51b751f279e356bf))
- Reporting and summary functions ([39707be](https://github.com/Dicklesworthstone/repo_updater/commit/39707beb298702090bdd2b277ade94aa3967868f))

### Infrastructure

- Installation script with SHA256 checksum verification ([4197166](https://github.com/Dicklesworthstone/repo_updater/commit/41971661ecee858404705edaea69c038f0d44d71))
- Centralized repo spec parsing with `resolve_repo_spec` ([191fc5a](https://github.com/Dicklesworthstone/repo_updater/commit/191fc5a9fbacc5d8f06a31b7ac9bd49dbc33c176))
- SSH URL parsing in `parse_repo_spec` ([41ff89e](https://github.com/Dicklesworthstone/repo_updater/commit/41ff89eddb011a00942704b6a150a09ac5dddbb9))
- Security: path traversal protection and JSON escaping ([8273933](https://github.com/Dicklesworthstone/repo_updater/commit/8273933995c8d95350e898806ba3be6b49cda380))
- TAP output format for test framework ([afa21c0](https://github.com/Dicklesworthstone/repo_updater/commit/afa21c0aab00b34638c5cc7593964f25c0d918c9))
- Master test runner `run_all_tests.sh` ([6c67388](https://github.com/Dicklesworthstone/repo_updater/commit/6c673886c2a5ec8b4f3032cb5e43d9b8e9b20d1d))
- CI: matrix testing on Ubuntu and macOS ([6bd01c9](https://github.com/Dicklesworthstone/repo_updater/commit/6bd01c9bc79884c58ef09603d4be57b8889f5998))
- CI and release workflows ([fda5440](https://github.com/Dicklesworthstone/repo_updater/commit/fda5440b3424e9bbe84add87075f552d0291297e))

### Pre-Release Testing

- E2E tests: init, sync clone/pull, status, config, doctor, repo spec parsing, edge cases, self-update, installation ([4c95bc9](https://github.com/Dicklesworthstone/repo_updater/commit/4c95bc914b0f0618f80b3ac637e882e440c1c858)...[ffef04c](https://github.com/Dicklesworthstone/repo_updater/commit/ffef04c452917c51cb013e79eebedcdd1a0a9f27))
- Unit tests: core utilities, path sanitization, sync state, dependency checks, argument parsing, repo list management, config, timeout handling, gum wrappers ([668a82b](https://github.com/Dicklesworthstone/repo_updater/commit/668a82bbcaa12abeffd9d09cd6b6f42915318cb2)...[173fa28](https://github.com/Dicklesworthstone/repo_updater/commit/173fa284834edd74dab0d6fd9bd27467896b0f98))
- Review E2E and unit tests with fixtures ([173fa28](https://github.com/Dicklesworthstone/repo_updater/commit/173fa284834edd74dab0d6fd9bd27467896b0f98))
- Priority scoring edge case tests ([14ccbb6](https://github.com/Dicklesworthstone/repo_updater/commit/14ccbb6d01d5707c7da50d9f55472af78085cae2))
- Security: command validation bypass repro coverage ([0e8be46](https://github.com/Dicklesworthstone/repo_updater/commit/0e8be460f2eb387ac9cd10998d326531dbbfa903))

### Bug Fixes

- Diverged status check order in `process_single_repo` ([00108f8](https://github.com/Dicklesworthstone/repo_updater/commit/00108f8d7f6b8f80281c372ab847247a5a0bdf3d))
- Nameref shadowing in `resolve_repo_spec` ([539ee70](https://github.com/Dicklesworthstone/repo_updater/commit/539ee706bfecab936e6aa03054643270f0464d3a))
- Exit codes and result tracking in sync ([b62cc6d](https://github.com/Dicklesworthstone/repo_updater/commit/b62cc6df7a6c25e23651e56da1eb5753ebdd681c))
- Color detection: check stderr instead of stdout ([11d3f57](https://github.com/Dicklesworthstone/repo_updater/commit/11d3f5703e35eac28566043962d090d36cc79c03))
- Prune: `log_warn` and depth calculation ([044b823](https://github.com/Dicklesworthstone/repo_updater/commit/044b823327d7fbd0bdc794d059ceda1df4b6304f))
- Import: non-GitHub hosts, dead code cleanup ([3df929e](https://github.com/Dicklesworthstone/repo_updater/commit/3df929ebdaa83014971fcc615c2ae0771f17b71b))
- Missing `write_result` calls in parallel worker ([8e0724f](https://github.com/Dicklesworthstone/repo_updater/commit/8e0724fc4d5ce79ec2700d73ea6352513765ac33))
- Undefined `NC` variable (should be `RESET`) ([d4d1fe7](https://github.com/Dicklesworthstone/repo_updater/commit/d4d1fe72919d6bcb0c3c915aa93fab939d0293d3))
- Self-update error handling for repos without releases ([ddaf9df](https://github.com/Dicklesworthstone/repo_updater/commit/ddaf9df8d829383b0d838dde3e81c8b5c754bb88))
- Installer: handle 404 when no releases exist, cache busting ([047d270](https://github.com/Dicklesworthstone/repo_updater/commit/047d270d086da972834a41d0ed48ccfedaa8b77b), [b4da2c6](https://github.com/Dicklesworthstone/repo_updater/commit/b4da2c607e0ff0c2d83d6d8222cb077b074aa66b))
- Installer: portable mktemp cleanup ([40f28ca](https://github.com/Dicklesworthstone/repo_updater/commit/40f28ca4a85ee0d0ed184caa1d76263ffd32b8c3))
- Rate-limit governor bugs and defensive integer validation ([99839bf](https://github.com/Dicklesworthstone/repo_updater/commit/99839bfcded9440605b62f6efacb60a25d6f8f46), [778b93f](https://github.com/Dicklesworthstone/repo_updater/commit/778b93f1ec9b855e3953a9e903c5920bd8c6c191))
- Dashboard robustness issues ([899214d](https://github.com/Dicklesworthstone/repo_updater/commit/899214dbd55daf5f5eff3c64dd463359f11e31a7))
- `get_config_value` quote stripping ([7a4ab02](https://github.com/Dicklesworthstone/repo_updater/commit/7a4ab026afc2812c8cecd48ddd6955471a0d0e5d))
- Review: allow dry-run without driver, allow `--status` in `parse_args` ([7526e7e](https://github.com/Dicklesworthstone/repo_updater/commit/7526e7edbb76ed78348b04dfee395082c44cfd92), [f993212](https://github.com/Dicklesworthstone/repo_updater/commit/f993212597d783dfac62b0280a0916e726e5d82e))
- macOS compatibility + deep code review bug fixes ([99a1bc9](https://github.com/Dicklesworthstone/repo_updater/commit/99a1bc988d49fb80b3aef9bdb3adfa862b532f6b), [f2da8d7](https://github.com/Dicklesworthstone/repo_updater/commit/f2da8d72d6595026330075dc49988c289806ae1e))
- ShellCheck warnings across codebase ([bb35706](https://github.com/Dicklesworthstone/repo_updater/commit/bb35706441d2f87b97c3e523f81ea35a29efc74a), [240eda0](https://github.com/Dicklesworthstone/repo_updater/commit/240eda0bfe9c5ede7b9d58637fb59fb84102fc33))

---

## Project Inception -- 2026-01-03

Initial commit ([12ba14c](https://github.com/Dicklesworthstone/repo_updater/commit/12ba14ce09a1401ede2f24d4b703409963033c21)): project specification and documentation. Core script skeleton ([1849c70](https://github.com/Dicklesworthstone/repo_updater/commit/1849c709fec4a823ea9f173b0caafd18f975e266)) and core feature implementation ([ec2cef5](https://github.com/Dicklesworthstone/repo_updater/commit/ec2cef5943b26ac0bd2b335b1fce0e9e4590b226)) began on the same day; the project reached its first release (v1.0.1) two days later.
