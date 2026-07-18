# fusion-review

[![CI](https://github.com/skibitskiy/fusion-review/actions/workflows/ci.yml/badge.svg)](https://github.com/skibitskiy/fusion-review/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Multi-model adversarial code review.** Every model you put in `$FUSION_REVIEW_ROSTER` — Claude, Codex, Grok, or anything you reach through [opencode](https://opencode.ai) (GLM, Kimi, DeepSeek, MiniMax…) — reviews **the same diff independently** against the same set of lens axes, then attacks the others' output: what did they *miss*, and which of their findings don't survive a refutation attempt. The output is a triaged findings report — fusion-review never touches your code.

> **Status: v0.1, experimental.** Forked from [fusion](https://github.com/malakhov-dmitrii/fusion), whose harness (`fan` / `cross-verify` / `collect` / `cleanup`, the read-only sandboxing per CLI, the write-guard, the coverage discipline) this still is. The review playbook and the `judge` primitive are new and not yet battle-tested.

## Why not just consensus

fusion — the parent project — makes models **converge**, because a planner must emit one plan. Copying that into review is the mistake this repo exists to avoid:

> If model A finds a race that B and C missed, majority logic deletes exactly the finding you paid four models to get.

So fusion-review inverts the gate. **The finding set is a UNION; consensus applies per-finding.** Every finding — including one raised by a single model — is then routed to models that *did not author it* and asked to refute it instrumentally. A finding is confirmed by surviving attack, not by being popular.

The second failure mode is the opposite one: models inventing plausible bugs. That's what `judge` and the "no finding without `file:line` + a proof" rule are for. Both directions are policed; neither is policed by vote.

## How it works

```
bundle  (diff + FULL text of changed files + callers of changed symbols)
   │       whole files, never bare hunks — a hunk that looks broken
   ▼       is usually guarded 20 lines above it
fan ──► model A   ┐  ONE prompt file, sent verbatim to every participant. It names all the
        model B   │  lens axes — correctness/concurrency · security/untrusted-input ·
        model C   │  api-contract/compat · perf/resources · tests/observability — and each
        model D   ┘  model covers all of them. Diversity comes from the FAMILIES differing,
   │                 not the prompt: fan has no per-participant prompt. Every model sees the
   │                 WHOLE bundle and ends with a REVIEWED: witness line.
   ▼
triage               [SEV] axis file:line — суть — пруф   ← one command, no host judgement:
   │                 clusters on (file, axis, line within +3 of the cluster's first line), keeps
   │                 the highest severity, preserves every participant's raw gist AND proof, counts
   │                 unparseable/proof-less lines instead of hiding them, and precomputes
   │                 judge-plan.tsv (2 judges per finding, never authors)
   ▼
cross-verify  (rotation — nobody grades themselves)
   asks for MISSED first, FALSE-POSITIVE second
   │                 new findings re-enter triage ONCE — naming BOTH rounds in one call
   ▼                 (`triage runs/r1 review cross`), because triage rebuilds findings/ each time
judge  (per finding: 2 participants that are NOT its authors, told to REFUTE)
   both real → confirmed · both refuted → refuted · anything else → disputed
   disputed BLOCKER → spike: reproduce it in a throwaway worktree
   │
   ▼
report.md   confirmed · disputed · refuted   + a coverage block with every denominator
```

Three invariants make it trustworthy:
- **Union, not consensus.** A single-model finding is marked `sources: 1`, never dropped.
- **No self-confirmation.** A model never judges its own finding — that's an echo, not verification. `triage` computes the routing, so a host cannot get it wrong; both this and the dedupe are in the harness precisely because doing them by hand fails *invisibly*. Identity is not guessed from a filename: `fan` and `cross-verify` write a `<artifact>.author` sidecar holding the participant string verbatim (for a cross-verify artifact, the *verifier*), and exclusion compares whole strings — so `grok` is never mistaken for `grok-4.5`, and a compound name like `grok-on-opencode_glm` is never read as one identity.
- **Every number carries its denominator.** Not "found 5 bugs" but `5 confirmed / 23 raw · 4/4 participants ok · 12/12 files bundled · 3 unparsed`. A participant that returns nothing must prove it looked (`REVIEWED:` line) or it counts as an error, not as "clean".

Write isolation is inherited from fusion: review is read-only, a git guard snapshots the repo before and after every fan, and a mutated tracked file stops the run (`write_leak: true`).

## Quickstart

```bash
git clone https://github.com/skibitskiy/fusion-review && cd fusion-review
./install.sh                 # detects Claude Code / Codex, links the skill

# set a roster — there is no default, and no fallback (unset => fan exits 96)
export FUSION_REVIEW_ROSTER="grok opencode:zai-coding-plan/glm-5.2"

# authenticate those providers (below), then:
/fusion-review --dir <path-to-your-repo> --base main
```

## Requirements & providers

You only need the CLIs for the models in your roster.

| Participant | CLI | Auth | Smoke test |
|---|---|---|---|
| Claude | [`claude`](https://docs.claude.com/claude-code) | Claude Code login or `ANTHROPIC_API_KEY` | `claude -p "say OK"` |
| Codex / GPT | [`codex`](https://developers.openai.com/codex/cli) | `codex login` (ChatGPT) or `OPENAI_API_KEY` | `codex exec "say OK"` |
| Grok | [`grok`](https://grok.com) | `grok login` or `XAI_API_KEY` | `grok -p "say OK"` |
| GLM / Kimi / DeepSeek / MiniMax… | [`opencode`](https://opencode.ai) | `opencode auth login` (OpenCode Go / OpenRouter) | `opencode run -m opencode-go/glm-5 "say OK"` |

`git`, `bash`, `shasum` and GNU `timeout` (macOS: `brew install coreutils`) are assumed — the harness preflights `timeout` and refuses to run without it, rather than letting a missing harness look exactly like "every model found nothing". If a participant's CLI is missing or unauthenticated it is dropped and the run is labelled `degraded` — it won't pretend two models are four.

## Models & rosters

Everything is configured by environment variables — no config files:

| Var | Meaning | Default |
|---|---|---|
| `FUSION_REVIEW_ROSTER` | participant list — **the roster `fan` runs** | none, **no fallback** (unset → `fan` exits 96) |
| `FUSION_MODEL_DEEPSEEK` | model for the `deepseek` alias | `opencode-go/deepseek-v4-pro` |
| `FUSION_CLAUDE_EFFORT` | `--effort` for `claude` | CLI default |
| `FUSION_GROK_EFFORT` | `--effort` for `grok` | CLI default |
| `FUSION_TIMEOUT` | per-call timeout (s) | `300` |
| `FUSION_GUARD_REPO` | repo the write-guard watches | `$PWD` |
| `FUSION_SCRATCH` | scratch dir for model writes | `/tmp/fusion-scratch` |

The roster variable is deliberately **separate from the planner's `$FUSION_ROSTER`, with no fallback**. Review fans N reviewers *and* ~2 judges per finding, so a roster you sized for planning silently turns into a much bigger and slower run here. A forgotten variable should cost you an error message, not a bill — so `fan` refuses to start rather than quietly borrowing the planner's list. The other `FUSION_*` names are shared on purpose: timeouts and model aliases mean the same thing in both tools.

A good review roster is small and diverse — two or three *different families* beat five variants of one:

```bash
export FUSION_REVIEW_ROSTER="grok opencode:zai-coding-plan/glm-5.2"
```

`fan` reads `$FUSION_REVIEW_ROSTER` itself when called with no participant arguments — prefer that over passing a list. Every `status.json` carries a `roster` block (`configured`, `matches_config`, `missing`, `unconfigured`); a run that doesn't match the configured ensemble prints `ROSTER-DRIFT`. The point is that `coverage.requested` alone can't tell you whether the ensemble was whole: its denominator comes from the caller, `roster.configured` comes from your config.

> **Instruction isolation.** Grok's claude-compat scan would otherwise load the same `CLAUDE.md` the `claude` participant obeys — a *shared input blind spot*, the very thing an ensemble exists to avoid. `grok` runs with `GROK_CLAUDE_AGENTS_ENABLED=false` so the two families genuinely differ in what they read. The same reasoning is why reviewers never see each other's output before their round is sealed.

A participant is `claude[:model]` · `codex` · `grok[:model]` · `opencode:<model>` · `deepseek` (alias). So you can run a **fully opencode-only** ensemble of three different families:

```bash
export FUSION_REVIEW_ROSTER="opencode:opencode-go/glm-5 opencode:opencode-go/kimi-k2.7-code opencode:opencode-go/deepseek-v4-pro"
```

## Usage

```
/fusion-review --dir <target-repo> [--base <ref> | --pr <n>] [--depth lite|full]
```

`full` (default) = fan + cross-verify + judge. `lite` = fan + judge, for when you want the union fast.

Or drive the harness directly (no host needed):

```bash
bash skills/fusion-review/review.sh fan review prompt.txt runs/r1   # roster from $FUSION_REVIEW_ROSTER
bash skills/fusion-review/review.sh triage runs/r1                  # -> findings/ + judge-plan.tsv
bash skills/fusion-review/review.sh cross-verify codex runs/r1/review/codex.md runs/r1
bash skills/fusion-review/review.sh triage runs/r1 review cross     # re-triage: BOTH rounds, one call
bash skills/fusion-review/review.sh judge grok runs/r1/findings/007.md runs/r1
bash skills/fusion-review/review.sh collect runs/r1
bash skills/fusion-review/review.sh --help
```

`triage` takes **any number of roles in one pass** and rebuilds `findings/` from all of them (no args ⇒ `review`, plus `cross` if that round exists). Naming roles one at a time would drop the rounds you didn't name. It ends with a single summary line:

```
triage: raw=23 deduped=14 unparsed=3 judge-pairs=26 under-judged=1 co-discovered=2 candidates=3 excluded=1 roles=review cross
```

Every one of those is a denominator worth copying into the report verbatim. `candidates=` is the judge pool actually used — `$FUSION_REVIEW_ROSTER` when it's set, otherwise the participants observed via the `.author` sidecars, so passing a participant list by hand still yields judges instead of an empty plan. `excluded=` is how many of those were dropped because `status.json` records them as not `ok` this round (they're named on stderr too): a model that timed out during `fan` can't judge that run, and assigning it anyway just produces more timeouts. `roles=` sits last because it's the only free-form field, which keeps every counter ahead of it trivially parseable.

`under-judged=` and `co-discovered=` are deliberately **separate counters for opposite situations**, because one number reported both and made the good case indistinguishable from the bad one. `under-judged=` means the roster was too small to find two non-authors — a real degradation. `co-discovered=` means the finding's `sources:` already cover every candidate: every available family found it independently, so there is nobody left who *could* judge it without grading their own work. That's the ensemble working, not failing; `triage` labels those findings `judged: co-discovered` in the finding file itself.

Two guardrails are enforced mechanically rather than by convention:

- **`triage` refuses to guess an identity (exit 93).** Every artifact must have its `.author` sidecar. Filenames are lossy slugs — and a cross artifact's filename fuses *two* participants — so deriving a participant from one silently re-opens self-judging.
- **`judge` refuses to grade its own finding (exit 92).** It reads the finding's `sources:` before doing anything else, so the no-self-judging invariant no longer depends on the host executing `judge-plan.tsv` faithfully.

Artifacts land **outside** the reviewed repo, in `~/.fusion-review/runs/<repo>-<timestamp>/`. That's deliberate: reviewers run with live read-access to the repo, so in-tree artifacts would let one participant read another's review and turn an echo into fake corroboration.

## Works in Claude Code and Codex

The harness is plain bash + CLI adapters, so the orchestrator host is interchangeable. `install.sh` links the skill into `~/.claude/skills/` (Claude Code, invoked as `/fusion-review`) and/or `~/.codex/skills/` (Codex reads `SKILL.md`). The skill is named `fusion-review`, not `review`, to avoid colliding with hosts that ship their own `/review`.

## Limitations (read these)

- **Report-only.** fusion-review never edits your code. Hand confirmed findings to an executor.
- **Batch, not interactive.** N models × rounds — expect minutes. For a fast single-model pass, use your host's built-in review.
- **Costs more than one model.** Reach for it when a missed bug is expensive — release branches, security-sensitive diffs, concurrency, migrations — not for every PR.
- **Large diffs must be split** by directory/subsystem, never by hunk; splitting mid-file breaks the whole-files invariant that keeps false positives down.
- **Provider drift.** CLI flags and quotas change. Codex in particular has a usage quota and a strict `config.toml`.

## Lineage

Forked from [malakhov-dmitrii/fusion](https://github.com/malakhov-dmitrii/fusion). The harness is shared ancestry and harness fixes are cherry-picked from `upstream`; the review playbook, the `judge` primitive, and the union-over-consensus gate are this repo's. The parent's design docs — which explain why the harness looks the way it does — are kept in [`docs/lineage/`](docs/lineage); they describe the *planner*, not this tool.

## License

MIT © Dmitrii Malakhov (upstream fusion) · MIT © skibitskiy (fusion-review)
