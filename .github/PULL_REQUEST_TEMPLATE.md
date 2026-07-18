<!-- Keep the diff small and the harness mechanical. -->

**What & why**

**Checks**
- [ ] `bash -n skills/fusion-review/review.sh install.sh` passes
- [ ] `shellcheck -S error skills/fusion-review/review.sh install.sh` passes
- [ ] `review.sh selftest <provider>` passes against a provider I have
- [ ] `README.md` / `SKILL.md` updated if behavior changed
- [ ] `CHANGELOG.md` entry added under *Unreleased*
