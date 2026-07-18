#!/usr/bin/env bash
# triage-test.sh — offline regression suite for `review.sh triage`.
#
# Every case here is a bug that SHIPPED, and each one made one of the tool's own guarantees false:
# findings vanishing from both denominators, a model judging its own finding, a triage call deleting
# the previous round, counters printing embedded newlines. They shipped because triage had no test
# at all — its output is plausible-looking either way, which is exactly the shape of failure that
# needs mechanical verification rather than a read-through.
#
# Constraints: no model CLIs, no network, no writes outside a temp dir. bash 3.2 compatible
# (no `declare -A`, no `mapfile`, no GNU-only flags).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REVIEW="$SCRIPT_DIR/../skills/fusion-review/review.sh"
[ -f "$REVIEW" ] || { echo "cannot find review.sh at $REVIEW" >&2; exit 2; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/triage-test-XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

N_PASS=0; N_FAIL=0; N_SKIP=0
CASE="(none)"

_case() { CASE="$1"; }
_ok()   { printf 'PASS  %s — %s\n' "$CASE" "$1"; N_PASS=$((N_PASS+1)); }
_bad()  { printf 'FAIL  %s — %s\n        %s\n' "$CASE" "$1" "$2"; N_FAIL=$((N_FAIL+1)); }
_skip() { printf 'SKIP  %s — %s\n' "$CASE" "$1"; N_SKIP=$((N_SKIP+1)); }

# assert_eq <what> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then _ok "$1"; else _bad "$1" "expected [$2], got [$3]"; fi
}
# assert_contains <what> <haystack> <needle>
assert_contains() {
  case "$2" in *"$3"*) _ok "$1" ;; *) _bad "$1" "[$3] not found in: $2" ;; esac
}
# assert_absent <what> <haystack> <needle>
assert_absent() {
  case "$2" in *"$3"*) _bad "$1" "[$3] should NOT appear in: $2" ;; *) _ok "$1" ;; esac
}

newdir() { mktemp -d "$TMPROOT/run-XXXXXX"; }

# mkpart <dir> <role> <participant>  — review artifact + identity sidecar; body on stdin.
mkpart() {
  local d="$1" role="$2" p="$3" slug
  slug="$(printf '%s' "$p" | tr '/:' '__')"
  mkdir -p "$d/$role"
  cat >"$d/$role/$slug.md"
  printf '%s\n' "$p" >"$d/$role/$slug.author"
}

# mkcross <dir> <basename> <verifier>  — cross artifact whose FILENAME does not encode its author
# (the real harness names these '<verifier>-on-<target>'); body on stdin.
mkcross() {
  local d="$1" base="$2" verifier="$3"
  mkdir -p "$d/cross"
  cat >"$d/cross/$base.md"
  printf '%s\n' "$verifier" >"$d/cross/$base.author"
}

# triage <dir> [roles...] — stdout only (under-judged warnings go to stderr by design).
triage() { local d="$1"; shift; bash "$REVIEW" triage "$d" "$@" 2>/dev/null; }

# field <summary-line> <key> — value of key=value in the summary.
field() { printf '%s\n' "$1" | tr ' ' '\n' | awk -F= -v k="$2" '$1==k{print $2; exit}'; }

nfindings() { ls "$1"/findings/*.md 2>/dev/null | wc -l | tr -d ' '; }


# ---------------------------------------------------------------------------
_case "B1 exact repro: indented finding-shaped line vanishes from BOTH denominators"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
  [MAJOR] correctness indented.go:5 — g — p
EOF
s="$(triage "$d")"
assert_eq "raw counts the indented finding"      "1" "$(field "$s" raw)"
assert_eq "it is deduped into a finding"         "1" "$(field "$s" deduped)"
assert_eq "and it is NOT parked in unparsed"     "0" "$(field "$s" unparsed)"

_case "B1 shaped-but-broken goes to unparsed; prose is counted nowhere"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
This is prose. It mentions a bug but is not a finding.

  [MAJOR] correctness good.go:5 — g — p
  [MAJOR] correctness no-location-here — missing the file:line
* [MINOR] tests bulleted.go:9 — b — q
Another paragraph of narration that should never be a denominator.
EOF
s="$(triage "$d")"
assert_eq "two well-formed findings parsed"          "2" "$(field "$s" raw)"
assert_eq "one finding-shaped line unparsed"         "1" "$(field "$s" unparsed)"
assert_contains "unparsed holds the broken line" "$(cat "$d/unparsed.md")" "no-location-here"
assert_absent   "prose does not inflate unparsed" "$(cat "$d/unparsed.md")" "narration"


# ---------------------------------------------------------------------------
_case "B2 exact repro: cross artifact author read from sidecar, not filename"
d="$(newdir)"
mkpart  "$d" review "opencode:zai-coding-plan/glm-5.2" <<'EOF'
[MAJOR] correctness a.go:10 — gist one — proof one
EOF
mkcross "$d" "grok-on-opencode_glm" "grok-4.5" <<'EOF'
[MAJOR] correctness b.go:20 — gist two — proof two
EOF
FUSION_REVIEW_ROSTER="opencode:zai-coding-plan/glm-5.2 grok-4.5 claude" \
  bash "$REVIEW" triage "$d" >/dev/null 2>&1
src1="$(awk -F'sources: ' '/^sources: /{print $2; exit}' "$d/findings/001.md")"
src2="$(awk -F'sources: ' '/^sources: /{print $2; exit}' "$d/findings/002.md")"
assert_eq "review source is the participant STRING, not a slug" "opencode:zai-coding-plan/glm-5.2" "$src1"
assert_eq "cross source is the VERIFIER, not the filename"      "grok-4.5" "$src2"
assert_absent "grok-4.5 is not routed to judge its own finding" \
  "$(awk -F'\t' '$1=="002"{print $2}' "$d/judge-plan.tsv")" "grok-4.5"
assert_absent "glm is not routed to judge its own finding" \
  "$(awk -F'\t' '$1=="001"{print $2}' "$d/judge-plan.tsv")" "opencode:zai-coding-plan/glm-5.2"

_case "m2: exclusion compares whole entries — 'grok' must not match 'grok-4.5'"
d="$(newdir)"
mkpart "$d" review "grok-4.5" <<'EOF'
[MAJOR] correctness a.go:10 — gist — proof
EOF
FUSION_REVIEW_ROSTER="grok grok-4.5 claude" bash "$REVIEW" triage "$d" >/dev/null 2>&1
judges="$(awk -F'\t' '$1=="001"{print $2}' "$d/judge-plan.tsv" | tr '\n' ' ')"
assert_contains "sibling 'grok' IS eligible"  "$judges" "grok "
assert_contains "'claude' is eligible"        "$judges" "claude"
assert_absent   "author 'grok-4.5' excluded"  "$judges" "grok-4.5"


# ---------------------------------------------------------------------------
_case "B3 exact repro: triage must not destroy the previous round"
d="$(newdir)"
mkpart  "$d" review "claude" <<'EOF'
[MAJOR] correctness rev.go:10 — review finding — proof r
EOF
mkcross "$d" "grok-on-claude" "grok" <<'EOF'
[MAJOR] correctness cross.go:20 — cross finding — proof c
EOF
s="$(triage "$d")"
assert_eq "default processes review AND cross in one pass" "2" "$(nfindings "$d")"
assert_contains "review round survives" "$(cat "$d"/findings/*.md)" "rev.go"
assert_contains "cross round survives"  "$(cat "$d"/findings/*.md)" "cross.go"
assert_contains "summary names both roles" "$s" "roles=review cross"
s="$(triage "$d" review cross)"
assert_eq "explicit multi-role is one pass too" "2" "$(nfindings "$d")"

_case "B3: default role set works when there is no cross round"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
[MAJOR] correctness only.go:10 — g — p
EOF
s="$(triage "$d")"; rc=$?
assert_eq "exit 0 with review only" "0" "$rc"
assert_eq "one finding"             "1" "$(nfindings "$d")"
assert_contains "roles is just review" "$s" "roles=review"


# ---------------------------------------------------------------------------
_case "B4 exact repro: empty run prints clean single-integer counters"
d="$(newdir)"; mkdir -p "$d/review"
s="$(triage "$d")"
assert_eq "summary is exactly ONE line" "1" "$(printf '%s\n' "$s" | wc -l | tr -d ' ')"
if printf '%s' "$s" | grep -qE '^triage: raw=[0-9]+ deduped=[0-9]+ unparsed=[0-9]+ judge-pairs=[0-9]+ under-judged=[0-9]+ candidates=[0-9]+ roles=[a-z ]+$'; then
  _ok "every counter is a single clean integer"
else
  _bad "every counter is a single clean integer" "got: $s"
fi
assert_eq "raw=0"         "0" "$(field "$s" raw)"
assert_eq "deduped=0"     "0" "$(field "$s" deduped)"
assert_eq "unparsed=0"    "0" "$(field "$s" unparsed)"
assert_eq "judge-pairs=0" "0" "$(field "$s" judge-pairs)"


# ---------------------------------------------------------------------------
_case "M1 exact repro: '--' is content, never a separator"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
[MAJOR] correctness cli.go:7 — ignores --readonly — flag treated as path
EOF
triage "$d" >/dev/null
body="$(cat "$d/findings/001.md")"
assert_contains "gist keeps its --flag and proof is intact" "$body" \
  "[MAJOR] correctness cli.go:7 — ignores --readonly — flag treated as path"

_case "M1: proof keeps every em-dash after the second separator"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
[MINOR] maintainability x.go:3 — the gist — proof with — an em-dash — inside
EOF
triage "$d" >/dev/null
assert_contains "proof survives verbatim" "$(cat "$d/findings/001.md")" \
  "— the gist — proof with — an em-dash — inside"

_case "M1: fewer than two em-dashes is unparsed, even with '--' present"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
[MAJOR] correctness y.go:3 -- gist -- proof
[MAJOR] correctness z.go:4 — only one separator
EOF
s="$(triage "$d")"
assert_eq "no findings parsed" "0" "$(field "$s" deduped)"
assert_eq "both land in unparsed" "2" "$(field "$s" unparsed)"


# ---------------------------------------------------------------------------
_case "M2 exact repro: no roster => candidates are the observed participants"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
[MAJOR] correctness a.go:10 — gist — proof
EOF
mkpart "$d" review "codex" <<'EOF'
Nothing finding-shaped here.
EOF
s="$(env -u FUSION_REVIEW_ROSTER bash "$REVIEW" triage "$d" 2>/dev/null)"
assert_eq "candidate pool is the two observed participants" "2" "$(field "$s" candidates)"
if [ "$(field "$s" judge-pairs)" != "0" ]; then _ok "judge-plan is NOT empty"; else
  _bad "judge-plan is NOT empty" "judge-pairs=0 with participants present: $s"; fi
assert_contains "the non-author judges" "$(cat "$d/judge-plan.tsv")" "codex"
assert_absent   "the author does not judge itself" "$(awk -F'\t' '{print $2}' "$d/judge-plan.tsv")" "claude"

_case "M2: three observed participants give a full 2/2 on a single-source finding"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
[MAJOR] correctness a.go:10 — gist — proof
EOF
mkpart "$d" review "codex" <<'EOF'
prose only
EOF
mkpart "$d" review "grok" <<'EOF'
prose only
EOF
s="$(env -u FUSION_REVIEW_ROSTER bash "$REVIEW" triage "$d" 2>/dev/null)"
assert_eq "two judge pairs"  "2" "$(field "$s" judge-pairs)"
assert_eq "nothing under-judged" "0" "$(field "$s" under-judged)"


# ---------------------------------------------------------------------------
_case "M3 exact repro: clusters must not chain past the documented +/-3 window"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
[MAJOR] correctness chain.go:10 — g10 — p10
[MAJOR] correctness chain.go:13 — g13 — p13
[MAJOR] correctness chain.go:16 — g16 — p16
[MAJOR] correctness chain.go:19 — g19 — p19
[MAJOR] correctness chain.go:22 — g22 — p22
EOF
s="$(triage "$d")"
assert_eq "all five rows parsed" "5" "$(field "$s" raw)"
assert_eq "10+13 | 16+19 | 22 => three findings, not one" "3" "$(field "$s" deduped)"

_case "M3: rows within 3 of the cluster START still cluster"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
[MAJOR] correctness near.go:10 — g10 — p10
[MAJOR] correctness near.go:12 — g12 — p12
[MAJOR] correctness near.go:13 — g13 — p13
EOF
s="$(triage "$d")"
assert_eq "10,12,13 collapse into one finding" "1" "$(field "$s" deduped)"

# The brief also offered "10,13,14 cluster" as an example, which CONTRADICTS its own rule:
# 14 - 10 = 4 > 3, so 14 cannot join a cluster starting at 10. Clustering 14 there requires
# measuring from the PREVIOUS row (14-13=1) — precisely the chaining M3 exists to remove; you
# cannot have both. The rule wins, and this case pins the resulting behaviour so the ambiguity
# cannot silently flip back later.
_case "M3: the stated rule beats the stated example — 10,13,14 must SPLIT"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
[MAJOR] correctness edge.go:10 — g10 — p10
[MAJOR] correctness edge.go:13 — g13 — p13
[MAJOR] correctness edge.go:14 — g14 — p14
EOF
s="$(triage "$d")"
assert_eq "10+13 cluster, 14 starts a new one (14-10=4 > 3)" "2" "$(field "$s" deduped)"


# ---------------------------------------------------------------------------
_case "m1: range locations are accepted, first number wins"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
[MAJOR] correctness file.go:10-15 — range gist — range proof
EOF
s="$(triage "$d")"
assert_eq "parsed, not unparsed" "0" "$(field "$s" unparsed)"
assert_eq "one finding"          "1" "$(field "$s" deduped)"
assert_contains "location uses the FIRST number" "$(cat "$d/findings/001.md")" "location: file.go:10"


# ---------------------------------------------------------------------------
_case "m3: raw reports preserve each participant's proof, not just the gist"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
[MAJOR] correctness dup.go:10 — claude gist — claude proof
EOF
mkpart "$d" review "codex" <<'EOF'
[BLOCKER] correctness dup.go:11 — codex gist — codex proof
EOF
triage "$d" >/dev/null
body="$(cat "$d/findings/001.md")"
assert_eq "both reports cluster into one finding" "1" "$(nfindings "$d")"
assert_contains "claude proof preserved" "$body" "(claude) — claude gist — claude proof"
assert_contains "codex proof preserved"  "$body" "(codex) — codex gist — codex proof"
assert_contains "highest severity wins"  "$body" "severity: BLOCKER"


# ---------------------------------------------------------------------------
_case "regression guard: existing behaviour preserved"
h="$(bash "$REVIEW" --help 2>&1)"
assert_contains "--help still documents 'fan <role>'" "$h" "fan <role>"
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  d="$(newdir)"; : >"$d/p.txt"
  env -u FUSION_REVIEW_ROSTER bash "$REVIEW" fan somerole "$d/p.txt" "$d" >/dev/null 2>&1
  assert_eq "fan with no participants and no roster exits 96" "96" "$?"
else
  _skip "fan-96 check needs timeout(1)/gtimeout(1) on PATH (preflight would return 127 first)"
fi


# ---------------------------------------------------------------------------
printf '\n%s\n' "----------------------------------------"
printf 'passed=%d failed=%d skipped=%d\n' "$N_PASS" "$N_FAIL" "$N_SKIP"
[ "$N_FAIL" -eq 0 ] || exit 1
exit 0
