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
bundle.md · review/<slug>.md · cross/<slug>-on-<author>.md · findings/<nnn>.md · judge/<slug>-on-<nnn>.md · spikes/<slug>.md · status.json
```

`status.json` carries `write_leak`, per-participant `{exit,status}`, and a `coverage` + `roster` block. Findings and verdicts live in files, not in `status.json`. `collect` concatenates everything into `aggregate.md`. Filenames are slugged from the participant string (`/` and `:` → `_`).

## Local dev (no agent needed)

```sh
bash -n skills/fusion-review/review.sh                 # syntax
shellcheck -S error skills/fusion-review/review.sh     # lint
bash skills/fusion-review/review.sh selftest deepseek  # live smoke (needs that provider authed)
bash skills/fusion-review/review.sh --help
```

CI runs the first three (without the live model call) on every PR.

## Pull requests

- Keep the diff small and the harness mechanical.
- `bash -n` and `shellcheck -S error` must pass; run `selftest` against at least one provider you have.
- Update `README.md` / `SKILL.md` if behavior changes, and add a `CHANGELOG.md` entry under *Unreleased*.
