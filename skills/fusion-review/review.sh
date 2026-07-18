#!/usr/bin/env bash
# review.sh — minimal multi-model fan-out harness for CODE REVIEW.
# Dumb pipe: fan / cross-verify / judge / spike / collect / cleanup. The orchestrator (any host)
# lives outside this script.
#
# Lineage: forked from fusion (github.com/malakhov-dmitrii/fusion), whose harness this still is.
# Harness fixes flow in from `upstream` via cherry-pick; the playbook (SKILL.md) is our own.
# What differs from the planner: no consensus gate. A planner wants ONE agreed plan, so it makes
# models converge. A reviewer wants the UNION of findings — model A catching what B missed is the
# entire payoff of an ensemble, and converging would delete it. Consensus here applies per-finding
# (does this survive refutation?), never to the finding SET. That is what `judge` is for.
#
# A participant is "<kind>[:<model>]":
#   claude[:<model>]        -> claude -p [--model <model>]
#   codex                   -> codex exec --sandbox read-only   (model via ~/.codex/config.toml)
#   grok[:<model>]          -> grok -p --sandbox read-only       (grok-4.5, grok-composer-2.5-fast)
#   opencode:<model>        -> opencode run -m <model> (read-only via OPENCODE_CONFIG_CONTENT; deepseek-v4-pro, opencode-go/glm-5, .../kimi-k2.7-code, ...)
#   deepseek                -> alias for opencode:$FUSION_MODEL_DEEPSEEK
# Rosters are just participant lists, e.g.:
#   mixed:        claude codex grok deepseek
#   opencode-only: opencode:opencode-go/glm-5 opencode:opencode-go/kimi-k2.7-code opencode:opencode-go/deepseek-v4-pro
# ponytail: status.json built with printf, not jq — fine for v1.
set -uo pipefail

RUN_ROOT="${FUSION_RUN_ROOT:-.fusion/runs}"
TIMEOUT="${FUSION_TIMEOUT:-300}"
SCRATCH="${FUSION_SCRATCH:-/tmp/fusion-scratch}"

# Read-only rights for opencode drafters — the equivalent of codex/grok's --sandbox read-only,
# which opencode has no flag for. Passed inline via OPENCODE_CONFIG_CONTENT (no temp file), so
# many concurrent copies each carry their own rights with no shared-file race.
FUSION_OC_READONLY='{"permission":{"edit":"deny","bash":"deny"}}'

_slug() { printf '%s' "$1" | tr '/:' '__'; }   # participant -> safe filename

# _roster — the roster, from $FUSION_REVIEW_ROSTER only. Deliberately NO fallback to the planner's
# $FUSION_ROSTER: review fans N reviewers AND ~2 judges per finding, so a roster sized for planning
# silently turns into a much bigger, slower, more expensive run here. A forgotten variable must fail
# loudly, not quietly spend. Both the `fan` default and the drift check read THIS function, so they
# can never disagree about what the configured ensemble is.
_roster() { printf '%s' "${FUSION_REVIEW_ROSTER:-}"; }

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
    # opencode has no --sandbox flag (unlike codex/grok); read-only is enforced via a
    # rights config passed inline through OPENCODE_CONFIG_CONTENT (no temp file -> safe under
    # many concurrent copies). edit+bash deny blocks all writes; repo reads still work because
    # opencode reads via read/grep/glob tools, not bash. WRITE-LEAK guard stays as backstop.
    deepseek) OPENCODE_DB=:memory: OPENCODE_CONFIG_CONTENT="$FUSION_OC_READONLY" \
                opencode run --title fusion --dir "$repo" \
                -m "${FUSION_MODEL_DEEPSEEK:-opencode-go/deepseek-v4-pro}" "$prompt" </dev/null ;;
    opencode|oc)
              [ -n "$model" ] || { echo "opencode participant needs a model: opencode:<model>" >&2; return 98; }
              OPENCODE_DB=:memory: OPENCODE_CONFIG_CONTENT="$FUSION_OC_READONLY" \
                opencode run --title fusion --dir "$repo" -m "$model" "$prompt" </dev/null ;;
    *) echo "unknown participant kind: $kind" >&2; return 99 ;;
  esac
}

# signature of target repo's tracked state — detect write-leaks from participants
_repo_sig() { git -C "${FUSION_GUARD_REPO:-$PWD}" status --porcelain 2>/dev/null | shasum | awk '{print $1}'; }

# fan <role> <promptfile> <dir> [participant...]  — parallel, write-guarded, status.json
# Participants default to $FUSION_REVIEW_ROSTER: the roster used to be documentation-only (nothing in
# this script ever read it), so the host model expanded `<roster>` by hand — and in real runs
# it drifted (7 of 7 once, 3 of 7 another time, and once a 4th participant that was never
# configured at all). Reading the env here makes the configured roster the default truth
# instead of a suggestion the caller may reinterpret.
cmd_fan() {
  local role="$1" prompt="$2" dir="$3"; shift 3
  _preflight || return 127
  # shellcheck disable=SC2046  # word-splitting the roster into participants is the point
  [ $# -eq 0 ] && set -- $(_roster)
  [ $# -eq 0 ] && { echo "fan: no participants and \$FUSION_REVIEW_ROSTER is not set (it has no fallback --" >&2; echo "     a planner-sized roster would silently make this run far bigger)" >&2; return 96; }
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

# The finding format is the contract that makes the whole pipeline mechanical: `<file>:<line>`
# gives the host a key to dedupe on, so merging N reviews never needs a model to "merge duplicates"
# (which silently drops findings). Every stage that can emit a finding emits exactly this shape.
FINDING_FMT='[BLOCKER|MAJOR|MINOR] <axis> <file>:<line> — <суть> — <пруф>'
FINDING_AXES='correctness · security · perf · api-contract · tests · maintainability'

# cross-verify <verifier> <target-review> <dir> [prompt-file] — idiot-test one participant's REVIEW.
# The contract stays baked into the command by default (a host that re-composes the prompt each run
# drifts it — this project has already observed exactly that failure with the roster), but an
# explicit [prompt-file] allows a deliberate override for a one-off lens.
# Note the asymmetry vs the planner: here the verifier is asked for MISSED findings first. Grading
# the author's list only polices false positives; the expensive miss in review is the bug nobody saw.
cmd_cross_verify() {
  local verifier="$1" target="$2" dir="$3" custom="${4:-}"
  _preflight || return 127
  mkdir -p "$dir/cross"
  local vslug; vslug="$(_slug "$verifier")"
  local base; base="$(basename "$target" .md)"
  local pf="$dir/cross/prompt-$vslug-on-$base.txt"
  {
    if [ -n "$custom" ]; then
      cat "$custom"
    else
      echo "Ты — кросс-верификатор код-ревью. Автор ревью ниже НЕКОМПЕТЕНТЕН в ОБЕ стороны:"
      echo "он и ПРОПУСКАЕТ настоящие баги, и выдумывает несуществующие. Проверяй ИНСТРУМЕНТАЛЬНО"
      echo "(открой файлы, найди вызывающих, построй контрпример), не «перечитал и согласен»."
      echo "Выдай ДВА раздела:"
      echo "1) MISSED — что автор не увидел в дифе. Это главная часть; оси: $FINDING_AXES."
      echo "2) FALSE-POSITIVE — его находки, которые не выдерживают проверки, с пруфом почему."
      echo "Формат КАЖДОЙ находки в MISSED ровно: $FINDING_FMT"
      echo "Последняя строка ровно: VERDICT: verified|issues-found|blocked (missed=<N> fp=<N>)."
      echo "--- РЕВЬЮ: ---"
    fi
    cat "$target"
  } >"$pf"
  ( _timeout "$TIMEOUT" bash "$0" _run "$verifier" "$pf" \
      >"$dir/cross/$vslug-on-$base.md" 2>"$dir/cross/$vslug-on-$base.err"
    echo "$?" >"$dir/cross/$vslug-on-$base.exit" )
}

# judge <participant> <finding-file> <dir> — adversarially test ONE finding; prints its VERDICT.
# The host MUST route a finding to a participant that did not produce it: a model grading its own
# finding confirms it. The verdict is three-way on purpose — forcing a binary makes genuinely
# uncertain findings get laundered into `real` or silently dropped, and in review both are bad.
cmd_judge() {
  local participant="$1" target="$2" dir="$3"
  _preflight || return 127
  mkdir -p "$dir/judge"
  local pslug; pslug="$(_slug "$participant")"
  local base; base="$(basename "$target" .md)"
  local out="$dir/judge/$pslug-on-$base" rc
  {
    echo "Ты — состязательный судья ОДНОЙ находки код-ревью. Задача — попытаться её ОПРОВЕРГНУТЬ."
    echo "Проверяй ИНСТРУМЕНТАЛЬНО: открой указанные файлы, найди вызывающих, построй конкретный"
    echo "сценарий «вход/состояние -> наблюдаемый неверный результат». «Прочитал, выглядит верно» — не пруф."
    echo "Опровергай, если: путь недостижим, инвариант держится выше по стеку, случай уже покрыт"
    echo "проверкой/типом, поведение намеренное, или это стиль без последствий."
    echo "Не занижай настоящий баг из вежливости и не подтверждай то, что не смог воспроизвести."
    echo "Последняя строка РОВНО: VERDICT: real|refuted|uncertain — <пруф или чего не хватило>."
    echo "--- НАХОДКА: ---"
    cat "$target"
  } >"$out.prompt.txt"
  ( _timeout "$TIMEOUT" bash "$0" _run "$participant" "$out.prompt.txt" \
      >"$out.md" 2>"$out.err" )
  rc=$?
  echo "$rc" >"$out.exit"
  grep -E '^VERDICT:' "$out.md" 2>/dev/null || echo "VERDICT: uncertain — no verdict line (exit $rc)"
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

# triage <dir> [role] — parse the reviews in <dir>/<role>/, dedupe findings, and emit
#   findings/<nnn>.md · judge-plan.tsv · unparsed.md  + a one-line summary with every denominator.
#
# This lives in the harness rather than the playbook ON PURPOSE. Two of its steps fail SILENTLY when
# a host does them by hand:
#   - routing a finding to a participant that authored it yields `real` from an echo, and nothing in
#     the output reveals it happened;
#   - asking a model to "merge the duplicates" drops findings, and you cannot tell from the result.
# Both are unfalsifiable after the fact, which is the same shape as the roster drift this project
# already got burned by. So: mechanical step, mechanical implementation.
cmd_triage() {
  local dir="$1" role="${2:-review}"
  local rd="$dir/$role" raw="$dir/findings.tsv" un="$dir/unparsed.md" fdir="$dir/findings"
  [ -d "$rd" ] || { echo "triage: no round dir $rd" >&2; return 94; }
  rm -rf "$fdir"; mkdir -p "$fdir"; : >"$raw"; : >"$un"
  local f p
  for f in "$rd"/*.md; do
    [ -f "$f" ] || continue
    p="$(basename "$f" .md)"
    # A finding is `[SEV] axis file:line — gist — proof`. A line missing the location or the proof
    # is NOT downgraded into a vague finding — it goes to unparsed.md and stays in the denominator.
    awk -v P="$p" -v UN="$un" '
      function trim(x){ sub(/^[ \t]+/,"",x); sub(/[ \t]+$/,"",x); return x }
      {
        line=$0
        sub(/^[ \t]*[-*][ \t]*/,"",line)               # tolerate a markdown bullet
        if (line !~ /^\[(BLOCKER|MAJOR|MINOR)\]/) next
        split(line,t,/[ \t]+/)
        sev=t[1]; gsub(/[][]/,"",sev); axis=t[2]; loc=t[3]
        if (match(loc,/:[0-9]+$/)==0) { print line >> UN; next }
        file=substr(loc,1,RSTART-1); ln=substr(loc,RSTART+1)+0
        body=substr(line, index(line,loc)+length(loc))
        if (gsub(/—|--/,"@@S@@",body) < 2) { print line >> UN; next }   # no proof section
        split(body,b,"@@S@@")
        gist=trim(b[2]); proof=trim(b[3])
        if (file=="" || ln<=0 || gist=="" || proof=="") { print line >> UN; next }
        gsub(/\t/," ",gist); gsub(/\t/," ",proof)
        printf "%s\t%d\t%s\t%s\t%s\t%s\t%s\n", file, ln, axis, sev, P, gist, proof
      }' "$f" >>"$raw"
  done

  # Cluster on (file, axis, line within 3) — two models describing one bug rarely agree on the exact
  # line. The cluster keeps the HIGHEST severity reported, and every raw report is preserved beneath
  # it, so merging never silently discards a participant's wording.
  LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k3,3 -k2,2n "$raw" | awk -F'\t' -v OUT="$fdir" '
    function rank(x){ return x=="BLOCKER"?3:(x=="MAJOR"?2:1) }
    function flush(  i,fn,srcs) {
      if (ck=="") return
      n++; fn=sprintf("%s/%03d.md", OUT, n); srcs=""
      for (i=1;i<=ns;i++) srcs = srcs (srcs==""?"":", ") src[i]
      printf "id: %03d\nseverity: %s\naxis: %s\nlocation: %s:%d\nsources: %s\n\n", n, bsev, caxis, cfile, bline, srcs > fn
      printf "[%s] %s %s:%d — %s — %s\n", bsev, caxis, cfile, bline, bgist, bproof > fn
      printf "\nraw reports:\n" > fn
      for (i=1;i<=nv;i++) printf "- %s\n", var[i] > fn
      close(fn); ck=""; ns=0; nv=0
    }
    {
      key=$1 "\t" $3
      if (key!=ck || $2-lastline>3) { flush(); ck=key; cfile=$1; caxis=$3; bline=$2; bsev=$4; bgist=$6; bproof=$7 }
      lastline=$2
      if (rank($4)>rank(bsev)) { bsev=$4; bline=$2; bgist=$6; bproof=$7 }
      dup=0; for(i=1;i<=ns;i++) if(src[i]==$5) dup=1
      if(!dup) src[++ns]=$5
      var[++nv]=sprintf("[%s] %s:%d (%s) — %s", $4, $1, $2, $5, $6)
    }
    END { flush() }'

  # Judge routing: 2 participants per finding, NEVER one of its sources (see the header comment).
  local fn id srcs c chosen short=0
  : >"$dir/judge-plan.tsv"
  for fn in "$fdir"/*.md; do
    [ -f "$fn" ] || continue
    id="$(basename "$fn" .md)"
    srcs="$(awk -F'sources: ' '/^sources: /{print $2; exit}' "$fn")"
    chosen=0
    for c in $(_roster); do
      case ",$(printf '%s' "$srcs" | tr -d ' ')," in *",$(_slug "$c"),"*) continue ;; esac
      printf '%s\t%s\n' "$id" "$c" >>"$dir/judge-plan.tsv"
      chosen=$((chosen+1)); [ "$chosen" -ge 2 ] && break
    done
    [ "$chosen" -lt 2 ] && { short=$((short+1)); echo "triage: finding $id has only $chosen non-author judge(s) — mark it judged: $chosen/2 (degraded)" >&2; }
  done

  local n_raw n_find n_un n_pair
  n_raw="$(grep -c . "$raw" 2>/dev/null || echo 0)"
  n_un="$(grep -c . "$un" 2>/dev/null || echo 0)"
  n_find="$(find "$fdir" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  n_pair="$(grep -c . "$dir/judge-plan.tsv" 2>/dev/null || echo 0)"
  echo "triage: raw=$n_raw deduped=$n_find unparsed=$n_un judge-pairs=$n_pair under-judged=$short roster=$(_roster | wc -w | tr -d ' ')"
}

_usage() {
  cat <<'USAGE'
review.sh — minimal multi-model fan-out harness for code review

  fan <role> <promptfile> <dir> [participant...]      run participants in parallel (write-guarded;
                                                      no args => roster from $FUSION_REVIEW_ROSTER)
  cross-verify <verifier> <target-review> <dir> [pf]  idiot-test one review (missed + false-positive)
  triage <dir> [role]                                 parse+dedupe reviews -> findings/ + judge-plan.tsv
  judge <participant> <finding-file> <dir>            adversarially refute ONE finding; prints VERDICT
  spike <hypothesis> <dir> [participant]              reproduce a finding in a throwaway worktree
  collect <dir>                                       concat run artifacts into aggregate.md
  selftest [participant]                              smoke the harness; PASS/FAIL
  cleanup                                             remove orphan worktrees + scratch

  participant = claude[:model] | codex | grok[:model] | opencode:<model> | deepseek
USAGE
}

# _roster_json <participant...> — roster-vs-config block. The denominator must come from
# CONFIG, not from the caller: `coverage.requested` counts whatever the host passed, so a run
# of 3-out-of-7 reports `requested:3, ok:3` and reads as full coverage. Two distinct drifts are
# both observed in real runs and both caught here: `missing` (configured but not run) and
# `unconfigured` (run but never configured — an invented participant).
_roster_json() {
  local configured p c found n=0 missing="" extra=""
  configured="$(_roster)"
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
    echo "ROSTER-DRIFT: run does not match \$FUSION_REVIEW_ROSTER — see roster.missing / roster.unconfigured in $sf" >&2
  cat "$sf"
}

main() {
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    _run)         _run "$@" ;;
    fan)          cmd_fan "$@" ;;
    cross-verify) cmd_cross_verify "$@" ;;
    triage)       cmd_triage "$@" ;;
    judge)        cmd_judge "$@" ;;
    spike)        cmd_spike "$@" ;;
    collect)      cmd_collect "$@" ;;
    selftest)     cmd_selftest "$@" ;;
    cleanup)      cmd_cleanup "$@" ;;
    help|-h|--help) _usage ;;
    *) _usage >&2; exit 1 ;;
  esac
}
main "$@"
