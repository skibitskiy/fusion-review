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

# judges_of <dir> <finding-id> — the judge set for one finding, sorted, space-joined.
# Sorted+exact so a case can assert what the plan IS, not merely what it lacks. `assert_absent`
# alone is satisfied by an EMPTY plan, which is how the flagship no-self-judging case (B2) came to
# pass against a judge-plan.tsv that routed nothing at all.
judges_of() {
  awk -F'\t' -v id="$2" '$1==id{print $2}' "$1/judge-plan.tsv" 2>/dev/null \
    | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//'
}


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
# POSITIVE, EXACT assertions. This case used to assert only that each author was ABSENT from its
# own finding's judges — which an entirely empty judge-plan.tsv satisfies, so the guarantee the
# case is named after was untested inside it. Assert the judge set EQUALS the expected non-author
# set: that fails both when an author sneaks in AND when nobody is routed at all.
assert_eq "001's judges are exactly the two non-authors" \
  "claude grok-4.5" "$(judges_of "$d" 001)"
assert_eq "002's judges are exactly the two non-authors" \
  "claude opencode:zai-coding-plan/glm-5.2" "$(judges_of "$d" 002)"

_case "m2: exclusion compares whole entries — 'grok' must not match 'grok-4.5'"
d="$(newdir)"
mkpart "$d" review "grok-4.5" <<'EOF'
[MAJOR] correctness a.go:10 — gist — proof
EOF
FUSION_REVIEW_ROSTER="grok grok-4.5 claude" bash "$REVIEW" triage "$d" >/dev/null 2>&1
# Exact set: 'grok' and 'claude' are the two non-authors, and the plan must contain precisely them.
assert_eq "judges are exactly {claude, grok}, author 'grok-4.5' excluded" \
  "claude grok" "$(judges_of "$d" 001)"


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
if printf '%s' "$s" | grep -qE '^triage: raw=[0-9]+ deduped=[0-9]+ unparsed=[0-9]+ judge-pairs=[0-9]+ under-judged=[0-9]+ co-discovered=[0-9]+ candidates=[0-9]+ excluded=[0-9]+ roles=[a-z ]+$'; then
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
assert_eq "the sole non-author is routed, and only it" "codex" "$(judges_of "$d" 001)"

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
assert_eq "and they are exactly the two non-authors" "codex grok" "$(judges_of "$d" 001)"


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
# ROUND 2 — every case below is a defect round 1 either introduced or left enforceable only by
# convention. Two of them (R1, R2) are verbatim repros the round-2 review reproduced by hand.
# ---------------------------------------------------------------------------

# R1: the `.author` basename fallback reinstated the self-judging bug it was added to kill.
# A cross artifact named '<verifier>-on-<target>' has NO participant in its basename — it has two,
# fused. Falling back to it yielded `sources: grok-on-claude_opus`, matching no roster entry, so
# author-exclusion excluded nobody and BOTH grok and claude:opus were routed to judge it.
_case "R1 exact repro: a missing .author sidecar FAILS LOUDLY, it does not guess an identity"
d="$(newdir)"; mkdir -p "$d/cross"
cat >"$d/cross/grok-on-claude_opus.md" <<'EOF'
[MAJOR] correctness a.go:10 — gist — proof
EOF
out="$(FUSION_REVIEW_ROSTER="grok claude:opus codex" bash "$REVIEW" triage "$d" cross 2>&1)"; rc=$?
assert_eq "triage exits non-zero (93), it does not proceed on a guess" "93" "$rc"
assert_contains "the message names the offending file" "$out" "grok-on-claude_opus.md"
assert_contains "the message names the missing sidecar" "$out" ".author"
assert_contains "and tells the user how to fix it" "$out" "fan"
if [ ! -f "$d/judge-plan.tsv" ]; then _ok "no judge plan is produced from a guessed identity"; else
  _bad "no judge plan is produced from a guessed identity" \
    "judge-plan.tsv exists: $(cat "$d/judge-plan.tsv")"; fi

_case "R1: the refusal happens BEFORE findings/ is rebuilt, so a good prior triage survives"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
[MAJOR] correctness good.go:5 — g — p
EOF
FUSION_REVIEW_ROSTER="claude codex grok" bash "$REVIEW" triage "$d" review >/dev/null 2>&1
assert_eq "a clean triage first" "1" "$(nfindings "$d")"
# Now drop in a sidecar-less artifact and re-triage: it must fail WITHOUT destroying the good run.
printf '[MAJOR] correctness orphan.go:9 — g — p\n' >"$d/review/orphan.md"
FUSION_REVIEW_ROSTER="claude codex grok" bash "$REVIEW" triage "$d" review >/dev/null 2>&1
assert_eq "it refuses (93)" "93" "$?"
assert_eq "and the previous findings/ is still intact" "1" "$(nfindings "$d")"
assert_contains "with the earlier finding still in it" "$(cat "$d"/findings/*.md)" "good.go:5"

_case "R1: an EMPTY sidecar is treated as missing, not as an empty identity"
d="$(newdir)"; mkdir -p "$d/review"
printf '[MAJOR] correctness a.go:5 — g — p\n' >"$d/review/x.md"
: >"$d/review/x.author"
FUSION_REVIEW_ROSTER="claude codex" bash "$REVIEW" triage "$d" review >/dev/null 2>&1
assert_eq "empty sidecar => exit 93" "93" "$?"

_case "R1: a sidecar present => the SAME artifact triages normally (the fix is not a blanket refusal)"
d="$(newdir)"
mkcross "$d" "grok-on-claude_opus" "grok" <<'EOF'
[MAJOR] correctness a.go:10 — gist — proof
EOF
s="$(FUSION_REVIEW_ROSTER="grok claude:opus codex" bash "$REVIEW" triage "$d" cross 2>/dev/null)"; rc=$?
assert_eq "exit 0"     "0" "$rc"
assert_eq "one finding" "1" "$(field "$s" deduped)"
assert_eq "source is the verifier alone" "grok" \
  "$(awk -F'sources: ' '/^sources: /{print $2; exit}' "$d/findings/001.md")"
assert_eq "judges are exactly the two non-authors — grok is NOT among them" \
  "claude:opus codex" "$(judges_of "$d" 001)"


# R2: models emit markdown. Round 1 stripped leading whitespace and -/* bullets only, so a bold,
# numbered or blockquoted finding matched neither the shape test nor unparsed — it vanished from
# BOTH denominators, which is the one failure this tool cannot have.
_case "R2 exact repro: decorated finding lines reach the denominators"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
**[MAJOR] correctness bold.go:5 — суть — пруф**
1. [MAJOR] correctness num.go:6 — суть — пруф
> [MAJOR] correctness quote.go:7 — суть — пруф
[MAJOR] correctness plain.go:8 — суть — пруф
EOF
s="$(triage "$d")"
assert_eq "all FOUR lines are raw findings (was raw=1)" "4" "$(field "$s" raw)"
assert_eq "all four dedupe to four findings"            "4" "$(field "$s" deduped)"
assert_eq "none silently unparsed"                      "0" "$(field "$s" unparsed)"
locs="$(grep -h '^location:' "$d"/findings/*.md | LC_ALL=C sort | tr '\n' ' ')"
assert_contains "bold survives"       "$locs" "bold.go:5"
assert_contains "numbered survives"   "$locs" "num.go:6"
assert_contains "blockquoted survives" "$locs" "quote.go:7"
assert_contains "plain still survives" "$locs" "plain.go:8"

_case "R2: one case per decoration form, incl. combined and trailing emphasis"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
__[MAJOR] correctness under.go:5 — g — p__
*[MAJOR] correctness ital.go:15 — g — p*
_[MAJOR] correctness uital.go:25 — g — p_
+ [MAJOR] correctness plus.go:35 — g — p
1) [MAJOR] correctness paren.go:45 — g — p
> > [MAJOR] correctness nested.go:55 — g — p
- **[MAJOR] correctness combo.go:65 — g — p**
>   - [MAJOR] correctness deep.go:75 — g — p
EOF
s="$(triage "$d")"
assert_eq "every decoration form parses"  "8" "$(field "$s" raw)"
assert_eq "eight distinct findings"       "8" "$(field "$s" deduped)"
assert_eq "nothing unparsed"              "0" "$(field "$s" unparsed)"
assert_contains "trailing emphasis is stripped from the proof, not kept" \
  "$(cat "$d"/findings/*.md)" "— g — p"
assert_absent "no stray emphasis leaked into a proof" \
  "$(grep -h '^\[' "$d"/findings/*.md)" "p__"

# Emphasis is PAIRED: an undecorated finding whose proof legitimately ends in an emphasis char must
# keep it. Stripping trailing emphasis unconditionally would rewrite the identifier a proof names.
_case "R2: trailing emphasis is only stripped when the line was actually emphasised"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
[MAJOR] correctness ident.go:5 — g — caller passes buf_
[MAJOR] correctness star.go:15 — g — deref of p*
**[MAJOR] correctness wrapped.go:25 — g — genuinely bold**
EOF
s="$(triage "$d")"
assert_eq "all three parse" "3" "$(field "$s" raw)"
body="$(cat "$d"/findings/*.md)"
assert_contains "an undecorated proof keeps its trailing underscore" "$body" "caller passes buf_"
assert_contains "an undecorated proof keeps its trailing asterisk"   "$body" "deref of p*"
assert_contains "a genuinely bold line loses its wrapper"            "$body" "— genuinely bold"
assert_absent   "and does not keep the closing **"                   "$body" "genuinely bold**"

_case "R2: decoration does NOT rescue a broken finding — it still lands in unparsed"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
**[MAJOR] correctness no-location-here — missing the file:line**
> 1. [MAJOR] correctness ok.go:5 — g — p
**This is bold prose, not a finding at all.**
EOF
s="$(triage "$d")"
assert_eq "the good one parses"                 "1" "$(field "$s" deduped)"
assert_eq "the shaped-but-broken one is unparsed" "1" "$(field "$s" unparsed)"
assert_contains "unparsed holds the UNDECORATED line" "$(cat "$d/unparsed.md")" "[MAJOR] correctness no-location-here"
assert_absent "bold prose still inflates nothing" "$(cat "$d/unparsed.md")" "bold prose"


# R3: judge-plan.tsv is advisory unless the point of use enforces it.
#
# NOTE ON PARTICIPANT NAMES IN THIS SECTION: every name here is a kind `_run` does not know, so it
# is rejected by _run's own dispatch (exit 99) and NO model CLI can ever be invoked. That is
# deliberate and load-bearing. Using a real name like `claude` would make these tests FAIL-UNSAFE:
# they pass today only because the refusal fires before dispatch, so the day the refusal regresses
# — the exact day the test must fail — it would instead shell out to a live model, bill the user,
# and hang the suite for $FUSION_TIMEOUT. A test for a guard must not depend on the guard to stay
# offline. The membership logic under test is name-agnostic.
_case "R3: judge REFUSES a participant that is a source of the finding"
d="$(newdir)"
mkpart "$d" review "notakind" <<'EOF'
[MAJOR] correctness a.go:10 — gist — proof
EOF
FUSION_REVIEW_ROSTER="notakind notakind-b notakind-c" bash "$REVIEW" triage "$d" >/dev/null 2>&1
out="$(bash "$REVIEW" judge notakind "$d/findings/001.md" "$d" 2>&1)"; rc=$?
assert_eq "distinct non-zero exit (92)" "92" "$rc"
assert_contains "the refusal names the participant" "$out" "notakind"
assert_contains "the refusal explains why"          "$out" "REFUSED"
assert_contains "and points at the judge plan"      "$out" "judge-plan.tsv"
if [ ! -f "$d/judge/notakind-on-001.md" ]; then _ok "no judge artifact is produced"; else
  _bad "no judge artifact is produced" "judge/notakind-on-001.md exists"; fi

_case "R3: exclusion is whole-entry — a NON-source with a shared prefix is not refused"
d="$(newdir)"
mkpart "$d" review "notakind-4.5" <<'EOF'
[MAJOR] correctness a.go:10 — gist — proof
EOF
FUSION_REVIEW_ROSTER="notakind-4.5 notakind other" bash "$REVIEW" triage "$d" >/dev/null 2>&1
bash "$REVIEW" judge notakind-4.5 "$d/findings/001.md" "$d" >/dev/null 2>&1
assert_eq "the author 'notakind-4.5' is refused" "92" "$?"
# 'notakind' merely shares a prefix with the author; it is a DIFFERENT participant and must not be
# refused. It goes on to fail at dispatch (exit 99, no CLI), so assert only that it is not 92.
bash "$REVIEW" judge notakind "$d/findings/001.md" "$d" >/dev/null 2>&1; rc=$?
if [ "$rc" != "92" ]; then _ok "sibling 'notakind' is NOT refused as an author"; else
  _bad "sibling 'notakind' is NOT refused as an author" "got exit 92"; fi

_case "R3: judging a file with no sources: header is not refused (judge stays general-purpose)"
d="$(newdir)"; mkdir -p "$d/x"
printf 'just some text, no sources header\n' >"$d/x/plain.md"
bash "$REVIEW" judge notakind "$d/x/plain.md" "$d" >/dev/null 2>&1
if [ "$?" != "92" ]; then _ok "no sources header => no refusal"; else
  _bad "no sources header => no refusal" "got exit 92"; fi


# R4/R5: co-discovery is the ensemble's BEST case; round 1 reported it as `under-judged`, i.e.
# identically to its WORST case (roster too small). One number cannot mean both.
_case "R4: sources covering every candidate => co-discovered, NOT under-judged"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
[MAJOR] correctness a.go:10 — claude gist — claude proof
EOF
mkpart "$d" review "codex" <<'EOF'
[MAJOR] correctness a.go:10 — codex gist — codex proof
EOF
s="$(env FUSION_REVIEW_ROSTER="claude codex" bash "$REVIEW" triage "$d" 2>/dev/null)"
assert_eq "one clustered finding"        "1" "$(field "$s" deduped)"
assert_eq "counted as co-discovered"     "1" "$(field "$s" co-discovered)"
assert_eq "and NOT as under-judged"      "0" "$(field "$s" under-judged)"
assert_eq "no judges are routed"         "0" "$(field "$s" judge-pairs)"
assert_contains "the finding file is labelled" "$(cat "$d/findings/001.md")" "judged: co-discovered"

_case "R4: under-judged means ONLY 'roster too small' — a co-discovered run does not inflate it"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
[MAJOR] correctness both.go:10 — g — p
[MAJOR] correctness solo.go:10 — g — p
EOF
mkpart "$d" review "codex" <<'EOF'
[MAJOR] correctness both.go:10 — g — p
EOF
# Roster of 3: 'both.go' is found by 2 of 3 (one judge left => under-judged), 'solo.go' by 1 of 3
# (two judges => fully judged). Neither is co-discovered.
s="$(env FUSION_REVIEW_ROSTER="claude codex grok" bash "$REVIEW" triage "$d" 2>/dev/null)"
assert_eq "two findings"          "2" "$(field "$s" deduped)"
assert_eq "nothing co-discovered" "0" "$(field "$s" co-discovered)"
assert_eq "one under-judged"      "1" "$(field "$s" under-judged)"

_case "R4: a pool of ONE is a small roster, not co-discovery"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
[MAJOR] correctness a.go:10 — g — p
EOF
s="$(env FUSION_REVIEW_ROSTER="claude" bash "$REVIEW" triage "$d" 2>/dev/null)"
assert_eq "candidates=1"              "1" "$(field "$s" candidates)"
assert_eq "NOT labelled co-discovered" "0" "$(field "$s" co-discovered)"
assert_eq "it is under-judged"         "1" "$(field "$s" under-judged)"
assert_absent "and the finding file carries no co-discovered label" \
  "$(cat "$d/findings/001.md")" "co-discovered"


# R7: a repeated role walked the same directory twice and doubled every denominator.
_case "R7: a repeated role is deduped, not counted twice"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
[MAJOR] correctness a.go:10 — g — p
[MINOR] tests b.go:20 — g — p
EOF
s1="$(triage "$d" review)"
s2="$(triage "$d" review review)"
assert_eq "raw is not doubled"     "$(field "$s1" raw)"     "$(field "$s2" raw)"
assert_eq "deduped is not doubled" "$(field "$s1" deduped)" "$(field "$s2" deduped)"
assert_eq "raw is 2, not 4"        "2" "$(field "$s2" raw)"
assert_contains "roles names it once" "$s2" "roles=review"
s3="$(triage "$d" review review cross 2>/dev/null || triage "$d" review review)"
assert_eq "dedupe preserves order and the rest of the list" "2" "$(field "$s3" raw)"


# R10: the judge pool must reflect who actually ANSWERED, not who was configured. Observed live:
# a participant that timed out during `fan` was still assigned as judge in 10 of 16 pairs, and
# every one of those judgements timed out too.
_case "R10: participants that failed this round are excluded from the judge pool"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
[MAJOR] correctness a.go:10 — g — p
EOF
cat >"$d/status.json" <<'EOF'
{"run_dir":"x","role":"review","write_leak":false,"participants":{"claude":{"exit":0,"status":"ok"},"codex":{"exit":0,"status":"ok"},"opencode:zai-coding-plan/glm-5.2":{"exit":124,"status":"timeout"}},"coverage":{"requested":3,"ok":2,"timeout":1,"error":0,"degraded":false},"roster":{"configured":3,"matches_config":true,"missing":[],"unconfigured":[]}}
EOF
s="$(env FUSION_REVIEW_ROSTER="claude codex opencode:zai-coding-plan/glm-5.2" \
      bash "$REVIEW" triage "$d" 2>/dev/null)"
assert_eq "the timed-out participant is dropped from the pool" "2" "$(field "$s" candidates)"
assert_eq "and the shrink is legible in the summary"           "1" "$(field "$s" excluded)"
assert_eq "only the surviving non-author judges are routed" "codex" "$(judges_of "$d" 001)"
assert_absent "the failed participant is never routed" \
  "$(cat "$d/judge-plan.tsv")" "glm-5.2"

_case "R10: the exclusion is NAMED on stderr, never a silent shrink"
err="$(env FUSION_REVIEW_ROSTER="claude codex opencode:zai-coding-plan/glm-5.2" \
        bash "$REVIEW" triage "$d" 2>&1 >/dev/null)"
assert_contains "stderr names the excluded participant" "$err" "opencode:zai-coding-plan/glm-5.2"
assert_contains "and says why"                          "$err" "status.json"

_case "R10: an all-ok status.json excludes nobody; an absent one is not treated as failure"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
[MAJOR] correctness a.go:10 — g — p
EOF
cat >"$d/status.json" <<'EOF'
{"participants":{"claude":{"exit":0,"status":"ok"},"codex":{"exit":0,"status":"ok"}},"coverage":{"requested":2,"ok":2}}
EOF
s="$(env FUSION_REVIEW_ROSTER="claude codex" bash "$REVIEW" triage "$d" 2>/dev/null)"
assert_eq "all-ok excludes nobody" "0" "$(field "$s" excluded)"
assert_eq "pool intact"            "2" "$(field "$s" candidates)"
rm -f "$d/status.json"
s="$(env FUSION_REVIEW_ROSTER="claude codex" bash "$REVIEW" triage "$d" 2>/dev/null)"
assert_eq "no status.json => no exclusions" "0" "$(field "$s" excluded)"
assert_eq "pool still intact"               "2" "$(field "$s" candidates)"

_case "R10: a participant absent from status.json is unknown, not failed"
d="$(newdir)"
mkpart "$d" review "claude" <<'EOF'
[MAJOR] correctness a.go:10 — g — p
EOF
cat >"$d/status.json" <<'EOF'
{"participants":{"claude":{"exit":0,"status":"ok"}},"coverage":{"requested":1,"ok":1}}
EOF
s="$(env FUSION_REVIEW_ROSTER="claude codex grok" bash "$REVIEW" triage "$d" 2>/dev/null)"
assert_eq "codex and grok are unknown, so the pool keeps them" "3" "$(field "$s" candidates)"
assert_eq "nothing excluded" "0" "$(field "$s" excluded)"


# R9: identity moved into the sidecar, so a seal that covers only the .md leaves the answer to
# "who wrote this" rewritable after sealing — a strictly worse tamper than editing the prose.
_case "R9: the seal covers .author sidecars, not just .md drafts"
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  d="$(newdir)"; : >"$d/p.txt"
  # 'notakind' is rejected by _run's own dispatch (exit 99) — no model CLI is ever invoked.
  FUSION_GUARD_REPO="$d" bash "$REVIEW" fan review "$d/p.txt" "$d" notakind >/dev/null 2>&1
  man="$(cat "$d/review/SEALED.manifest" 2>/dev/null)"
  assert_contains "the draft is in the manifest"   "$man" "notakind.md"
  assert_contains "the SIDECAR is in the manifest" "$man" "notakind.author"
  if [ -f "$d/review/notakind.author" ] && [ ! -w "$d/review/notakind.author" ]; then
    _ok "the sidecar is chmod a-w like the draft"
  else
    _bad "the sidecar is chmod a-w like the draft" \
      "$(ls -l "$d/review/notakind.author" 2>&1)"
  fi
else
  _skip "seal check needs timeout(1)/gtimeout(1) on PATH (preflight would return 127 first)"
fi


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
