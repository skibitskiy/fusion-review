# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [SemVer](https://semver.org/).

## [Unreleased]

Forked from [fusion](https://github.com/malakhov-dmitrii/fusion) and repurposed from planning to code review.

### Added
- `judge <participant> <finding-file> <dir>` — adversarial refutation of a single finding by a participant that did **not** author it. Three-way `VERDICT: real|refuted|uncertain`, because forcing a binary launders uncertain findings into confirmed ones or drops them silently.
- `cross-verify` now takes an optional prompt file, so a one-off lens doesn't require editing the harness.
- Shared finding contract (`FINDING_FMT` / `FINDING_AXES`): `[BLOCKER|MAJOR|MINOR] <axis> <file>:<line> — <суть> — <пруф>`. `file:line` is what lets the host dedupe mechanically instead of asking a model to merge duplicates (which drops findings).
- `SKILL.md`: a review playbook — bundle (whole files, not hunks) → lensed fan → normalize/dedupe → cross-verify for MISSED → per-finding judge → triaged report.

### Changed
- **The consensus gate is gone, on purpose.** A planner converges on one plan; a reviewer must not, or majority logic deletes the single-model finding that justified the ensemble. The finding set is a union; consensus applies per-finding via `judge`.
- `cross-verify` asks for MISSED findings before FALSE-POSITIVEs — grading the author's list only polices false positives, while the expensive miss in review is the bug nobody saw.
- Skill renamed `fusion` → `fusion-review` (`skills/fusion-review/review.sh`) to avoid colliding with hosts that ship their own `/review`.

### Removed
- The planner's LOCATE phase, vertical-slice brief, VOTES block, and pre-mortem gate.
- `examples/selftest-plan.md` — a planner output, misleading as an example for this tool. A real review report replaces it after the first end-to-end run.

## [0.1.0] — 2026-06-15

First public cut. Experimental.

### Added
- `fusion.sh` harness: `fan` (parallel, write-guarded), `cross-verify` (structured idiot-test), `spike` (isolated git worktree), `collect`, `selftest`, `cleanup`.
- Host-agnostic adapters: `claude[:model]`, `codex`, `grok[:model]`, `opencode:<model>`, `deepseek` — so an all-opencode roster (GLM + Kimi + DeepSeek) works with no Claude or Codex.
- `SKILL.md` playbook with a hard consensus gate (no majority override) and operator tie-break.
- `install.sh` for Claude Code and Codex; MIT license; design docs; a real run example.

### Known gaps
- ROI vs a single model is not yet measured (baseline A/B pending — see `docs/`).
- `SKILL.md` cross-verify quality varies by provider; treat a missing `VERDICT:` line as inconclusive.
