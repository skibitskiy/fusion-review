# fusion-review

[![CI](https://github.com/skibitskiy/fusion-review/actions/workflows/ci.yml/badge.svg)](https://github.com/skibitskiy/fusion-review/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Multi-model adversarial code review.** Every model you put in `$FUSION_ROSTER` — Claude, Codex, Grok, or anything you reach through [opencode](https://opencode.ai) (GLM, Kimi, DeepSeek, MiniMax…) — reviews **the same diff independently** under a different lens, then attacks the others' output: what did they *miss*, and which of their findings don't survive a refutation attempt. The output is a triaged findings report — fusion-review never touches your code.

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
fan ──► model A  (correctness/concurrency)     ┐  every model sees the WHOLE bundle;
        model B  (security/untrusted-input)    │  the lens biases attention, it does
        model C  (api-contract/compat)         │  not shard the work
        model D  (tests/observability)         ┘  each ends with a REVIEWED: witness line
   │
   ▼
normalize + dedupe   [SEV] axis file:line — суть — пруф   ← mechanical, on file:line.
   │                 unparseable / proof-less lines are counted, not hidden
   ▼
cross-verify  (rotation — nobody grades themselves)
   asks for MISSED first, FALSE-POSITIVE second
   │
   ▼
judge  (per finding: 2 participants that are NOT its authors, told to REFUTE)
   both real → confirmed · both refuted → refuted · anything else → disputed
   disputed BLOCKER → spike: reproduce it in a throwaway worktree
   │
   ▼
report.md   confirmed · disputed · refuted   + a coverage block with every denominator
```

Three invariants make it trustworthy:
- **Union, not consensus.** A single-model finding is marked `sources: 1`, never dropped.
- **No self-confirmation.** A model never judges its own finding — that's an echo, not verification.
- **Every number carries its denominator.** Not "found 5 bugs" but `5 confirmed / 23 raw · 4/4 participants ok · 12/12 files bundled · 3 unparsed`. A participant that returns nothing must prove it looked (`REVIEWED:` line) or it counts as an error, not as "clean".

Write isolation is inherited from fusion: review is read-only, a git guard snapshots the repo before and after every fan, and a mutated tracked file stops the run (`write_leak: true`).

## Quickstart

```bash
git clone https://github.com/skibitskiy/fusion-review && cd fusion-review
./install.sh                 # detects Claude Code / Codex, links the skill
# authenticate the providers in your roster (below), then:
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
| `FUSION_ROSTER` | participant list — **the roster `fan` runs** | none (unset → `fan` errors) |
| `FUSION_MODEL_DEEPSEEK` | model for the `deepseek` alias | `opencode-go/deepseek-v4-pro` |
| `FUSION_CLAUDE_EFFORT` | `--effort` for `claude` | CLI default |
| `FUSION_GROK_EFFORT` | `--effort` for `grok` | CLI default |
| `FUSION_TIMEOUT` | per-call timeout (s) | `300` |
| `FUSION_GUARD_REPO` | repo the write-guard watches | `$PWD` |
| `FUSION_SCRATCH` | scratch dir for model writes | `/tmp/fusion-scratch` |

Env var names keep the `FUSION_` prefix on purpose: if you run both fusion and fusion-review, one roster configures both.

`fan` reads `$FUSION_ROSTER` itself when called with no participant arguments — prefer that over passing a list. Every `status.json` carries a `roster` block (`configured`, `matches_config`, `missing`, `unconfigured`); a run that doesn't match the configured ensemble prints `ROSTER-DRIFT`. The point is that `coverage.requested` alone can't tell you whether the ensemble was whole: its denominator comes from the caller, `roster.configured` comes from your config.

> **Instruction isolation.** Grok's claude-compat scan would otherwise load the same `CLAUDE.md` the `claude` participant obeys — a *shared input blind spot*, the very thing an ensemble exists to avoid. `grok` runs with `GROK_CLAUDE_AGENTS_ENABLED=false` so the two families genuinely differ in what they read. The same reasoning is why reviewers never see each other's output before their round is sealed.

A participant is `claude[:model]` · `codex` · `grok[:model]` · `opencode:<model>` · `deepseek` (alias). So you can run a **fully opencode-only** ensemble of three different families:

```bash
export FUSION_ROSTER="opencode:opencode-go/glm-5 opencode:opencode-go/kimi-k2.7-code opencode:opencode-go/deepseek-v4-pro"
```

## Usage

```
/fusion-review --dir <target-repo> [--base <ref> | --pr <n>] [--depth lite|full]
```

`full` (default) = fan + cross-verify + judge. `lite` = fan + judge, for when you want the union fast.

Or drive the harness directly (no host needed):

```bash
bash skills/fusion-review/review.sh fan review prompt.txt runs/r1        # roster from $FUSION_ROSTER
bash skills/fusion-review/review.sh cross-verify codex runs/r1/review/codex.md runs/r1
bash skills/fusion-review/review.sh judge grok runs/r1/findings/007.md runs/r1
bash skills/fusion-review/review.sh collect runs/r1
bash skills/fusion-review/review.sh --help
```

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
