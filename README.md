# fusion

Многомодельный консенсус-планировщик. Claude, Codex и DeepSeek (или любые модели через opencode — GLM, Kimi, MiniMax…) **независимо** строят план, кросс-верифицируют друг друга («идиот-тест») и **обязаны прийти к консенсусу** по ключевым осям, прежде чем выдать план. Выход — план-документ; код fusion не трогает (реализация — отдельно, через forge/improve).

Тезис («fusion beats frontier»): ансамбль разных семейств обгоняет одну топ-модель, потому что у них разные слепые зоны.

> Статус: **v0.1**. Труба (`fan`/`cross-verify`/`collect`/`cleanup`) проверена живьём; полный цикл `/fusion` через playbook собран, но прирост против одиночной модели ещё не доказан baseline-замером (см. `docs/.../v1-implementation-plan.md`). Plan-only, batch-инструмент (≥1 ч/задача), не интерактивный.

## Как устроено

- `skills/fusion/fusion.sh` — детерминированная труба (bash + CLI-адаптеры). **Host-agnostic:** все участники зовутся одинаково CLI-вызовами, поэтому оркестратором может быть Claude Code, Codex или opencode.
- `skills/fusion/SKILL.md` — playbook цикла (draft → cross-verify → consensus-гейт → synthesize), который исполняет хост-модель.
- Участник = `claude[:model] | codex | opencode:<model> | deepseek`.

## Требования

Нужны только CLI тех моделей, что в твоём ростере:

| Участник | CLI | Проверка |
|---|---|---|
| Claude | [`claude`](https://docs.claude.com/claude-code) | `claude -p "OK"` → `OK` |
| Codex | [`codex`](https://developers.openai.com/codex/cli) | `codex exec --sandbox read-only "say OK"` |
| GLM/Kimi/DeepSeek/… | [`opencode`](https://opencode.ai) | `opencode run -m opencode-go/glm-5 "say OK"` |

`git`, `bash`, `shasum` — стандартные.

## Настройка токенов (per provider)

Fusion не хранит ключи — использует логин самих CLI:

- **Claude:** `claude` использует логин Claude Code (подписка/`ANTHROPIC_API_KEY`). Проверка: `claude -p "OK"`.
- **Codex:** `codex login` (ChatGPT-аккаунт) или `OPENAI_API_KEY`. Проверка: `codex exec "say OK"`. ⚠️ ChatGPT-план имеет квоту — при исчерпании участник выбывает в `degraded`.
- **opencode** (GLM/Kimi/DeepSeek/MiniMax): `opencode auth login` → провайдер (OpenCode Go / OpenRouter). Список моделей: `opencode models`. Проверка: `opencode run -m opencode-go/deepseek-v4-pro "say OK"`.

## Настройка моделей (env)

| Переменная | Что | Дефолт |
|---|---|---|
| `FUSION_ROSTER` | список участников | `claude codex deepseek` |
| `FUSION_MODEL_DEEPSEEK` | модель для алиаса `deepseek` | `opencode-go/deepseek-v4-pro` |
| `FUSION_MODEL_CLAUDE` | модель для `claude` (`--model`) | (дефолт CLI) |
| `FUSION_TIMEOUT` | таймаут на вызов, сек | `300` |
| `FUSION_GUARD_REPO` | репо, чьи изменения стережёт write-guard | `$PWD` |
| `FUSION_SCRATCH` | scratch для записей моделей | `/tmp/fusion-scratch` |

**Ростеры:**
```bash
FUSION_ROSTER="claude codex deepseek"                                                   # mixed (default)
FUSION_ROSTER="opencode:opencode-go/glm-5 opencode:opencode-go/kimi-k2.7-code opencode:opencode-go/deepseek-v4-pro"  # opencode-only
```

## Установка (per host)

Скилл — это папка `skills/fusion/` в формате [Agent Skills](https://agentskills.io). Поставь её туда, где хост ищет скиллы:

**Claude Code:**
```bash
ln -s "$PWD/skills/fusion" ~/.claude/skills/fusion      # затем /fusion в сессии
# или как плагин: добавить репозиторий через plugin-маркетплейс
```

**Codex:**
```bash
ln -s "$PWD/skills/fusion" ~/.codex/skills/fusion       # Codex читает ~/.codex/skills/<name>/SKILL.md
```

**opencode (как оркестратор):**
opencode исполняет тот же `SKILL.md` как инструкцию (`opencode run "follow skills/fusion/SKILL.md for: <task>"`). Менее стандартно, но труба та же.

> Операторское интервью на развилке: в Claude Code — `AskUserQuestion`; в Codex/opencode — обычный вопрос текстом. Это единственное место, зависящее от хоста.

## Использование

```
/fusion <task> --dir <target-repo> [--depth lite|full]
```

Хост следует `SKILL.md`: собирает сырой бриф → `fan` (все участники параллельно, write-guard) → `cross-verify` (ротация) → консенсус-гейт по structured-votes → `synthesize`. Артефакты — в `<target>/.fusion/runs/<ts>/` (`*-plan.md` + `*-debate.md`).

Прямой вызов трубы (без хоста):
```bash
bash skills/fusion/fusion.sh fan draft prompt.txt .fusion/runs/r1 claude codex deepseek
bash skills/fusion/fusion.sh cross-verify codex .fusion/runs/r1/draft/codex.md .fusion/runs/r1
bash skills/fusion/fusion.sh collect .fusion/runs/r1
```

## Инварианты

- **Жёсткий консенсус-гейт:** план не эмитится, пока все доступные участники не согласны по material-осям. Большинство не перебивает несогласного; тай разбивает оператор (`decision: operator_decision ≠ consensus`).
- **Write-изоляция:** `fan` стережёт target-репо (`git status` до/после); мутация → `write_leak:true`, стоп.
- **`<2` семейств → `degraded`,** не выдаётся за fusion.

## Не делает

Не исполняет код (кроме спайков) · не правит репо · не роутит на одну модель · не хранит секреты. Полный список ограничений и дизайн — в `docs/superpowers/specs/`.
