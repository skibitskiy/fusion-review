#!/usr/bin/env bash
# fusion.sh — minimal multi-model fan-out harness (v1 spike).
# Dumb pipe: fan / cross-verify / collect / cleanup. Claude (orchestrator) lives outside this script.
# ponytail: status.json built with printf, not jq — fine for v1; switch to jq if it grows.
set -uo pipefail

RUN_ROOT="${FUSION_RUN_ROOT:-.fusion/runs}"
TIMEOUT="${FUSION_TIMEOUT:-300}"

# --- adapters: read prompt from file $1, answer to stdout. Grounded in 2026-06-15 spike. ---
_run() {
  local model="$1" pfile="$2"
  case "$model" in
    codex)    codex exec --sandbox read-only "$(cat "$pfile")" ;;
    deepseek) opencode run --pure --dir "${FUSION_SCRATCH:-/tmp/fusion-scratch}" \
                -m opencode-go/deepseek-v4-pro "$(cat "$pfile")" ;;
    *) echo "unknown model: $model" >&2; return 99 ;;
  esac
}

# fan <role> <promptfile> <run-dir> <model...>  — parallel, capture stdout + exit per model
cmd_fan() {
  local role="$1" prompt="$2" dir="$3"; shift 3
  mkdir -p "$dir/$role" "${FUSION_SCRATCH:-/tmp/fusion-scratch}"
  local m
  for m in "$@"; do
    ( timeout "$TIMEOUT" bash "$0" _run "$m" "$prompt" \
        >"$dir/$role/$m.md" 2>"$dir/$role/$m.err"
      echo "$?" >"$dir/$role/$m.exit" ) &
  done
  wait
  _status "$dir" "$role" "$@"
}

# cross-verify <verifier> <target-plan-file> <run-dir> — idiot-test one plan with one model
cmd_cross_verify() {
  local verifier="$1" target="$2" dir="$3"
  mkdir -p "$dir/cross"
  local base; base="$(basename "$target" .md)"
  local pf="$dir/cross/prompt-$verifier-on-$base.txt"
  {
    echo "Ты — кросс-верификатор. Автор плана ниже НЕКОМПЕТЕНТЕН: перепроверь ИНСТРУМЕНТАЛЬНО каждое"
    echo "утверждение, источник, довод, вывод (grep/read/контрпример, а не «перечитал и согласен»)."
    echo "Выдай [BLOCKER/MAJOR/MINOR]+суть+пруф. В конце: ship/revise/rethink. --- ПЛАН: ---"
    cat "$target"
  } >"$pf"
  ( timeout "$TIMEOUT" bash "$0" _run "$verifier" "$pf" \
      >"$dir/cross/$verifier-on-$base.md" 2>"$dir/cross/$verifier-on-$base.err"
    echo "$?" >"$dir/cross/$verifier-on-$base.exit" )
}

# collect <run-dir> — concat all artifacts into aggregate.md
cmd_collect() {
  local dir="$1" out="$1/aggregate.md"
  { echo "# Aggregate — $dir"; echo
    local f
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
  rm -rf "${FUSION_SCRATCH:-/tmp/fusion-scratch}" 2>/dev/null || true
  echo "cleanup done"
}

# _status <dir> <role> <model...> — write status.json with exit codes
_status() {
  local dir="$1" role="$2"; shift 2
  local sf="$dir/status.json" m ex st first=1
  { printf '{"run_dir":"%s","role":"%s","participants":{' "$dir" "$role"
    for m in "$@"; do
      ex="$(cat "$dir/$role/$m.exit" 2>/dev/null || echo 99)"
      case "$ex" in 0) st=ok ;; 124) st=timeout ;; *) st=error ;; esac
      [ $first -eq 1 ] || printf ','; first=0
      printf '"%s":{"exit":%s,"status":"%s"}' "$m" "$ex" "$st"
    done
    printf '}}'
  } >"$sf"
  cat "$sf"
}

main() {
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    _run)         _run "$@" ;;
    fan)          cmd_fan "$@" ;;
    cross-verify) cmd_cross_verify "$@" ;;
    collect)      cmd_collect "$@" ;;
    cleanup)      cmd_cleanup "$@" ;;
    *) echo "usage: fusion.sh {fan <role> <promptfile> <dir> <model...>|cross-verify <verifier> <target> <dir>|collect <dir>|cleanup}" >&2; exit 1 ;;
  esac
}
main "$@"
