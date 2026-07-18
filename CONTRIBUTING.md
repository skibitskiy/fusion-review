# Contributing to fusion-review

Thanks for looking. fusion-review is small on purpose — a bash harness plus a playbook. Keep changes minimal and verifiable.

## Architecture in one minute

- **`skills/fusion-review/review.sh`** — a deterministic "dumb pipe". It only runs model CLIs in parallel, captures their output, and guards the repo. No orchestration logic lives here.
- **`skills/fusion-review/SKILL.md`** — the playbook the host model (Claude Code / Codex) follows: bundle the diff, fan reviews, cross-verify for MISSED findings, judge each finding, report.

The split matters: anything stateful or "smart" goes in `SKILL.md`; `review.sh` stays mechanical and testable.

## The adapter contract

A participant is `claude[:model] | codex | grok[:model] | opencode:<model> | deepseek`. All dispatch through one place:

```sh
_run <participant> <promptfile>   # reads the prompt file, writes the model's answer to stdout
```

To **add a provider**, add one `case` arm to `_run` (and to `cmd_spike`, which needs a write-enabled invocation). Nothing else should need to know about it. Keep models configurable by env, not hardcoded.

## Artifact layout

A run writes to `runs/<ts>/`:

```
bundle.md · review/<slug>.{md,err,exit,author} · cross/<slug>-on-<author>.{md,err,exit,author} · findings/<nnn>.md · judge/<slug>-on-<nnn>.md · spikes/<slug>.md · status.json
```

`status.json` carries `write_leak`, per-participant `{exit,status}`, and a `coverage` + `roster` block. Findings and verdicts live in files, not in `status.json`. `collect` concatenates everything into `aggregate.md`.

Filenames are slugged from the participant string (`/` and `:` → `_`), but **the slug is not an identity** — it is lossy and one-way, and a cross-verify basename encodes two participants and parses back to neither. So every review/cross artifact ships a `<artifact>.author` sidecar holding the participant string verbatim (for a cross-verify artifact: the *verifier*), and `triage` reads identity from there. Any new stage that needs to know who produced an artifact must read the sidecar, never re-derive it from the filename — that inference is what once let a model judge its own finding.

## Local dev (no agent needed)

```sh
bash -n skills/fusion-review/review.sh                 # syntax
shellcheck -S error skills/fusion-review/review.sh     # lint
bash tests/triage-test.sh                              # triage behaviour (fixtures only, no network)
bash skills/fusion-review/review.sh selftest deepseek  # live smoke (needs that provider authed)
bash skills/fusion-review/review.sh --help
```

CI runs everything except the live model call on every PR. `tests/triage-test.sh` is the one that catches *behaviour*: syntax, lint and a `--help` grep were all green while `triage` was dropping findings and routing them to their own author. Any change to parsing, clustering, identity or judge routing needs a case there.

## Pull requests

- Keep the diff small and the harness mechanical.
- `bash -n`, `shellcheck -S error` and `bash tests/triage-test.sh` must pass; run `selftest` against at least one provider you have.
- Update `README.md` / `SKILL.md` if behavior changes, and add a `CHANGELOG.md` entry under *Unreleased*.
