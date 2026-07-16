---
name: fusion
description: Multi-model consensus planner (v2) — routes bug/unknown-root tasks through a LOCATE-the-fault phase before planning, gathers diverse real evidence (reproduce + probe + multi-modal sweep) BEFORE reasoning, then has every model in your $FUSION_ROSTER independently draft over a full vertical-slice brief, cross-verify each other (incl. a wrong-layer adversary), survive a pre-mortem, and reach consensus on material axes before any plan is emitted. Use for a non-trivial task that needs a maximally hardened plan OR a root-cause that must not be mis-located. Output is a plan; implementation is out of scope (hand to forge/improve).
---

# fusion v2 — locate-then-plan, evidence-first multi-model consensus

Every model configured in `$FUSION_ROSTER` — different families, whatever you chose — **independently** drafts a plan, cross-verifies another, and they **must reach consensus** on the material axes before a plan is emitted. Premise: an ensemble of different families beats one frontier model because their blind spots differ — **but only if they don't share the SAME input blind spot.** v2 exists because v1 lost to a single human teammate on a real bug: the host cut a symptom-scoped brief (one layer), all 5 models reasoned over it, and the true root lived in a layer (protocol/schema decode) that was never in the brief or probed. The teammate won by *running it and seeing the error*. v2 fixes that structurally: **observe before you reason; locate before you plan; treat the brief boundary as the enemy.**

The orchestrator is **the host model** (Claude Code or Codex) running this playbook. All reasoning participants are called the same way through `fusion.sh`, so the orchestrator is not privileged and **does not decide by majority**: consensus is computed mechanically from votes, tie broken by the operator.

## When to use
A non-trivial task that needs a hardened plan with real alternatives and checked assumptions, OR a bug whose root cause must not be mis-located. **Not** for quick answers/trivial edits — it is a batch tool (minutes, multiple models × rounds).

## Invariants (never break)
- **Locate before you plan.** If the task is "why is X broken / X is wrong" and the root cause is not already pinned by evidence, you MUST complete the LOCATE phase (R + 1) before any drafting. Never ensemble-plan a mystery.
- **Evidence before hypotheses.** Phase 1 (reproduce + probe + sweep) runs BEFORE the draft. A plan whose #1 root cause rests on an unrun probe ships as `root-cause: HYPOTHESIS (probe <X> pending)` with that probe as step 0 — never as confirmed, and the host never reports "fixed" on it.
- **The brief is a full vertical slice or it is a defect.** It must trace the failing operation across every layer boundary down to the substrate and end with a `Layers covered / Layers NOT covered` manifest. A single-layer brief → warn loudly.
- **Diversity of evidence enriches the brief; it never shards the reasoning.** The sweep agents gather DIFFERENT evidence in parallel; every gathered fact is mechanically verified before entering the brief. All reasoning participants then see the SAME full enriched brief and reach INDEPENDENT conclusions. (Why: sharding reasoning per-model loses the "different models → different conclusions" payoff and lets a weak model poison its slice. Keep gathering parallel+checked, keep reasoning full-context+independent.)
- **Every number travels with its denominator (coverage discipline).** No bare count or percent is quotable — it always carries "out of what". `status.json` now emits a `coverage` block (`requested/ok/timeout/error/degraded`); the synthesized plan states `consensus 3/3` vs `2/3 (degraded)`, `swept 4/6 layers`, never a naked "consensus" or "verified". A metric without its denominator hides whether you checked everything-and-it's-clean or 10%-and-that-10%-is-clean. The `Layers covered / NOT covered` manifest and `decision ∈ {consensus,degraded}` are the same discipline — generalize it to every emitted number.
- **Hard consensus gate:** synthesize only when every available participant is `reached` on the material axes (architecture · approach · key-assumptions). A 2-of-3 majority never overrides a dissenter.
- **`decision ∈ {consensus, operator_decision, blocked, degraded}`** — a plan after an operator tie-break is `operator_decision`, never `consensus`.
- **`<2` families available → `degraded`,** never presented as fusion. **`write_leak: true` in status.json → STOP.**
- **Isolation by artifact location, not by blinding the agent (Δ2).** A drafter MUST keep live repo read-access (it goes and reads the code it needs — the brief can't pre-include everything), so every participant runs WITH the repo as its working dir. Isolation comes from **run artifacts living OUTSIDE the repo working tree** (set `RUN` to an out-of-repo private root): a participant browsing the repo sees all the code but NO run's drafts — not its own (blind-first) and not a concurrent sibling fusion's (no cross-run echo as fake corroboration). Drafts also seal read-only + shasum-manifest (`SEALED.manifest`) the instant a round ends. Limit: this removes accidental cross-run exploration, not a kernel sandbox — a participant already holding an absolute path to a sibling run could still read it.

## Parameters
`/fusion <task> --dir <target-repo> [--depth lite|full] [--force-plan]`  (lite = 1 round, full = 2; default full. `--force-plan` skips the LOCATE phase only when the operator asserts the root is already pinned.)

**Roster (`$FUSION_ROSTER`)** — participant list. participant = `claude[:model] | codex | grok[:model] | opencode:<model> | deepseek`. Cross-verify rotation = cyclic shift (i verifies i+1).
**Never expand the roster by hand.** Call `fan` with NO participant arguments and let it read `$FUSION_ROSTER` itself. The host silently substituting its own list is a real, observed failure (runs went 7-of-7, then 3-of-7, then invented a participant that was never configured) — and because `coverage.requested` counted whatever the host passed, a third of the ensemble reported as full coverage. `status.json.roster.matches_config: false` (+ a `ROSTER-DRIFT` warning) now means the run is NOT the configured ensemble: treat it like `write_leak` — stop and fix the call, don't narrate around it.
**Layer lenses (optional, recommended for cross-layer bugs):** assign each drafter a primary lens — `client-reactive` / `server-lifecycle` / `protocol-schema` / `infra-latency` — passed as a line in the draft prompt. The lens biases attention; **every drafter still sees the full brief** (lens ≠ shard).

## Playbook

Throughout: `export FUSION_GUARD_REPO=<target> FUSION_SCRATCH=/tmp/fusion-$TS; RUN=$HOME/.fusion/runs/$(basename <target>)-$TS; SH=skills/fusion/fusion.sh`.
**RUN lives OUTSIDE the target repo on purpose (Δ2):** participants run with repo read-access, so if artifacts sat in `<target>/.fusion/runs/` a drafter browsing the repo would see its own + concurrent siblings' drafts. Out-of-repo artifacts keep the code readable while keeping every run's drafts invisible to participants. Inspect/collect results under `$RUN`; copy the final plan back into the repo only if you want it committed.

### R. Routing gate (debug-before-plan) — FIRST
Classify the task in one line and write `$RUN/routing.md`:
- **`bug / unknown-root`** ("why is X broken", "X is slow/wrong/flaky", symptom described, root not named with evidence) → run LOCATE (Phase 1) before drafting. This is the default for anything phrased as a malfunction.
- **`design / wide-solution`** (problem understood, many viable approaches, e.g. "how should we architect X") → LOCATE is light (still gather evidence), go to drafting.
- Unsure → treat as `bug / unknown-root`. The cost of locating a non-mystery is small; the cost of ensemble-planning a mislocated mystery is this whole incident.
Load any relevant fusion post-mortems + repo memory (e.g. prior spikes/“seam” notes) and **explicitly check them against the task** — the lesson that would have saved v1 already existed in memory and went unconsulted.

### 0. Setup
`bash "$SH" cleanup`. `mkdir -p $RUN`. `fan`/`spike` preflight GNU `timeout` and refuse to run without it (macOS: `brew install coreutils`) — never let a missing harness be read as "every model errored".

### 1. LOCATE — evidence FIRST (reproduce · probe · multi-modal sweep)
Do this with your own tools (Bash/agents) AND `fusion.sh spike` — BEFORE any model drafts.
1. **Reproduce + instrument.** Trigger the failing operation; capture the *actual* error signatures (stack traces, decode errors like `TypeNotFoundError`/`Constructor ID`, timeouts, status codes), not a description of them. `bash "$SH" spike "reproduce <symptom> and dump the real error at each boundary" $RUN <participant>` runs it in a throwaway worktree. If a live system / logs are the only ground truth and you can reach them, read them; if you cannot, that probe becomes a HYPOTHESIS gate (Invariant 2), not a skip.
2. **Multi-modal evidence sweep (parallel, blind).** Spawn several gatherers, each on a DIFFERENT angle, none reasoning about the fix yet:
   - by-data-flow: trace the failing op across every boundary (UI → transport → server → protocol → schema); record where it crosses and what type each side expects.
   - by-defensive-path: grep the subsystem for every fallback / retry / cache-on-error / `catch` around decode|parse|deserialize. **Each defensive path is a fossil of a root someone band-aided — trace each to its UPSTREAM trigger.**
   - by-recent-change: `git log`/blame on the failing files + recent dep/schema bumps.
   - by-substrate: the protocol/schema/codec/version layer the symptom never names (the layer split, the generated TL/IDL, the gramjs/driver version).
   - by-symptom-search: literal error strings, issue/PR history, prior incidents.
3. **Verify every gathered fact mechanically** (quote+path → `verify-claims`) before it enters the brief. Un-cited evidence is dropped or marked `claimed, unverified`. This is what makes a weak gatherer harmless.
4. Output `$RUN/evidence.md`: the verified facts, the real error signatures, the defensive-path→upstream map, and a one-line **candidate-fault-location** per gatherer. If the gatherers point at different layers, that is signal — keep all.

### 2. Brief — full vertical slice (RAW + enriched)
Build `$RUN/brief.md`: repo tree (depth-capped), HEAD + recent log, ADR/CONTEXT/README (capped), and **the code of EVERY layer the failing operation crosses** (from Phase 1's data-flow trace) — not just the layer where the symptom shows. Append `$RUN/evidence.md` (verified facts + real errors + defensive-path map). No host *interpretation* (raw code + verified facts only), but the host IS responsible for reaching the substrate.
- End with a **`## Layers covered / Layers NOT covered`** manifest. If only one layer is covered → STOP and widen; a symptom-scoped brief is the v1 failure.
- `coverage = layers-reached-of-the-data-flow` (not just %files): missing the substrate layer → `BLOCKED: brief-not-vertical`.

### 3. Round 1 — draft (full brief, independent)
`$RUN/draft-prompt.txt` = full brief + task + **multi-angle requirement**:
(a) don't solve it · (b) solve it much simpler · (c) depends on future plans · (d) different scenarios ·
**(e) the root is in a layer NOT in this brief — name the layer and the probe that would find it ·
(f) for every defensive/fallback path, state the UPSTREAM condition that triggers it and whether it can be removed at the source (do NOT just harden the band-aid).**
Optional: prepend each drafter's layer lens. `bash "$SH" fan draft $RUN/draft-prompt.txt $RUN <roster>` — parallel, write-guarded. `write_leak=true`→STOP; `<2 ok`→`degraded`.

### 4. Round 1 — cross-verify (rotation + wrong-layer adversary)
Rotation (i verifies i+1), nobody grades themselves; contract baked into the command (correctness/completeness/assumptions/contradictions/missed-risks + `VERDICT:`):
- `bash "$SH" cross-verify <verifier> $RUN/draft/<author>.md $RUN` … (cyclic).
- **PLUS one dedicated wrong-layer adversary** (a fresh participant, ideally one given only the symptom + the converged root): *"Assume the proposed root cause is in the WRONG layer. Where else is the true cause — especially OUTSIDE the code shown? Name it and the probe that confirms it."* → `$RUN/cross/wrong-layer.md`. A verifier that only checks claims against shown code raises confidence in the wrong layer; this one attacks the boundary.

### 5. Aggregate · Round 2 — re-discuss + structured votes
`bash "$SH" collect $RUN`. Drift-check HEAD. Re-discuss prompt: everyone sees `aggregate.md` (incl. wrong-layer.md), revises / DISAGREEs, **ends with a VOTES block**:
```
VOTES:
architecture:    reached|split | material:true|false | position:<…> | evidence:<path|none> | would_accept_if:<…>
approach:        …
key-assumptions: …
```
`bash "$SH" fan rediscuss …` → cross-verify again (same rotation).

### 6. Pre-mortem gate (before synthesize)
One participant, single task: **"It is a week later and the operator says X is STILL broken. Write the most likely reason the just-agreed fix did NOT work."** → `$RUN/premortem.md`. If it names an un-examined layer, an unrun probe, or a defensive-path whose upstream was never addressed → **loop back** (one more LOCATE sweep / re-discuss on that point). Do not synthesize over a live pre-mortem objection.

### 7. Consensus gate (mechanical, from VOTES) + operator-probe-first
- Each material axis (`material:true`): all available `reached` → converged. Still `split` → spike a spikeable assumption (`confirmed/refuted` updates positions; `inconclusive` → `confidence=LOW`, surface `UNVERIFIED`, don't block); allow one extra re-discuss.
- **Operator-probe-first:** if the #1 root cause rests on an operator-observable that was NOT run in Phase 1 (prod logs, a live probe), the gate is NOT `consensus` on that point — synthesize with that probe as **step 0** and stamp `root-cause: HYPOTHESIS (probe pending)`. The host must not report the bug fixed until that probe is run.
- Not converged after cap (rounds=2, +1 post-spike) → operator tie-break (`AskUserQuestion`/text) → `operator_decision`; operator unavailable → `BLOCKED: no-consensus`. `material:false` axes don't gate. All material `reached` → `consensus`.

### 8. Synthesize (mechanical template)
Only when `decision ∈ {consensus, operator_decision}`. Fill from raw artifacts — every claim/boundary/assumption → a source path; add no new claims:
Problem · Constraints (union) · **Confirmed fault location + how it was observed (Phase 1 evidence)** · Chosen solution · Alternatives + why-rejected · Implementation steps `[{file, description, est-loc, depends-on}]` · Assumptions ranked (HIGH/MED/LOW) · **Operator-unknowns / pending probes (step 0)** · Pre-mortem residual risks · Hard boundaries + STOP · Git stamp + drift · `decision:` + `root-cause: confirmed|hypothesis`.
→ `$RUN/final/<topic>-plan.md`; `debate.md` = disagreements + resolution table (consensus/spike/operator/wrong-layer/premortem).

### 9. Learn (compounding)
Append a one-paragraph post-mortem to fusion memory: the symptom, the layer the root actually lived in, the probe that found it (or should have), and which brief layer was missing. The next run's Phase R loads it. This is how v2 stops repeating v1.

## Degraded / failures
- timeout/exit≠0/empty → `fan` retried **into a fresh run dir or a new role name**; mark `timeout/error`, continue if ≥2. A sealed round is Δ2-immutable: re-running `fan` on the same role now refuses with exit 95 (it used to hit `Permission denied` per participant and report `ok:0, degraded:true` while the previous drafts sat intact — a harness failure wearing a model failure's face).
- `ROSTER-DRIFT` / `roster.matches_config: false` → the run is not the configured ensemble. Re-run `fan` with no participant args. Dropping a participant is legitimate ONLY when its CLI is missing/unauthenticated — and then it is `degraded`, named as such, never quietly.
- codex `quota` → drop it. 2 families → `degraded: two-model` (mutual cross-verify, any unresolved material split → operator). 1 family → `degraded: claude-only`, `DEGRADED` in title.
- spike `refuted` → blocks dependent branch; `inconclusive` → LOW/UNVERIFIED, no block.
- LOCATE could not reach ground truth (no repro, no logs) → every root cause is a HYPOTHESIS; the plan leads with the probes needed and says so. Do not launder a hypothesis into a confirmed fix.
