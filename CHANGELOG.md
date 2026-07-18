# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [SemVer](https://semver.org/).

## [Unreleased]

Forked from [fusion](https://github.com/malakhov-dmitrii/fusion) and repurposed from planning to code review.

### Added
- `triage <dir> [role...]` — parses reviews, clusters findings on `(file, axis, line within +3 of the cluster's first line)` keeping the highest reported severity and every participant's raw wording, and precomputes `judge-plan.tsv` with 2 **non-author** judges per finding. This is in the harness rather than the playbook because both steps fail *silently* when hand-done: a model asked to merge duplicates drops findings, and a judge routed to its own finding returns `real` from an echo — neither is visible in the output afterwards.
- `$FUSION_REVIEW_ROSTER` — the roster, with **no fallback** to the planner's `$FUSION_ROSTER`. Review fans N reviewers *and* ~2 judges per finding, so borrowing a planner-sized roster would quietly multiply the cost of a run; unset now exits 96 instead.
- `judge <participant> <finding-file> <dir>` — adversarial refutation of a single finding by a participant that did **not** author it. Three-way `VERDICT: real|refuted|uncertain`, because forcing a binary launders uncertain findings into confirmed ones or drops them silently.
- `cross-verify` now takes an optional prompt file, so a one-off lens doesn't require editing the harness.
- Shared finding contract (`FINDING_FMT` / `FINDING_AXES`): `[BLOCKER|MAJOR|MINOR] <axis> <file>:<line> — <суть> — <пруф>`. `file:line` is what lets the host dedupe mechanically instead of asking a model to merge duplicates (which drops findings).
- `SKILL.md`: a review playbook — bundle (whole files, not hunks) → fan across the lens axes → normalize/dedupe → cross-verify for MISSED → per-finding judge → triaged report.

### Changed
- **The consensus gate is gone, on purpose.** A planner converges on one plan; a reviewer must not, or majority logic deletes the single-model finding that justified the ensemble. The finding set is a union; consensus applies per-finding via `judge`.
- `cross-verify` asks for MISSED findings before FALSE-POSITIVEs — grading the author's list only polices false positives, while the expensive miss in review is the bug nobody saw.
- Skill renamed `fusion` → `fusion-review` (`skills/fusion-review/review.sh`) to avoid colliding with hosts that ship their own `/review`.
- `triage` now takes **any number of roles in one pass** (default: `review`, plus `cross` when that round exists). It rebuilds `findings/` on every call, so the previously documented two-step — `triage $d` then `triage $d cross` — silently *deleted* the review round and left only cross. Naming roles one at a time can no longer lose a round.
- Participant identity is now explicit, not inferred. `fan` and `cross-verify` write a `<artifact>.author` sidecar with the participant string verbatim (for cross-verify: the verifier), and `triage` reads it. Consequently `sources:` in `findings/<nnn>.md` holds full participant strings (`opencode:zai-coding-plan/glm-5.2`) rather than filename slugs.
- The judge pool is the roster when `$FUSION_REVIEW_ROSTER` is set, otherwise the participants actually observed via the sidecars — so an explicit `fan <dir> claude codex` with the variable unset gets real judges instead of an empty plan.
- The triage summary line reports `candidates=` instead of `roster=` (it is the pool actually used, which may come from sidecars), and gained a trailing `roles=`. `roles=` is last because it is the only free-form field, keeping every counter ahead of it trivially parseable.

### Fixed

Round-1 multi-model review of this repo. Each item below had made one of the tool's **own** guarantees false, and every one of them was invisible in the output — the same unfalsifiable shape as the roster drift this project already got burned by. Each is pinned by a regression test.

- **A finding could vanish from both denominators.** An indented finding line failed the severity-tag test and was skipped before anything reached `unparsed.md`, so it was counted nowhere. A tool whose headline claim is its denominators must never drop a line into neither of them; finding-*shaped* lines that fail a later check now always land in `unparsed.md` (prose still counts nowhere, or the parse-failure signal would be worthless).
- **A model could judge its own finding.** Identity was inferred from a filename, but the slug is lossy and one-way and a cross-verify basename (`grok-on-opencode_glm.md`) encodes two identities and parses back to neither — so the author-exclusion test never matched and a model was routed to adjudicate its own finding, an echo reported as independent confirmation. Fixed by the `.author` sidecar plus whole-string comparison, so `grok` is also never confused with `grok-4.5`.
- **Clusters chained without bound.** Distance was measured from the previous row, so each successive +3 gap extended the window and lines 10,13,16,19,22 collapsed into one finding while the docs promised ±3 — unrelated bugs merged, undetectably. Distance is now measured from the cluster start.
- **`--` was treated as a separator,** which rewrote every finding *about a CLI flag* into a different claim: `ignores --readonly — flag treated as path` parsed as gist `ignores`, proof `readonly`. The em-dash is now the only separator and the proof takes everything after the second one, so em-dashes inside a proof survive verbatim.
- **Empty runs printed counters with embedded newlines** (`raw=0\n0`): on an empty file `grep -c` prints `0` *and* exits 1, so the fallback fired too. One `_count` helper now guarantees a single clean integer per counter.
- **`file.go:10-15` was rejected** into `unparsed.md`. A range is a legitimate location; the first number is taken as the line.
- **Raw reports kept only the gist,** discarding each participant's proof, while this changelog claimed every participant's wording was preserved under a merged finding. Both are kept now.
- **The playbook told the orchestrator to give each participant its own lens**, prepended to its prompt. `fan` takes ONE prompt file and sends it to every participant — per-participant prompts do not exist. Since the playbook is executed literally by a model, that step was unperformable and would silently produce a broken run. The lens axes are now a set every reviewer is asked to cover in the one shared prompt, and `SKILL.md` says plainly that per-participant lenses are unsupported.
- **`install.sh` advertised a default roster** of `claude codex deepseek`. There is no default: `$FUSION_REVIEW_ROSTER` is required and `fan` exits 96 when it is unset. The bug-report template asked for the planner's `$FUSION_ROSTER` for the same reason.
- **CI now runs `tests/triage-test.sh`** (fixtures only — no model calls, no network). Every bug in this round passed the existing four checks: `bash -n`, shellcheck, a `--help` grep and an install idempotency test all lint *shape*, and none of them can observe behaviour.

Round-2 multi-model review, run on the round-1 fixes. Several items below are defects round 1 **introduced** — a fix that restores one guarantee while quietly breaking another is the failure mode a self-hosted review harness exists to catch.

- **The `.author` basename fallback reinstated the self-judging bug.** Round 1 added identity sidecars but kept "fall back to the basename if the sidecar is absent". A basename is not an identity: a cross artifact (`cross/grok-on-claude_opus.md`) with no sidecar yielded `sources: grok-on-claude_opus`, which matches no roster entry, so author-exclusion excluded nobody and the judge plan assigned **both** `grok` and `claude:opus` — the round-1 defect, restored by its own fix. The fallback is gone; `triage` now exits **93** naming the file. `fan`/`cross-verify` always write sidecars, so a missing one means a stale artifact, and guessing is what produced the bug.
- **Decorated finding lines still vanished from both denominators.** Round 1 handled leading whitespace and `-`/`*` bullets only, but models emit markdown: bold, numbered and blockquoted findings matched neither the shape test nor `unparsed.md`. A four-line file of `**…**`, `1. …`, `> …` and a plain finding parsed as `raw=1`. Blockquote markers, list markers (`-`, `*`, `+`, `1.`, `1)`) and emphasis runs (`**`, `__`, `*`, `_`, leading and trailing) are now stripped before the shape test. Decoration never rescues a malformed finding — it still lands in `unparsed.md`.
- **`judge` did not consult the plan.** `triage` filtered authors out of `judge-plan.tsv`, but `judge` accepted any participant for any finding, so "the host cannot get routing wrong" held only while the host transcribed the plan correctly — an advisory guarantee. `judge` now reads the finding's own `sources:` and refuses with exit **92** before any model call.
- **Co-discovered findings were misreported as degraded.** When a finding's `sources:` already cover every candidate there are no non-author judges — but that is independent discovery by every available family, the ensemble's *best* case, and it was reported identically to a roster too small to find two judges. `SKILL.md`'s `judged: co-discovered` rule was therefore unenforceable by the host. Now mechanical: such findings are labelled `judged: co-discovered` in the finding file and counted in a separate `co-discovered=` field, **excluded** from `under-judged=`, which now means only "roster too small". Co-discovery additionally requires ≥2 candidates — a pool of one trivially satisfies "sources cover every candidate" while nobody corroborated anything.
- **The flagship no-self-judging test was vacuous.** The "B2 exact repro" case asserted only that each author was *absent* from its own finding's judges — which an entirely **empty** `judge-plan.tsv` satisfies, so the guarantee the case is named after was untested inside it. Routing cases now assert the judge set **equals** the expected non-author set, exactly and sorted, which fails both when an author sneaks in and when nobody is routed at all. The rest of the suite was audited for the same pattern.
- **A repeated role double-counted every finding.** `triage $d review review` walked the same directory twice; the roles list is deduped.
- **The seal did not cover identity.** `SEALED.manifest` and `chmod a-w` covered only `.md` artifacts, but identity had moved into unsealed `.author` sidecars — so a sidecar could be re-attributed after sealing without breaking a single checksum, a strictly worse tamper than editing the prose. Sidecars are now sealed with the drafts they name.
- **The judge pool ignored who actually succeeded.** Found by running the harness, not by a model: `opencode:zai-coding-plan/glm-5.2` timed out during `fan`, yet `triage` assigned it as judge in 10 of 16 pairs and every one of those judgements timed out too. When `status.json` exists, participants not recorded `ok` are excluded from the pool, counted in `excluded=`, and named on stderr — never a silent shrink. A participant *absent* from `status.json` is unknown, not failed, and does not shrink the pool.
- **Stale header comment**: `triage <dir> [role]` documented a singular role after the multi-role change.

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
