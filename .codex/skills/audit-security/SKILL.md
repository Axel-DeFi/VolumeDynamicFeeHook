---
name: audit-security
description: Комплексный аудит безопасности Solidity-проектов с итоговым отчетом в Markdown без автоматических исправлений. Используй, когда нужно регулярно проверять контракт, автомат состояний, административные сценарии, логику комиссий, инварианты, документацию и готовность к запуску после изменений или перед релизом.
---

# Audit Security

## Назначение

Проводи один целостный проход по безопасности и корректности.

Результат работы:
- только отчет в `Markdown`
- без автоматических исправлений
- без коммитов с кодовыми правками
- без побочных рефакторингов

Если по ходу проверки обнаружена проблема, зафиксируй ее в отчете как подтвержденную находку, но не исправляй ее в этом режиме.

## Источник истины

Всегда начинай с этих материалов:
- `README.md`
- `docs/SPEC.md`
- NatSpec в контрактах
- релевантные тесты
- релевантные `RUNBOOK`
- текущая логика конфигурации контроллера

Не начинай со сгенерированных артефактов, кэшей и старых выгрузок, если задача не касается именно их.

## Режим работы

1. Сначала локализуй scope.
2. Зафиксируй ревизию, ветку и состояние рабочего дерева.
3. Если дерево грязное или в репозитории работают несколько человек, не трогай чужие изменения.
4. При риске помех используй отдельное `git worktree`.
5. Не вноси правки в код, тесты, конфиги, документацию и `RUNBOOK`.
6. Создавай только итоговый отчет.

## Выходной артефакт

По умолчанию создавай отчет сюда:

```text
docs/audit/audit-report-<scope>-<YYYY-MM-DDTHH-MM>.md
```

Где:
- `<scope>` — короткий slug области проверки
- дата и время — локальные для текущей среды

За основу бери шаблон:

```text
.codex/skills/audit-security/assets/report-template.md
```

Если пользователь явно указал другой путь, следуй указанию пользователя.

Не перезаписывай существующие отчеты.

Создавай новый файл с новым timestamp.

## Порядок проверки

### 1. Карта поверхности

Определи:
- основные контракты и библиотеки
- state machine и переходы
- точки записи привилегированного состояния
- fee paths
- ownership и admin flows
- паузы, аварийные сценарии и timelock-механики
- точки наблюдаемости
  - события
  - reason codes
  - debug accessors
- документацию и операционные допущения

### 2. Базовая сборка и тесты

Сначала выполни:

```bash
forge build
```

Дальше выбирай объем проверки по измененному риску.

Для узкого локального изменения:

```bash
forge test --match-path <path>
forge test --match-contract <name>
forge test --match-test <name>
```

Для репозиторного security review, для изменений в hook, access control, shared logic, fee logic, state machine или перед релизом используй полный прогон Foundry:

```bash
FOUNDRY_PROFILE=ops NO_PROXY='*' forge test
```

Если нужных harness или тестов нет, зафиксируй этот пробел в отчете.

### 3. Инварианты Foundry

Проверь, есть ли в проекте meaningful invariant coverage.

Для этого репозитория ориентируйся на:
- `ops/tests/invariant/`
- `invariant_` свойства
- handler-based stateful sequences

Сфокусируйся на:
- допустимых значениях mode
- соответствии fee текущему mode
- bounded counters
- monotonic `periodStart`
- корректности gap catch-up
- невозможности bypass для ordinary downward paths
- консистентности admin и timelock состояния

Если инварианты отсутствуют или покрывают только часть поведения, явно укажи это как coverage gap.

### 4. Символическая проверка

Используй:
- `Halmos`

Для этого репозитория базовый запуск:

```bash
halmos --root . --contract VolumeDynamicFeeHookCheckTest --solver-timeout-assertion 20s --loop 2 --no-status --statistics
```

Проверь минимум:
- mode и fee не расходятся
- hold блокирует ordinary downward transitions
- emergency reset ведет к `FLOOR` только по emergency path
- idle reset очищает runtime state
- ordinary downward transitions требуют нужные confirms
- transitions не портят counters и streaks
- admin updates не создают невозможное состояние

Если вводишь bounds, перечисли их явно в отчете.

### 5. Stateful fuzzing

Используй:
- `Echidna`

Для этого репозитория базовый запуск:

```bash
echidna ops/tests/echidna/VolumeDynamicFeeHook.Echidna.sol --contract VolumeDynamicFeeHookEchidnaHarness --config ops/tests/echidna/VolumeDynamicFeeHook.yaml --format text --workers 1 --disable-slither
```

Проверь:
- длинные последовательности swap и close
- gap и catch-up поведение
- входы и выходы из `CASH` и `EXTREME`
- emergency и idle reset edge cases
- pause interactions
- scheduling и execution административных действий

Если harness нет или он слабый, укажи это как verification gap.

### 6. Статический анализ

Используй:
- `Slither`

Для этого репозитория запуск только с repo-local конфигом:

```bash
slither src/VolumeDynamicFeeHook.sol --config-file ops/shared/slither/slither.config.json
```

При необходимости добавляй принтеры:

```bash
slither src/VolumeDynamicFeeHook.sol --config-file ops/shared/slither/slither.config.json --print human-summary,contract-summary,entry-points,vars-and-auth,call-graph
```

Для каждого релевантного сигнала классифицируй:
- real issue
- acceptable
- false positive
- needs verification

Не переноси detector output в findings без проверки по исходникам.

### 7. Дополнительные инструменты

Используй только если это дает новый сигнал, а не дублирует уже проверенное:
- `Aderyn`
- `Medusa`

Если не запускал, напиши почему.

### 8. Ручной разбор

Обязательно проверь вручную:
- repeated close loop semantics
- zero-volume paths
- precedence emergency reset против ordinary downward logic
- decrement behavior у hold
- interaction между `EXTREME` exit и emergency floor
- ownership и pending ownership flow
- lifecycle для scheduled fee changes
- pause и unpause behavior
- event correctness
- места, где возможно stale mode или stale fee
- соответствие документации фактическому поведению

## Правила подтверждения находок

Подтвержденной находкой считай только то, что выполняет все условия:
- есть конкретный источник
- есть воспроизводимый путь отказа или нарушения инварианта
- влияние объяснено без догадок
- классификация согласована с фактическим поведением и документацией

Отдельно помечай:
- `acceptable`
- `false positive`
- `needs verification`

Не выдавай архитектурный trade-off за уязвимость, если проект его явно принимает и защита активов не ломается.

## Правила отчета

Отчет должен быть самодостаточным и пригодным для двух следующих задач:
- исправление подтвержденных находок
- последующая сборка `PDF` другим скиллом

Всегда включай:
1. краткое резюме
2. scope и источники истины
3. перечень инструментов и фактический coverage
4. список того, что не удалось запустить, и почему
5. findings table
6. подробные карточки подтвержденных находок
7. triage по `Slither` и другим шумным сигналам
8. список добавленной или проверенной property coverage
9. остаточные риски
10. приоритетный remediation plan
11. точные команды запуска

Если подтвержденных проблем нет, напиши это явно.

## Требования к стилю отчета

- Пиши на русском.
- Используй таблицы для сравнений и triage.
- Не вставляй длинные шумные логи.
- Давай точные ссылки на файлы и строки.
- Четко отделяй факт от вывода.
- Для каждого пропуска проверки указывай конкретный blocker.
- Не добавляй diff и не предлагай автопатч в этом режиме.
- Не коммить итоговый отчет без явной просьбы пользователя.

## Ресурс

Используй шаблон:
- `assets/report-template.md`
