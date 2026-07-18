#!/usr/bin/env bash
# Install the fusion-review skill for your coding agent. Idempotent: safe to re-run.
# Detects Claude Code and/or Codex and links the skill into their skills dir.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_SRC="$HERE/skills/fusion-review"
[ -d "$SKILL_SRC" ] || { echo "error: $SKILL_SRC not found (run from the repo root)"; exit 1; }

link() {  # link <skills-dir> <host-label> <invoke-hint>
  mkdir -p "$1"
  ln -sfn "$SKILL_SRC" "$1/fusion-review"
  echo "  ✓ $2: linked $1/fusion-review   $3"
}

echo "Installing fusion-review skill…"
installed=0
if [ -d "$HOME/.claude" ] || command -v claude >/dev/null 2>&1; then
  link "$HOME/.claude/skills" "Claude Code" "→ run /fusion-review in a session"; installed=1
fi
if [ -d "$HOME/.codex" ] || command -v codex >/dev/null 2>&1; then
  link "$HOME/.codex/skills" "Codex" "→ Codex reads ~/.codex/skills/fusion-review/SKILL.md"; installed=1
fi
if [ "$installed" -eq 0 ]; then
  echo "  ! No Claude Code or Codex host detected — skill not linked."
  echo "    You can still drive the harness directly:  bash skills/fusion-review/review.sh --help"
  echo "    (e.g. an opencode-only roster needs no host skill dir.)"
fi

echo
echo "Model CLIs (install only the ones in your roster):"
for c in claude codex grok opencode; do
  if command -v "$c" >/dev/null 2>&1; then echo "  ✓ $c"; else echo "  – $c  (optional)"; fi
done

echo
echo "Next:"
echo "  1. Authenticate the providers you'll use (README → Requirements & providers)."
echo "  2. Set a roster — there is NO default, and no fallback to the planner's \$FUSION_ROSTER."
echo "     Unset ⇒ 'fan' refuses to run (exit 96), so a forgotten variable costs an error, not a bill."
echo "     e.g.  export FUSION_REVIEW_ROSTER=\"grok opencode:zai-coding-plan/glm-5.2\""
echo "  3. Run:  /fusion-review --dir <repo>       (or: bash skills/fusion-review/review.sh --help)"
