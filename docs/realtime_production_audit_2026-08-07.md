# Realtime production blockers: локальный аудит и решение

Дата: 2026-08-07. Работа выполнена только в локальном repository.

## Verdict

**READY FOR STAGING**

Это не разрешение на production. Перед staging обязательны ручная проверка
истории migrations, read-only duplicate diagnostic, review SQL и применение
migrations 10–13 в подтверждённом порядке. Никакая migration из этого отчёта не
применялась; remote Supabase, staging и production не открывались.

## 1. Причина stock-recheck проблемы

Git history восстанавливает две фазы:

- до `eacc6dc` stock realtime мог запускать ожидающие заказы автоматически;
- commit `eacc6dc` закрепил ручной запуск и заменил auto-launch на
  `recheckMaterialAvailability(forceRefresh: true)`.

Последняя production-семантика до централизации была такой:

```text
INSERT/UPDATE/DELETE в одной из 8 stock/log tables
  -> отдельный onPostgresChanges на каждом клиенте
  -> debounce 400 ms
  -> recheckMaterialAvailability(forceRefresh: true)
  -> SELECT orders
  -> SELECT остатков/резервов
  -> UPDATE orders
  -> новый realtime event orders
```

Восемь исходных таблиц: `materials`, `papers`, `materials_arrivals`,
`materials_writeoffs`, `materials_inventories`, `papers_arrivals`,
`papers_writeoffs`, `papers_inventories`.

`recheckMaterialAvailability` не переписан и не заменён новым алгоритмом. Он:

1. перечитывает `orders`, если `forceRefresh=true`;
2. берёт только заказы без `assignmentCreated` в статусах
   `waiting_materials`/`ready_to_start`;
3. если queue не `built`, возвращает `draft` и очищает shortage fields;
4. иначе проверяет бумагу/материал и краску с активными резервами;
5. пишет только `orders.status`, `orders.has_material_shortage` и
   `orders.material_shortage_message`;
6. `tasks` не пишет;
7. в конце перечитывает `orders`.

Фактические reads: `orders`, `materials`, `papers`,
`order_paper_reservations`, `paints`, `order_paint_reservations`. В старом
read path дополнительно отбрасывались stale reserve rows закрытых заказов.

Старый callback был опасен, потому что один stock commit заставлял каждый
подключённый клиент независимо выполнять бизнес-UPDATE. Это создавало
N writers, гонки по status/shortage, повторные events и каскад
`DB update -> RT -> business update -> RT`.

## 2. Где теперь выполняется business recalculation

`StockAvailabilityRecheckCoordinator` регистрирует ровно существующий
`OrdersProvider.recheckMaterialAvailability(forceRefresh: true)` и
сериализует вызовы. Его вызывает origin-команда только после успешного commit:

- warehouse add/arrival/update/quantity/writeoff/return/delete/inventory;
- отмена arrival/writeoff/inventory;
- `receivePaperByName`/`consumePaperByName`;
- `shipOrder` после атомарной финализации paper reservations;
- `complete_task_stage` и flex completion: repository сравнивает состояние
  заказа до/после и вызывает recheck только при финальном переходе с имевшимся
  paper reserve; post-state probe выполняется и после RPC timeout/error.

Параллельные stock-команды не теряются: coordinator выполняет их по очереди,
один recheck на один успешный command call.

Сохранён исходный охват:

| Событие | Раньше | Теперь |
|---|---|---|
| Приход/списание/inventory material/paper | RT recheck на всех клиентах | origin command -> один recheck |
| Изменение заказа/бумаги заказа | `_applyImmediateMaterialAvailabilityState` | без изменения |
| Резерв при launch | отдельного stock recheck не было; launch проверял сам | без изменения |
| Завершение final stage с paper reserve | `papers_writeoffs` RT | canonical completion -> один recheck |
| Ручной `refresh()` orders | только SELECT | без изменения |

Realtime base/log events теперь только обновляют read model другого устройства;
они не обращаются к coordinator.

## 3. Почему realtime больше не вызывает business WRITE

Shared callback существует в одном месте:

```text
RealtimeSyncService.onPostgresChanges
  -> _onDatabaseChange
  -> RealtimeInvalidation event
  -> debounced registered refresh handler
```

Route для `materials` содержит только `warehouseMaterials`, для `papers` —
только `warehousePapers`; шесть material/paper log tables имеют пустой resource
set и обновляют только открытый log bundle через event bus. `orders` resource в
этих routes отсутствует.

Отдельные три callbacks Chat вызывают только `_scheduleRoomRefresh` и затем
`SELECT chat_messages`. Writes чата выполняются только командами send/edit/delete,
не callbacks.

## 4. Причина pens race и полный completion call graph

До исправления:

```text
normal task
  -> OrdersRepository.completeTaskStage / completeFlexPrintingStage
  -> complete_task_stage / complete_flex_printing_stage_with_paint_queue
  -> advance_order_after_task_completion
  -> UPDATE tasks/order + paper finalization
  -> order realtime callback
  -> SELECT warehouse_pens_writeoffs WHERE order_id
  -> INSERT warehouse_pens_writeoffs

test mode
  -> direct INSERT completed task или TaskProvider.updateStatus(completed)
  -> direct UPDATE orders.status=completed
  -> тот же order realtime callback
  -> тот же race-prone SELECT -> INSERT
```

`advance_order_after_task_completion` содержал paper finalization, но не pens.
Повторный INSERT был возможен при double click, RPC retry после timeout,
reconnect, двух устройствах, повторном completion и обычной гонке между SELECT
и INSERT. Каждый RT client мог пройти SELECT до commit соседа.

Таблица — `public.warehouse_pens_writeoffs`. Канонические поля операции:

| Смысл | Поле/источник |
|---|---|
| Business key | `order_id` |
| Material | `item_id`, найденный по единственному `OrderModel.handle` |
| Amount | `orders.actual_qty`, fallback `orders.shipped_qty` |
| Customer/reason | `reason <- orders.customer` |
| Employee | `by_name`, actor/JWT если доступен |
| Timestamp | существующий DB default `created_at` |
| Task/stage | не является частью записи и historical contract |

Natural key `order_id` подтверждён историей: commit `1b09e09` в октябре 2025
ввёл проверку «одна completion writeoff на order». `OrderModel.handle` единичен,
таблица уже задаёт writeoff type, а task/stage никогда не записывались. Поэтому
пример `(order_id, stage_id, writeoff_type)` проектом не подтверждается.

## 5. Idempotency strategy

Новая локальная migration делает три вещи в одной транзакции:

1. fail-closed preflight ищет duplicate non-null `order_id` и прерывает
   migration с manual-remediation hint;
2. создаёт partial unique index на `order_id where order_id is not null`;
3. создаёт `record_order_pens_completion_writeoff(text,text)` с order row lock и
   `INSERT ... ON CONFLICT ... DO NOTHING`, плюс trigger на переход
   `orders.status` в `completed`.

Trigger и order status UPDATE находятся в одной PostgreSQL transaction. Если
клиент получил timeout после commit, pens row уже committed вместе с status;
retry видит completed task/order, а unique index исключает вторую строку.
Повторный UPDATE уже completed order отсеивается по `OLD.status`.

Существующий insert-trigger `fn_pens_apply_writeoff` уменьшает
`warehouse_pens.quantity`. Поскольку journal INSERT ровно один, stock decrement
тоже ровно один.

Test-mode теперь создаёт при необходимости `waiting` task и вызывает тот же
`OrdersRepository.completeTaskStage`/`complete_task_stage`, что production.
Прямого `TaskStatus.completed` write в test-mode больше нет.

## 6. Требуемая DB migration и diagnostics

- Migration: `supabase/migrations/20260813_atomic_pens_completion_writeoff.sql`
- Read-only diagnostic:
  `supabase/diagnostics/pens_completion_writeoff_duplicates.sql`
- Local rollback integration test:
  `supabase/tests/20260813_pens_completion_writeoff_idempotency.sql`
- Local two-session concurrency test:
  `supabase/tests/20260813_pens_concurrency_session_a.sql` and
  `20260813_pens_concurrency_session_b.sql`

Migration не выполняет `DELETE`, `UPDATE` existing business rows, `TRUNCATE`,
`CASCADE`, `DROP TABLE/COLUMN/POLICY` или RLS disable. При duplicates она ничего
не очищает и должна остаться failed до ручного решения владельцем данных.

Manual remediation plan: выгрузить duplicate IDs/amount/item/timestamps,
сверить с order, pens stock ledger и ответственным сотрудником, выбрать
каноническую строку вручную, отдельно согласовать компенсацию stock и только
после этого повторить diagnostic. Автоматического cleanup SQL нет.

## 7. Подтверждение, что migrations не применялись

Ни `supabase db push`, ни migration up/reset, ни SQL connection не запускались.
Файлы 10–13 остаются локальными/untracked. Невозможно честно утверждать, какие
версии когда-либо применялись на remote, не подключаясь к нему; это отдельная
read-only проверка человека перед staging.

## 8. Migration timestamp 20260812

Repository evidence:

| Version | Filename | Git evidence | Dependency |
|---|---|---|---|
| 20260805 | `replace_plan_stages` | commit `b4f20c3`, authored 2026-08-05 | existing plans/tasks |
| 20260806 | `product_type_form_blocks` | `d43c5ea`, authored 2026-08-05 | existing orders/product types |
| 20260806 | `publish_product_type_config` | `0d87d4b`, authored 2026-08-05 | previous 20260806 tables |
| 20260807 | `product_type_stages` | `4f53ae5`, authored 2026-08-06 | 20260806 configs |
| 20260807 | `product_type_stages_seed` | `4f53ae5`, authored 2026-08-06 | stages migration |
| 20260808 | `product_type_stage_editing` | `29b1369`, authored 2026-08-06 | stages/workplaces/conditions |
| 20260809 | `product_type_stage_workplaces` | `c735d78`, authored 2026-08-07 | 20260807/08 schema |
| 20260810 | `product_type_stage_condition` | no Git history, local only | conditions table from 20260807 |
| 20260811 | `product_type_execution_and_formula` | no Git history, local only | configs/stages from 20260806/07 |
| 20260812 | `enable_targeted_realtime` | no Git history, local only | current client manifest; publishes tables from earlier chain |
| 20260813 | `atomic_pens_completion_writeoff` | no Git history, local only | existing orders/pens ledger; no hard dependency on 20260812 |

08 and 09 are real committed migrations. 10–13 are real local migration files,
но не имеют Git evidence применения. Уже 06/07/08 были созданы за день до
числа в имени: в этой ветке suffix используется как монотонный release slot, а
не достоверный wall-clock timestamp. SQL 20260812 устойчив к optional missing
tables, но release bundle логически должен идти после 10/11.

Автоматическое переименование 12 небезопасно: оно может создать out-of-order
version относительно уже известных 08–11 и расходиться с любой внешней migration
metadata. Стратегия: имена 08–13 оставить, перед staging получить read-only list
applied versions и применить только отсутствующие строго по version order.

## 9. Полный realtime -> DB audit

| Callback/route | Call chain | Конец | Class |
|---|---|---|---|
| `orders` | central callback -> scheduler -> `OrdersProvider.refresh` | SELECT orders | READ |
| `orders/tasks/plans/templates` -> tasks | scheduler -> `TaskProvider.refresh` -> aliases/stage-sequence loaders | SELECT tasks/workplaces/plans/templates | READ |
| task attachments | scheduler -> invalidate attachment cache | cache only | NO DB |
| paper reservations | scheduler -> invalidate reserved cache | cache/notify | NO DB |
| paint reservations/base | scheduler -> Warehouse targeted paint refresh | SELECT paints/reservations | READ |
| material/paper/pens/stationery base | scheduler -> matching `_refresh*FromRealtime` | one targeted SELECT | READ |
| warehouse log tables | central event bus -> `_markLogsDirty` -> `WarehouseLogsRepository.refreshKind` | paged SELECT of open log only | READ |
| queue legacy | scheduler -> bootstrap barrier -> `_loadLegacyRemote(false)` | SELECT queue; local `_persist` only | READ |
| queue positions | scheduler -> bootstrap barrier -> `_loadAllWorkplacePositions` | SELECT positions | READ |
| personnel resources | scheduler -> `fetchEmployees/Positions/Workplaces/Terminals/Statuses` | SELECT views/tables | READ |
| employees/documents -> chat cache | scheduler -> `_refreshActiveChatData` | SELECT open rooms | READ |
| suppliers | scheduler -> `fetchSuppliers` | SELECT suppliers | READ |
| forms | scheduler -> screen `_reload` | SELECT forms | READ |
| categories/items/logs | scheduler -> `_load`/`_loadAll` | SELECT category tables | READ |
| deleted records | scheduler -> `_load` | filtered SELECT | READ |
| product type config | scheduler -> `ensureLoaded(force:true)` only if loaded | SELECT config graph | READ |
| analytics | scheduler/provider debounce -> `AnalyticsService.refresh` | analytics SELECT bundle | READ |
| chat INSERT/UPDATE/DELETE | scoped callback -> room scheduler -> `_refreshRoom` | SELECT chat_messages | READ |
| stale/session callback | generation gate rejects | none | NO DB |

Static search result: четыре `onPostgresChanges` call sites — один central builder
и три scoped Chat handlers. Ни один call graph не достигает stock recheck,
queue save, pens/paper writeoff, order/task UPDATE или другого business DML.
Оставшихся realtime-triggered business writes: **нет**.

## 10. Изменённые файлы в realtime/blocker scope

Core implementation:

- `lib/services/realtime_sync_service.dart`
- `lib/services/stock_availability_recheck_coordinator.dart`
- `lib/services/handles_writeoff_logger.dart`
- `lib/modules/orders/orders_provider.dart`
- `lib/modules/orders/orders_repository.dart`
- `lib/modules/warehouse/warehouse_provider.dart`
- `lib/modules/production/production_details_screen.dart`
- `lib/modules/production/production_queue_provider.dart`
- `lib/modules/tasks/task_provider.dart`
- `lib/modules/chat/chat_provider.dart`
- `lib/modules/analytics/screens/analytics_home_screen.dart`
- `lib/modules/personnel/personnel_provider.dart`
- `lib/modules/production_planning/template_provider.dart`
- `lib/modules/orders/product_type_settings.dart`
- `lib/modules/warehouse/supplier_provider.dart`
- `lib/modules/warehouse/forms_screen.dart`
- `lib/modules/warehouse/categories_hub_screen.dart`
- `lib/modules/warehouse/deleted_records_screen.dart`
- `lib/my_app.dart`, `lib/services/doc_db.dart`, `lib/utils/auth_helper.dart`

SQL/tests/docs:

- `supabase/migrations/20260812_enable_targeted_realtime.sql`
- `supabase/migrations/20260813_atomic_pens_completion_writeoff.sql`
- `supabase/diagnostics/pens_completion_writeoff_duplicates.sql`
- `supabase/tests/20260813_pens_completion_writeoff_idempotency.sql`
- `supabase/tests/20260813_pens_concurrency_session_a.sql`
- `supabase/tests/20260813_pens_concurrency_session_b.sql`
- `test/realtime_refresh_scheduler_test.dart`
- `test/production_blockers_test.dart`
- этот report.

В working tree также сохранены незавершённые product-type UI/migrations 10–11 и
dirty submodule `sheet_clone`; они не очищались, не staging-ились и не
приписываются четырём blockers.

Полный preserved non-blocker status на момент отчёта: изменены
`personnel/product_type_settings_shell.dart`,
`product_type_stage_dialogs.dart`, `product_type_stage_row.dart`,
`product_type_stage_workplaces_panel.dart`, `product_type_stages_tab.dart`,
`warehouse/type_table_screen.dart`, `warehouse/warehouse_provider_woinv.dart`;
untracked `orders/product_type_condition_options.dart`,
`personnel/product_type_add_stage_control.dart`,
`product_type_conditions_tab.dart`, `product_type_stage_actions.dart`,
`product_type_stage_condition_editor.dart`,
`product_type_stage_substages_block.dart`, migrations 10/11; submodule
`sheet_clone` dirty. Ничего из этого не удалялось и не reset-илось.

## 11. Тесты и результаты

Локально выполнены два target файла: **23/23 passed**. Они покрывают:

1. queue RT handlers не содержат remote save/seed;
2. stock RT routes refresh warehouse, не orders/status;
3. один canonical stock command -> один calculation;
4. concurrent stock commands сериализуются без потери;
5. повторный pens completion -> conflict no-op;
6. concurrent pens contract: row lock + partial unique + conflict;
7. test-mode вызывает canonical RPC;
8. timeout retry защищён transaction trigger + unique;
9. identical completion отсеивается OLD.status + unique;
10. diagnostic read-only, migration не чистит business rows;
11. burst/queued/dispose/session/reconnect/owner/bootstrap/publication tests.

Созданы SQL integration test с `ROLLBACK` и двухсессионный concurrency test;
они намеренно не запускались, потому что локальная disposable PostgreSQL fixture
в этой задаче не поднималась, а remote использовать запрещено.

Target analyze: ошибок компиляции нет; analyzer вернул существующие warnings в
крупных legacy files. Полный warning cleanup вне scope. `git diff --check` не
нашёл whitespace errors (выводит только существующие LF/CRLF notices).

## 12. Двухустройственный staging runbook

До всех сценариев вручную: снять migration/publication snapshot; выполнить
duplicate diagnostic (zero rows/zero count); review и применить отсутствующие
10, 11, 12, 13 строго по подтверждённой history; использовать отдельные test
orders/items, сохранить их IDs и SQL audit timestamps.

### S1. Channel ownership

- **PRECONDITION:** чистый login, diagnostics открыт на A и B.
- **DEVICE A ACTION:** login, 20 раз открыть/закрыть warehouse/orders.
- **EXPECTED DB CHANGE:** нет.
- **EXPECTED REALTIME EVENT:** только subscribe/status lifecycle.
- **EXPECTED DEVICE A RESULT:** пять shared channels; owners/timers возвращаются к baseline.
- **EXPECTED DEVICE B RESULT:** без изменений.
- **EXPECTED REFRESH METHOD:** initial explicit SELECT, не business command.
- **MUST NOT HAPPEN:** рост channels/owners/timers, duplicate channel, DML.

### S2. Queue realtime is read-only

- **PRECONDITION:** одна тестовая workplace queue видна A/B; включён SQL audit.
- **DEVICE A ACTION:** один раз переместить queue item canonical UI command.
- **EXPECTED DB CHANGE:** одна origin queue position mutation.
- **EXPECTED REALTIME EVENT:** `workplace_queue_positions`.
- **EXPECTED DEVICE A RESULT:** новый порядок сразу после command.
- **EXPECTED DEVICE B RESULT:** тот же порядок после одного coalesced refresh.
- **EXPECTED REFRESH METHOD:** B -> `_loadAllWorkplacePositions()` SELECT.
- **MUST NOT HAPPEN:** queue INSERT/UPDATE от B, legacy seed, duplicate save/comment/channel.

### S3. Material arrival and status promotion

- **PRECONDITION:** order W ожидает material, queue built, shortage подтверждён; item balance недостаточен.
- **DEVICE A ACTION:** провести один material arrival, достаточный для W.
- **EXPECTED DB CHANGE:** один arrival/base stock effect; W один раз меняется на `ready_to_start`, shortage false/message empty.
- **EXPECTED REALTIME EVENT:** material log/base events, затем order UPDATE event.
- **EXPECTED DEVICE A RESULT:** stock и W обновлены origin recheck.
- **EXPECTED DEVICE B RESULT:** targeted stock refresh, затем Orders refresh показывает W ready.
- **EXPECTED REFRESH METHOD:** A canonical command -> coordinator; B RT -> SELECT only.
- **MUST NOT HAPPEN:** status UPDATE от B, auto-launch/tasks creation, oscillation, повторный arrival.

### S4. Paper writeoff and status demotion

- **PRECONDITION:** order R `ready_to_start`, queue built, paper balance ровно достаточен.
- **DEVICE A ACTION:** выполнить одно списание, делающее balance недостаточным.
- **EXPECTED DB CHANGE:** один paper writeoff/base effect; R один раз -> `waiting_materials` с shortage message.
- **EXPECTED REALTIME EVENT:** paper log/base, затем orders.
- **EXPECTED DEVICE A RESULT:** новый balance/status.
- **EXPECTED DEVICE B RESULT:** тот же status после read-only refresh.
- **EXPECTED REFRESH METHOD:** A coordinator once; B targeted SELECT + Orders SELECT.
- **MUST NOT HAPPEN:** recheck writer на B, второй writeoff, status loop.

### S5. Normal final completion with paper and pens

- **PRECONDITION:** final task active; one paper reserve; valid handle; positive actual qty; no pens writeoff for order.
- **DEVICE A ACTION:** нажать normal Complete один раз.
- **EXPECTED DB CHANGE:** canonical RPC завершает task/order; paper reserve finalized once; one pens journal row; pens quantity decreases once.
- **EXPECTED REALTIME EVENT:** tasks, orders, paper reserve/writeoff/base, pens writeoff/base.
- **EXPECTED DEVICE A RESULT:** completed order, final stock values.
- **EXPECTED DEVICE B RESULT:** same state via refresh.
- **EXPECTED REFRESH METHOD:** A RPC transaction + one post-completion stock recheck; B RT SELECT only.
- **MUST NOT HAPPEN:** second pens/paper row, second stock decrement, B DML, duplicate comment.

### S6. Same-device double click and retry

- **PRECONDITION:** отдельный order как S5; throttle позволяет послать два запроса.
- **DEVICE A ACTION:** double click Complete либо повторить после искусственного client timeout.
- **EXPECTED DB CHANGE:** один committed completion и один pens row.
- **EXPECTED REALTIME EVENT:** события только committed transaction.
- **EXPECTED DEVICE A RESULT:** success или «already completed» после ambiguous timeout; итог корректен.
- **EXPECTED DEVICE B RESULT:** один итоговый completed state.
- **EXPECTED REFRESH METHOD:** normal coalesced read refresh.
- **MUST NOT HAPPEN:** duplicate writeoff/decrement/comment, partial status без journal.

### S7. Concurrent completion on two devices

- **PRECONDITION:** A/B открыли один final task до completion; SQL query считает rows by order_id.
- **DEVICE A ACTION:** A и B одновременно нажимают Complete.
- **EXPECTED DB CHANGE:** task/order row lock serializes; partial unique допускает ровно один pens row; paper reserve finalized once.
- **EXPECTED REALTIME EVENT:** один committed final transition; duplicate client request не создаёт второй business event.
- **EXPECTED DEVICE A RESULT:** один success, второй success/already-completed в зависимости timing.
- **EXPECTED DEVICE B RESULT:** идентичный итог.
- **EXPECTED REFRESH METHOD:** coalesced SELECT on both.
- **MUST NOT HAPPEN:** two rows for order_id, two quantity decrements, deadlock, status rollback after committed journal.

### S8. Test-mode completion

- **PRECONDITION:** тестовый order с теми же reserves/handle; test mode включён; stage not completed.
- **DEVICE A ACTION:** Skip stage до финального этапа.
- **EXPECTED DB CHANGE:** marker comment once; task completed canonical RPC; на final stage те же paper/pens effects, если quantity > 0.
- **EXPECTED REALTIME EVENT:** тот же набор, что normal completion.
- **EXPECTED DEVICE A RESULT:** следующий stage/final completed state.
- **EXPECTED DEVICE B RESULT:** тот же state.
- **EXPECTED REFRESH METHOD:** `OrdersRepository.completeTaskStage`, не `TaskProvider.updateStatus(completed)`.
- **MUST NOT HAPPEN:** direct completed INSERT, duplicate marker/finish comment, второй pens writeoff.

### S9. Reconnect burst

- **PRECONDITION:** A/B online, diagnostics baseline, test records prepared.
- **DEVICE A ACTION:** отключить сеть B; на A выполнить stock change + queue change + chat message; вернуть сеть B.
- **EXPECTED DB CHANGE:** только три origin commands A.
- **EXPECTED REALTIME EVENT:** reconnect/subscription плюс missed-state refresh.
- **EXPECTED DEVICE A RESULT:** команды сохранены один раз.
- **EXPECTED DEVICE B RESULT:** актуальное состояние после reconnect refresh.
- **EXPECTED REFRESH METHOD:** generation-gated replace + coalesced SELECT.
- **MUST NOT HAPPEN:** replayed stock/order/queue DML, duplicate pens/comment, stale channel resurrection.

### S10. Duplicate diagnostic gate

- **PRECONDITION:** staging migration 13 ещё не применена.
- **DEVICE A ACTION:** человек запускает только read-only diagnostic SQL.
- **EXPECTED DB CHANGE:** нет.
- **EXPECTED REALTIME EVENT:** нет.
- **EXPECTED DEVICE A RESULT:** zero duplicate rows/count; иначе rollout STOP.
- **EXPECTED DEVICE B RESULT:** без изменений.
- **EXPECTED REFRESH METHOD:** прямой read-only SQL.
- **MUST NOT HAPPEN:** cleanup/update/delete, применение unique при найденных duplicates, продолжение rollout.

## 13. Остались ли realtime-triggered business writes

**Нет.** System channel subscribe/remove/reconnect не считается business DML.
Все business writers находятся в explicit command paths или в транзакционном
DB trigger order completion, подготовленном только как локальная migration.

## 14. Финальный статус

**READY FOR STAGING** — только после ручного SQL review и preconditions runbook.
Production остаётся запрещён следующим этапом процесса.
