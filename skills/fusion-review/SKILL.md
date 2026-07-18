---
name: fusion-review
description: Multi-model adversarial code review — every model in your $FUSION_REVIEW_ROSTER independently reviews the same diff bundle against the same set of lenses, cross-verifies what the others MISSED, and every surviving finding is routed to models that did not author it for adversarial refutation (real/refuted/uncertain). Output is a triaged findings report with coverage denominators; it never edits your code. Use when a diff is worth more than one model's blind spots — release branches, security-sensitive changes, unfamiliar subsystems.
---

# fusion-review — union-first, refutation-gated multi-model review

Every model in `$FUSION_REVIEW_ROSTER` reviews **the same diff bundle independently**, then attacks each other's output. Premise: different model families have different blind spots, so the ensemble sees more than any one of them — **but only if the pipeline never asks them to agree on what to report.**

**This is the one place fusion-review deliberately breaks from its parent, fusion.** The planner has a hard consensus gate because it must emit ONE plan. A reviewer must not: if model A finds a race that B and C missed, majority logic deletes exactly the finding you paid four models to get. So:

> **Consensus applies per-finding, never to the finding set.** The set is a UNION. Each individual finding then has to survive adversarial refutation by models that did not author it.

The orchestrator is the host model (Claude Code / Codex) running this playbook. It is not privileged: it does not decide what is a real bug, it routes and counts.

## When to use
A diff worth more than one model's blind spots — release branches, security-sensitive changes, concurrency, migrations, code in a subsystem you don't know well. **Not** for a two-line change or a style pass; it is a batch tool (minutes, N models × rounds). For a fast single-model pass use the host's own review command.

## Invariants (never break)
- **Union, not consensus.** Never drop a finding because only one participant raised it. Single-source findings are the ensemble's whole point; they are marked `sources: 1`, not deleted.
- **No finding is confirmed by its author.** `judge` MUST route to participants that did not produce the finding. A model grading its own output confirms it — that is not verification, it is an echo.
- **No finding without `file:line` + a proof.** The proof is instrumental: a concrete `вход/состояние -> наблюдаемый неверный результат`, a caller that violates the assumption, a counter-example. "Looks wrong" is dropped at normalization, not reported.
- **Review whole files, never bare hunks.** A hunk that looks broken is routinely guarded 20 lines above it. Hunk-only context is the #1 manufacturer of false positives — the bundle carries the full text of every changed file.
- **Every number travels with its denominator.** Never "found 5 bugs". Always `5 confirmed / 23 raw findings · 4/4 participants ok · 12/12 changed files bundled · 3 unparsed`. A count without its denominator hides whether you reviewed everything-and-it's-clean or 10%-and-that-10%-is-clean.
- **Silence needs a denominator too.** A participant returning zero findings is either a clean diff or a lazy model, and they are indistinguishable without a witness. Every reviewer must end with `REVIEWED: <files> files, <hunks> hunks — findings=<k>`. Missing that line ⇒ the participant counts as `error`, not as "clean".
- **`write_leak: true` → STOP.** Review is read-only; a participant mutating tracked files invalidates the run.
- **`roster.matches_config: false` (ROSTER-DRIFT) → STOP.** Never expand the roster by hand — call `fan` with no participant args and let it read `$FUSION_REVIEW_ROSTER`. Host-substituted rosters are an observed failure in this lineage, and they corrupt `coverage.requested` so a third of the ensemble reports as full coverage.
- **Never hand-roll triage or judge routing.** `triage` does the parse, the dedupe, and the author-exclusion. Both hand-done steps fail *silently* — a model asked to merge duplicates drops findings, and a judge routed to its own finding returns `real` from an echo — and neither is visible in the output afterwards.
- **`<2` families available → `degraded`,** named as such in the report title, never presented as an ensemble review.
- **Isolation by artifact location (Δ2).** Reviewers need live repo read-access, so they run with the repo as cwd; isolation comes from `$RUN` living **outside** the repo tree, so no participant sees another's review. Rounds seal read-only + shasum manifest the moment they end.

## Parameters
`/fusion-review --dir <repo> [--base <ref> | --pr <n>] [--depth lite|full]`
`lite` = fan + judge (skip cross-verify). `full` = fan + cross-verify + judge (default).
**Roster (`$FUSION_REVIEW_ROSTER`)** — participant = `claude[:model] | codex | grok[:model] | opencode:<model> | deepseek`. It has **no fallback** to the planner's `$FUSION_ROSTER`: review fans N reviewers *and* ~2 judges per finding, so a planner-sized roster silently becomes a far bigger run. Unset ⇒ `fan` refuses (exit 96).

## Playbook

Throughout: `export FUSION_GUARD_REPO=<target> FUSION_SCRATCH=/tmp/fr-$TS; RUN=$HOME/.fusion-review/runs/$(basename <target>)-$TS; SH=skills/fusion-review/review.sh`.

### 0. Setup
`bash "$SH" cleanup`; `mkdir -p $RUN`. `fan`/`judge`/`spike` preflight GNU `timeout` and refuse without it (macOS: `brew install coreutils`) — never let a missing harness read as "every model found nothing".

### 1. Bundle the change (`$RUN/bundle.md`)
- **Diff:** `git diff $(git merge-base <base> HEAD)..HEAD` — merge-base, never a two-dot diff against a moved base, or you review someone else's commits. `--pr <n>` → `gh pr diff <n>`. Default base: the repo's default branch.
- **Full text of every changed file** (see the whole-files invariant). Depth-cap huge files, and say which were capped.
- **Blast radius:** for every changed exported/public symbol, grep its callers and include them. A signature change is correct in its own file and broken at the call site.
- **Context:** HEAD, branch, base ref, PR description if any, and the tests touching the changed files.
- End with a **`## Files covered / Files NOT covered (and why)`** manifest. Anything skipped (vendored, generated, over cap) is named here, not silently omitted.

### 2. Round 1 — fan review across the lens axes
`$RUN/review-prompt.txt` = bundle + contract. The prompt names **all** the lens axes and asks every reviewer to cover each one:
`correctness/concurrency` · `security/untrusted-input` · `api-contract/backward-compat` · `perf/resources` · `tests/observability`.
**Per-participant lenses are not supported.** `fan` takes ONE prompt file and sends the identical text to every participant — there is no per-participant prompt and no flag for one, so do not try to hand model A a different lens line than model B. Diversity here comes from the model families differing, not from the prompt differing; the shared axis list is what stops a family's blind spot from becoming the ensemble's.
The contract demands, for each finding, exactly `[BLOCKER|MAJOR|MINOR] <axis> <file>:<line> — <суть> — <пруф>`, and the closing `REVIEWED:` witness line.
Also require the inverse pass — it catches what a bug-hunt frames out: **what the diff should have changed and didn't** (missed call site, unupdated test, doc/flag drift).
`bash "$SH" fan review $RUN/review-prompt.txt $RUN` (no participant args — roster comes from env). `write_leak`→STOP. `<2 ok`→`degraded`.

### 3. Triage (`bash "$SH" triage $RUN [role...]`)
One command, no host judgement: it parses every finding line, clusters on `(file, axis, line within +3 of the FIRST line in the cluster)` keeping the highest reported severity and preserving each participant's raw gist *and* proof, writes `$RUN/findings/<nnn>.md` with a `sources:` header, sends unparseable or proof-less lines to `$RUN/unparsed.md`, and precomputes `$RUN/judge-plan.tsv` (2 non-author judges per finding).
- **All roles in ONE pass.** `triage` rebuilds `findings/` from scratch every call, so it takes *every* role you want represented at once. With no role args it does `review`, plus `cross` when `$RUN/cross` exists. Never name roles one at a time — the second call would rebuild without the first round.
- **Identity comes from the `<out>.author` sidecar** that `fan`/`cross-verify` write next to each artifact (for a cross-verify artifact the author is the *verifier*), not from the filename. So `sources:` holds full participant strings — `opencode:zai-coding-plan/glm-5.2`, not a slug — and author-exclusion compares whole strings, so `grok` is never confused with `grok-4.5`.
- **There is NO fallback to the basename.** A missing sidecar is a hard error (**exit 93**, naming the file): a filename is a lossy one-way slug, and for a cross artifact (`grok-on-claude_opus.md`) it is two participants fused into one unusable string that matches no roster entry — which excluded nobody and handed the finding to its own author. `fan`/`cross-verify` always write sidecars, so a missing one means a stale or hand-made artifact. **Re-run the round; never hand-write a sidecar to get past this.** Guessing identity is what produced the bug.
- **Markdown decoration is stripped before parsing** — blockquotes (`>`), list markers (`-`, `*`, `+`, `1.`, `1)`) and emphasis (`**`, `__`, `*`, `_`, incl. trailing) — so a bolded or numbered finding lands in the denominators instead of vanishing from both. Decoration never *rescues* a broken finding: undecorated-but-malformed still goes to `unparsed.md`.
- Location accepts `file:<n>` and `file:<n>-<m>` (a range's first number is the line).
- Repeated roles are deduped: `triage $d review review` counts each finding once.
It prints exactly:
`raw=… deduped=… unparsed=… judge-pairs=… under-judged=… co-discovered=… candidates=… excluded=… roles=…` — carry those numbers into the report's coverage block verbatim. `candidates=` is the size of the actual judge pool: `$FUSION_REVIEW_ROSTER` when set, otherwise the participants observed via the sidecars — so a hand-passed participant list still gets judges instead of an empty plan. `excluded=` counts participants dropped from that pool because `status.json` says they did **not** finish this round `ok` (they are also named on stderr) — a model that timed out during `fan` cannot judge it. `roles=` is last because it is the one free-form field.
**`under-judged=` and `co-discovered=` are opposite situations and must never be conflated.** `under-judged>0` means the roster was too small to find 2 non-authors — mark those `judged: <n>/2 (degraded)`. `co-discovered>0` means the finding's `sources:` already cover *every* candidate (needs ≥2 candidates); `triage` writes `judged: co-discovered` into the finding file itself. See step 5.

### 4. Cross-verify — MISSED first (skip if `--depth lite`)
Rotation (i verifies i+1, nobody grades themselves): `bash "$SH" cross-verify <verifier> $RUN/review/<author>.md $RUN`.
The baked contract asks for **MISSED before FALSE-POSITIVE** on purpose: grading the author's list only polices false positives, while the expensive miss in review is the bug nobody saw. New findings from this round re-enter step 3 **once** — re-run triage naming **both** roles in a single call, `bash "$SH" triage $RUN review cross` (no unbounded loop). One call, both roles: `triage review` followed by `triage cross` would rebuild `findings/` from the cross round alone and lose round 1 entirely.

### 5. Judge every finding (per-finding consensus)
Execute `$RUN/judge-plan.tsv` — each row is `<finding-id>\t<participant>`, already filtered so no participant judges its own finding: `bash "$SH" judge <participant> $RUN/findings/<id>.md $RUN`. Run the rows in parallel; each prints its verdict. Verdicts are `real|refuted|uncertain`:
- **`judge` enforces author-exclusion itself** (**exit 92**, no model call, no artifact) by reading the finding's own `sources:`. So the guarantee no longer depends on the host transcribing the plan faithfully — but execute the plan anyway: it is also the only thing that keeps judges *balanced* across findings.
- both `real` → **confirmed**; both `refuted` → **refuted**; anything else (incl. any `uncertain`) → **disputed**.
- A `disputed` BLOCKER is worth one `bash "$SH" spike "reproduce <finding> and show the actual failure" $RUN <participant>` — a worktree repro settles it with evidence instead of opinion.
- `triage` already flagged findings with fewer than 2 non-author judges; mark those `judged: <n>/2 (degraded)`. Never top up with an author to reach two.
- **Co-discovered findings have no judges left, and that is not a degradation.** When a finding's `sources:` already list *every* available candidate (and there were ≥2), the non-author pool is empty by construction. You do not have to detect this by hand: `triage` counts it as `co-discovered=` — **excluded from `under-judged=`** — and writes `judged: co-discovered` into the finding file. Do not top up with an author; `judge` would refuse anyway (exit 92). Copy the label through to the report and say in one sentence why it counts: independent discovery of the same `file:line` by every available family is corroboration from the same disjoint-blind-spots argument that judging rests on, and no author-run judge could add anything but an echo.

### 6. Report (`$RUN/report.md`)
Three sections, severity-ordered inside each: **Confirmed** · **Disputed** (with what would settle it) · **Refuted** (collapsed one-liners — kept, so a rejected finding isn't re-raised next run).
Every entry: `file:line`, суть, пруф, `sources:`, `judged:`. Lead the report with the coverage block:
`participants ok/requested · files bundled/changed · raw findings · deduped · confirmed/disputed/refuted · unparsed · decision ∈ {ensemble, degraded}`.
State the base ref and HEAD you reviewed — a report without its git stamp is unreproducible.

### 7. Learn
Append a paragraph to review memory: which lens axis carried the highest-severity confirmed finding (and whether any axis produced nothing across the whole roster — a dead axis is either a clean diff or a prompt that doesn't ask hard enough), which participant produced the most refuted findings (a noisy model is a roster decision), and any false-positive pattern worth adding to the contract. The next run's step 2 loads it.

## Degraded / failures
- timeout/exit≠0/empty → retry `fan` **into a fresh run dir or a new role name**; a sealed round is immutable (exit 95) and re-running into it would report `ok:0, degraded:true` while good drafts sit intact — a harness failure wearing a model failure's face.
- Missing `REVIEWED:` witness → treat that participant as `error`, never as "reviewed, clean".
- `triage` exit 93 (no `.author` sidecar) → an artifact was not produced by this harness, or the round predates sidecars. Re-run the round; do not hand-write a sidecar and do not "fix" it by renaming files.
- `judge` exit 92 (participant is a source) → routing error in the host, not a model failure. Re-read `judge-plan.tsv` for that finding; if the plan is empty for it, it is `co-discovered` or `under-judged` — check the triage counters, do not substitute an author.
- A participant that failed `fan` is dropped from the judge pool automatically (`excluded=`). If that takes the pool under 2, the run is `degraded` for the same reason a small roster is.
- `ROSTER-DRIFT` → the run is not the configured ensemble. Re-run `fan` with no participant args. Dropping a participant is legitimate only when its CLI is missing/unauthenticated — and then it is `degraded`, named, never quiet.
- Provider quota → drop it, recount coverage. 2 families → `degraded: two-model` (mutual cross-verify, judge falls back to 1/2). 1 family → `degraded: single-model`, `DEGRADED` in the report title — at that point this is a plain review, not an ensemble, and must not be sold as one.
- Diff too large for one bundle → split **by directory/subsystem, never by hunk**, run one pass per split, and report per-split coverage. Splitting mid-file breaks the whole-files invariant.
