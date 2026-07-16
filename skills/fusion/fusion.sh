#!/usr/bin/env bash
# fusion.sh — minimal multi-model fan-out harness (v1).
# Dumb pipe: fan / cross-verify / collect / cleanup. Orchestrator (any host) lives outside this script.
#
# A participant is "<kind>[:<model>]":
#   claude[:<model>]        -> claude -p [--model <model>]
#   codex                   -> codex exec --sandbox read-only   (model via ~/.codex/config.toml)
#   grok[:<model>]          -> grok -p --sandbox read-only       (grok-4.5, grok-composer-2.5-fast)
#   opencode:<model>        -> opencode run -m <model>          (deepseek-v4-pro, opencode-go/glm-5, .../kimi-k2.7-code, ...)
#   deepseek                -> alias for opencode:$FUSION_MODEL_DEEPSEEK
# Rosters are just participant lists, e.g.:
#   mixed:        claude codex grok deepseek
#   opencode-only: opencode:opencode-go/glm-5 opencode:opencode-go/kimi-k2.7-code opencode:opencode-go/deepseek-v4-pro
# ponytail: status.json built with printf, not jq — fine for v1.
set -uo pipefail

RUN_ROOT="${FUSION_RUN_ROOT:-.fusion/runs}"
TIMEOUT="${FUSION_TIMEOUT:-300}"
SCRATCH="${FUSION_SCRATCH:-/tmp/fusion-scratch}"

_slug() { printf '%s' "$1" | tr '/:' '__'; }   # participant -> safe filename

# _timeout — GNU timeout(1) under either name. Stock macOS ships NEITHER (coreutils installs
# `gtimeout`, or `timeout` only with gnubin on PATH). This matters more than portability
# pedantry: a bare `timeout` call exits 127 *per participant*, and status.json faithfully
# records that as `error` — a harness that is simply not installed looks EXACTLY like "every
# model failed". Fail loudly, once, in preflight instead of laundering it into model errors.
_timeout() {
  if command -v timeout >/dev/null 2>&1; then command timeout "$@"
  elif command -v gtimeout >/dev/null 2>&1; then command gtimeout "$@"
  else return 127
  fi
}
_preflight() {
  command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || {
    echo "fusion: no timeout(1) on PATH — every participant would fail with exit 127 and be" >&2
    echo "        misreported as a model error. Install it: brew install coreutils" >&2
    return 127
  }
}

# _run <participant> <promptfile>  — dispatch one model call, answer to stdout.
# Δ2 isolation (corrected): a drafter NEEDS live repo read-access to go read the code it
# wants — the brief can't pre-include everything. So every participant runs WITH the repo as
# its working dir (claude/codex inherit cwd=repo; opencode gets --dir "$repo"). Isolation is
# achieved instead by keeping run ARTIFACTS OUT of the repo working tree (the orchestrator
# sets RUN to an out-of-repo private root, e.g. ~/.fusion/runs/$TS): a participant browsing
# the repo sees all the code but NO run's drafts — not its own (blind-first) and not a
# concurrent sibling fusion's (no cross-run echo as fake corroboration). NOTE: this removes
# the accidental-exploration vector; a model already holding an absolute path to a sibling
# run could still read it. Hard guarantee = sandbox-exec/containers (deferred).
_run() {
  local participant="$1" pfile="$2"
  local kind="${participant%%:*}" model=""
  [ "$participant" != "$kind" ] && model="${participant#*:}"
  local prompt; prompt="$(cat "$pfile")"
  local repo="${FUSION_GUARD_REPO:-$PWD}"
  case "$kind" in
    claude)   claude -p ${FUSION_CLAUDE_EFFORT:+--effort "$FUSION_CLAUDE_EFFORT"} ${model:+--model "$model"} "$prompt" </dev/null ;;
    codex)    codex exec --sandbox read-only --skip-git-repo-check "$prompt" </dev/null ;;
    # --no-memory: grok's cross-session memory would carry one run's drafts into the next,
    # breaking blind-first. --no-subagents: a participant is ONE independent voice, not its
    # own fan-out (a self-fan would smuggle fake corroboration into a single draft).
    # GROK_CLAUDE_AGENTS_ENABLED=false: grok's claude-compat scan otherwise loads the same
    # CLAUDE.md the `claude` participant obeys — shared instructions are a SHARED INPUT BLIND
    # SPOT, the exact failure v2 exists to prevent. Participants must differ in what they read.
    grok)     GROK_CLAUDE_AGENTS_ENABLED=false \
              grok -p "$prompt" --cwd "$repo" ${model:+-m "$model"} \
                ${FUSION_GROK_EFFORT:+--effort "$FUSION_GROK_EFFORT"} \
                --sandbox read-only --no-memory --no-subagents </dev/null ;;
    deepseek) OPENCODE_DB=:memory: opencode run --title fusion --dir "$repo" \
                -m "${FUSION_MODEL_DEEPSEEK:-opencode-go/deepseek-v4-pro}" "$prompt" </dev/null ;;
    opencode|oc)
              [ -n "$model" ] || { echo "opencode participant needs a model: opencode:<model>" >&2; return 98; }
              OPENCODE_DB=:memory: opencode run --title fusion --dir "$repo" -m "$model" "$prompt" </dev/null ;;
    *) echo "unknown participant kind: $kind" >&2; return 99 ;;
  esac
}

# signature of target repo's tracked state — detect write-leaks from participants
_repo_sig() { git -C "${FUSION_GUARD_REPO:-$PWD}" status --porcelain 2>/dev/null | shasum | awk '{print $1}'; }

# fan <role> <promptfile> <dir> [participant...]  — parallel, write-guarded, status.json
# Participants default to $FUSION_ROSTER: the roster used to be documentation-only (nothing in
# this script ever read it), so the host model expanded `<roster>` by hand — and in real runs
# it drifted (7 of 7 once, 3 of 7 another time, and once a 4th participant that was never
# configured at all). Reading the env here makes the configured roster the default truth
# instead of a suggestion the caller may reinterpret.
cmd_fan() {
  local role="$1" prompt="$2" dir="$3"; shift 3
  _preflight || return 127
  [ $# -eq 0 ] && set -- ${FUSION_ROSTER:-}
  [ $# -eq 0 ] && { echo "fan: no participants and \$FUSION_ROSTER is empty" >&2; return 96; }
  # A sealed round is immutable by design (Δ2), so re-running into it makes every redirect fail
  # with "Permission denied" -> exit 1 -> `ok:0, degraded:true`, while the previous round's good
  # drafts still sit in those files. The documented retry path therefore reported "every model
  # failed" for a pure harness reason. Refuse instead: sealing and retrying must not both win.
  if [ -f "$dir/$role/SEALED.manifest" ]; then
    echo "fan: '$role' is already sealed in $dir (Δ2 immutable). Retry into a FRESH run dir," >&2
    echo "     or use a new role name — never re-run into a sealed round." >&2
    return 95
  fi
  mkdir -p "$dir/$role" "$SCRATCH"
  local sig_before sig_after leak=false p slug
  sig_before="$(_repo_sig)"
  for p in "$@"; do
    slug="$(_slug "$p")"
    ( _timeout "$TIMEOUT" bash "$0" _run "$p" "$prompt" \
        >"$dir/$role/$slug.md" 2>"$dir/$role/$slug.err"
      echo "$?" >"$dir/$role/$slug.exit" ) &
  done
  wait
  # Δ2 seal-before-share: the instant the round ends, freeze each draft (read-only + a shasum
  # manifest) BEFORE any later stage can show it to another participant — a tamper-evident
  # record that no draft was revised after glimpsing a sibling's.
  : >"$dir/$role/SEALED.manifest"
  for p in "$@"; do
    slug="$(_slug "$p")"
    [ -f "$dir/$role/$slug.md" ] || continue
    shasum "$dir/$role/$slug.md" >>"$dir/$role/SEALED.manifest" 2>/dev/null || true
    chmod a-w "$dir/$role/$slug.md" 2>/dev/null || true
  done
  sig_after="$(_repo_sig)"
  if [ "$sig_before" != "$sig_after" ]; then
    leak=true
    echo "WRITE-LEAK: target repo mutated during fan — a participant wrote tracked files" >&2
  fi
  _status "$dir" "$role" "$leak" "$@"
  [ "$leak" = true ] && return 3 || return 0
}

# cross-verify <verifier-participant> <target-plan-file> <dir> — idiot-test one plan
cmd_cross_verify() {
  local verifier="$1" target="$2" dir="$3"
  mkdir -p "$dir/cross"
  local vslug; vslug="$(_slug "$verifier")"
  local base; base="$(basename "$target" .md)"
  local pf="$dir/cross/prompt-$vslug-on-$base.txt"
  {
    echo "Ты — кросс-верификатор. Автор плана ниже НЕКОМПЕТЕНТЕН: перепроверь ИНСТРУМЕНТАЛЬНО"
    echo "(grep/read/контрпример, не «перечитал и согласен»). Оси проверки:"
    echo "correctness · completeness · assumptions · contradictions · missed-risks."
    echo "Формат КАЖДОЙ находки ровно: [BLOCKER|MAJOR|MINOR] <axis> @<секция> — <суть> — <пруф>."
    echo "Последняя строка ровно: VERDICT: verified|issues-found|blocked (blockers=<N>)."
    echo "--- ПЛАН: ---"
    cat "$target"
  } >"$pf"
  ( _timeout "$TIMEOUT" bash "$0" _run "$verifier" "$pf" \
      >"$dir/cross/$vslug-on-$base.md" 2>"$dir/cross/$vslug-on-$base.err"
    echo "$?" >"$dir/cross/$vslug-on-$base.exit" )
}

# collect <run-dir> — concat artifacts into aggregate.md
cmd_collect() {
  local dir="$1" out="$1/aggregate.md" f n
  n="$(ls "$dir"/*/*.md 2>/dev/null | wc -l | tr -d ' ')"
  { echo "# Aggregate — $dir"
    echo "coverage: $n artifact(s) included$([ -f "$dir/status.json" ] && printf ' · status.json: %s' "$(grep -o '"coverage":{[^}]*}' "$dir/status.json" 2>/dev/null)")"
    echo
    for f in "$dir"/*/*.md; do
      [ -f "$f" ] || continue
      echo "## $f"; echo '```'; cat "$f"; echo '```'; echo
    done
  } >"$out"
  echo "$out"
}

# cleanup [--all] — remove orphan fusion worktrees + scratch
cmd_cleanup() {
  git worktree list 2>/dev/null | awk '/fusion-spike/{print $1}' | while read -r w; do
    git worktree remove --force "$w" 2>/dev/null || true
  done
  rm -rf "$SCRATCH" 2>/dev/null || true
  echo "cleanup done"
}

# spike <hypothesis> <dir> [participant]  — test an assumption in a throwaway git worktree
# (write-enabled but isolated; the worktree is always removed). Prints a VERDICT line.
cmd_spike() {
  local hyp="$1" dir="$2" participant="${3:-deepseek}"
  _preflight || return 127
  mkdir -p "$dir/spikes"
  local slug; slug="$(printf '%s' "$hyp" | tr -c 'a-zA-Z0-9' '_' | cut -c1-48)"
  local out="$dir/spikes/$slug.md" repo wt rc
  repo="$(git -C "${FUSION_GUARD_REPO:-$PWD}" rev-parse --show-toplevel 2>/dev/null || true)"
  wt="$(mktemp -d "${TMPDIR:-/tmp}/fusion-spike-XXXXXX")"
  [ -n "$repo" ] && git -C "$repo" worktree add --detach -q "$wt" HEAD 2>/dev/null || true
  local prompt="Проверь гипотезу ИНСТРУМЕНТАЛЬНО в этой изолированной рабочей копии (можно создавать throwaway-код, запускать команды). Гипотеза: $hyp. Последняя строка ровно: VERDICT: confirmed|refuted|inconclusive — <evidence>."
  local kind="${participant%%:*}" model=""; [ "$participant" != "$kind" ] && model="${participant#*:}"
  ( cd "$wt" || exit 97
    case "$kind" in
      claude)      _timeout "$TIMEOUT" claude -p ${model:+--model "$model"} "$prompt" ;;
      codex)       _timeout "$TIMEOUT" codex exec --sandbox workspace-write "$prompt" ;;
      grok)        GROK_CLAUDE_AGENTS_ENABLED=false \
                   _timeout "$TIMEOUT" grok -p "$prompt" ${model:+-m "$model"} \
                     --sandbox workspace --always-approve --no-memory --no-subagents ;;
      deepseek)    OPENCODE_DB=:memory: _timeout "$TIMEOUT" opencode run -m "${FUSION_MODEL_DEEPSEEK:-opencode-go/deepseek-v4-pro}" "$prompt" ;;
      opencode|oc) OPENCODE_DB=:memory: _timeout "$TIMEOUT" opencode run -m "$model" "$prompt" ;;
      *) echo "spike: unknown participant $participant" >&2; exit 99 ;;
    esac
  ) >"$out" 2>"$dir/spikes/$slug.err"; rc=$?
  echo "$rc" >"$dir/spikes/$slug.exit"
  [ -n "$repo" ] && git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
  rm -rf "$wt"
  grep -E '^VERDICT:' "$out" 2>/dev/null || echo "VERDICT: inconclusive — no verdict line (exit $rc)"
}

# selftest [participant]  — cleanup + a trivial fan smoke; prints PASS/FAIL, exit 0 on PASS
cmd_selftest() {
  local participant="${1:-codex}" dir
  # Preflight here too: without it a missing timeout(1) surfaces as "FAIL — <p>: exit 99",
  # blaming the participant for a harness that was never installed.
  _preflight || { echo "FAIL — $participant: harness preflight (timeout(1) missing)"; return 1; }
  dir="$(mktemp -d "${TMPDIR:-/tmp}/fusion-selftest-XXXXXX")"
  cmd_cleanup >/dev/null 2>&1 || true
  printf 'Reply with exactly: OK\n' >"$dir/p.txt"
  cmd_fan selftest "$dir/p.txt" "$dir" "$participant" >/dev/null 2>&1 || true
  local slug ex bytes; slug="$(_slug "$participant")"
  ex="$(cat "$dir/selftest/$slug.exit" 2>/dev/null || echo 99)"
  bytes="$(wc -c <"$dir/selftest/$slug.md" 2>/dev/null || echo 0)"
  rm -rf "$dir"
  if [ "$ex" = 0 ] && [ "${bytes:-0}" -gt 0 ]; then
    echo "PASS — $participant: exit 0, ${bytes} bytes"; return 0
  fi
  echo "FAIL — $participant: exit $ex, ${bytes} bytes"; return 1
}

_usage() {
  cat <<'USAGE'
fusion.sh — minimal multi-model fan-out harness

  fan <role> <promptfile> <dir> <participant...>   run participants in parallel (write-guarded)
  cross-verify <verifier> <target-plan> <dir>      idiot-test one plan
  spike <hypothesis> <dir> [participant]           test an assumption in a throwaway worktree
  collect <dir>                                    concat run artifacts into aggregate.md
  selftest [participant]                           smoke the harness; PASS/FAIL
  cleanup                                          remove orphan worktrees + scratch

  participant = claude[:model] | codex | grok[:model] | opencode:<model> | deepseek
USAGE
}

# _roster_json <participant...> — roster-vs-config block. The denominator must come from
# CONFIG, not from the caller: `coverage.requested` counts whatever the host passed, so a run
# of 3-out-of-7 reports `requested:3, ok:3` and reads as full coverage. Two distinct drifts are
# both observed in real runs and both caught here: `missing` (configured but not run) and
# `unconfigured` (run but never configured — an invented participant).
_roster_json() {
  local configured="${FUSION_ROSTER:-}" p c found n=0 missing="" extra=""
  if [ -z "$configured" ]; then
    printf '"roster":{"configured":null,"matches_config":null}'; return
  fi
  for c in $configured; do
    n=$((n+1)); found=false
    for p in "$@"; do [ "$p" = "$c" ] && { found=true; break; }; done
    [ "$found" = false ] && missing="$missing${missing:+,}\"$c\""
  done
  for p in "$@"; do
    found=false
    for c in $configured; do [ "$p" = "$c" ] && { found=true; break; }; done
    [ "$found" = false ] && extra="$extra${extra:+,}\"$p\""
  done
  local match=true
  { [ -n "$missing" ] || [ -n "$extra" ]; } && match=false
  printf '"roster":{"configured":%d,"matches_config":%s,"missing":[%s],"unconfigured":[%s]}' \
    "$n" "$match" "$missing" "$extra"
}

# _status <dir> <role> <leak> <participant...>
# Coverage-denominator discipline: status.json carries a `coverage` block so no consumer can
# read "ok" without "requested". `degraded` is computed mechanically (ok<2 families = not a
# real fusion). A bare ok-count is never quotable; it always travels with its denominator.
_status() {
  local dir="$1" role="$2" leak="${3:-false}"; shift 3
  local sf="$dir/status.json" p slug ex st first=1
  local requested=$# ok=0 timeout=0 error=0 degraded
  { printf '{"run_dir":"%s","role":"%s","write_leak":%s,"participants":{' "$dir" "$role" "$leak"
    for p in "$@"; do
      slug="$(_slug "$p")"
      ex="$(cat "$dir/$role/$slug.exit" 2>/dev/null || echo 99)"
      case "$ex" in 0) st=ok; ok=$((ok+1)) ;; 124) st=timeout; timeout=$((timeout+1)) ;; *) st=error; error=$((error+1)) ;; esac
      [ $first -eq 1 ] || printf ','; first=0
      printf '"%s":{"exit":%s,"status":"%s"}' "$p" "$ex" "$st"
    done
    [ "$ok" -lt 2 ] && degraded=true || degraded=false
    printf '},"coverage":{"requested":%d,"ok":%d,"timeout":%d,"error":%d,"degraded":%s},' \
      "$requested" "$ok" "$timeout" "$error" "$degraded"
    _roster_json "$@"
    printf '}'
  } >"$sf"
  # Loud on stderr too: a JSON field nobody reads is not a guarantee.
  grep -q '"matches_config":false' "$sf" && \
    echo "ROSTER-DRIFT: run does not match \$FUSION_ROSTER — see roster.missing / roster.unconfigured in $sf" >&2
  cat "$sf"
}

main() {
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    _run)         _run "$@" ;;
    fan)          cmd_fan "$@" ;;
    cross-verify) cmd_cross_verify "$@" ;;
    spike)        cmd_spike "$@" ;;
    collect)      cmd_collect "$@" ;;
    selftest)     cmd_selftest "$@" ;;
    cleanup)      cmd_cleanup "$@" ;;
    help|-h|--help) _usage ;;
    *) _usage >&2; exit 1 ;;
  esac
}
main "$@"
