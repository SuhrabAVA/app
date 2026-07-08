-- ============================================================================
-- ЧЕРНОВИК DDL: «Претензия из чата» — НЕ ПРИМЕНЯТЬ без утверждения.
-- Файл: docs/etalon_analytics/proposed_ddl_claims.sql
--
-- Стратегия: НЕ создаём новую таблицу. Расширяем существующую public.claims,
-- из которой аналитика уже читает данные (ClaimsRepository.listForMonth →
-- AnalyticsState.claims). Так остаётся ОДИН механизм подсчёта претензий:
-- месяц = месяц created_at, привязка к сотруднику = employee_id.
--
-- LIVE-ПРОВЕРКА 2026-07-07 (PostgREST OpenAPI):
--   claims: id=uuid; order_id/comment_id/employee_id/workplace_id/created_by
--     = text; order_id уже nullable. Колонки source/message_id/file_url/
--     file_mime/author_name УЖЕ существуют (source NOT NULL).
--   chat_messages: id=uuid, sender_id=uuid; claim_targets jsonb УЖЕ есть.
--   => типы совпадают с черновиком, правки типов не нужны; скрипт
--      идемпотентен и безопасен при повторном прогоне (важны шаги 3 и 5 —
--      индексы и RLS, их наличие через OpenAPI проверить нельзя).
-- ============================================================================

-- ── 1. claims.order_id становится необязательным ───────────────────────────
-- Претензия из чата не привязана к заказу.
ALTER TABLE public.claims
  ALTER COLUMN order_id DROP NOT NULL;

-- ── 2. Новые колонки claims ─────────────────────────────────────────────────
ALTER TABLE public.claims
  -- Источник претензии: различаем в UI, но СЧИТАЕМ вместе.
  ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'order'
    CHECK (source IN ('order', 'chat')),
  -- Ссылка на сообщение чата (id генерируется клиентом до insert).
  ADD COLUMN IF NOT EXISTS message_id text,
  -- Денормализованная ссылка на медиа (public URL из bucket 'chat'):
  -- переживает удаление/очистку сообщения в chat_messages.
  ADD COLUMN IF NOT EXISTS file_url text,
  ADD COLUMN IF NOT EXISTS file_mime text,
  -- Имя автора (created_by хранит app-id вида 'tech_leader' / documents-id,
  -- который не джойнится с auth.users — храним читаемое имя рядом).
  ADD COLUMN IF NOT EXISTS author_name text;

-- Претензия из чата обязана ссылаться на сообщение.
-- DROP+ADD, потому что у ADD CONSTRAINT нет IF NOT EXISTS: скрипт должен
-- быть безопасен при повторном прогоне (live-проверка 2026-07-07 показала,
-- что колонки шага 1–2 и claim_targets уже существуют в схеме).
ALTER TABLE public.claims
  DROP CONSTRAINT IF EXISTS claims_chat_requires_message;
ALTER TABLE public.claims
  ADD CONSTRAINT claims_chat_requires_message
  CHECK (source <> 'chat' OR message_id IS NOT NULL);

-- ── 3. Индексы ──────────────────────────────────────────────────────────────
-- Запрос аналитики: WHERE created_at >= .. AND created_at < .. (за месяц).
CREATE INDEX IF NOT EXISTS idx_claims_created_at
  ON public.claims (created_at);
CREATE INDEX IF NOT EXISTS idx_claims_employee_created
  ON public.claims (employee_id, created_at);
-- Поиск претензий по сообщению (бейдж/диалог).
CREATE INDEX IF NOT EXISTS idx_claims_message_id
  ON public.claims (message_id)
  WHERE message_id IS NOT NULL;

-- ── 4. Бейдж «Претензия» в чате ─────────────────────────────────────────────
-- Денормализованный маркер на самом сообщении, чтобы MessageBubble рисовал
-- бейдж синхронно из существующего realtime-потока chat_messages без
-- дополнительного запроса к claims.
-- Формат: JSON-массив [{"id": "<employee_id>", "name": "Фамилия Имя"}, ...]
ALTER TABLE public.chat_messages
  ADD COLUMN IF NOT EXISTS claim_targets jsonb;

-- ── 5. RLS ──────────────────────────────────────────────────────────────────
-- ЧЕСТНОЕ ОГРАНИЧЕНИЕ АРХИТЕКТУРЫ: приложение ходит в Supabase под ОДНИМ
-- техническим аккаунтом (AppAuth.ensureSignedIn: WAREHOUSE_EMAIL или
-- anonymous). auth.uid() одинаков для всех пользователей приложения, поэтому
-- БД не может отличить тех-лидера от упаковщика. Правило «создавать могут
-- только тех-лидер и менеджер» на уровне БД сейчас НЕПРОВЕРЯЕМО — оно
-- обеспечивается на уровне приложения (кнопка видна только этим ролям).
-- RLS ниже фиксирует максимум возможного: доступ только authenticated,
-- анонимному ключу без сессии — ничего.

ALTER TABLE public.claims ENABLE ROW LEVEL SECURITY;

-- Чтение — по существующей модели: все авторизованные клиенты приложения
-- (фильтрация «сотрудник видит только себя» уже реализована в
-- AnalyticsPermissionService на уровне приложения).
DROP POLICY IF EXISTS claims_select_authenticated ON public.claims;
CREATE POLICY claims_select_authenticated ON public.claims
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS claims_insert_authenticated ON public.claims;
CREATE POLICY claims_insert_authenticated ON public.claims
  FOR INSERT TO authenticated
  WITH CHECK (true);

-- Update/Delete из приложения не предусмотрены — политики не создаём
-- (при включённом RLS отсутствие политики = запрет).

-- ── 5б. Delete-политика для отката (ПРЕДЛОЖЕНИЕ, ждёт утверждения) ──────────
-- Сценарий: claims уже вставлены, а insert самого сообщения упал — клиент
-- откатывает только что созданные претензии (deleteByIds). Без политики
-- delete молча удалит 0 строк и останутся сироты, которые СЧИТАЮТСЯ в
-- аналитике. Политика узкая: только чат-претензии и только свежие (окно
-- отката 15 минут) — исторические данные из приложения удалить нельзя.
DROP POLICY IF EXISTS claims_delete_recent_chat ON public.claims;
CREATE POLICY claims_delete_recent_chat ON public.claims
  FOR DELETE TO authenticated
  USING (
    source = 'chat'
    AND created_at > now() - interval '15 minutes'
  );

-- ── 5а. СТРОГИЙ ВАРИАНТ (закомментирован) ───────────────────────────────────
-- Если/когда проект перейдёт на персональные Supabase-сессии и появится
-- таблица user_roles(user_id uuid, role text) — заменить insert-политику на:
--
-- DROP POLICY IF EXISTS claims_insert_authenticated ON public.claims;
-- CREATE POLICY claims_insert_lead_or_manager ON public.claims
--   FOR INSERT TO authenticated
--   WITH CHECK (
--     EXISTS (
--       SELECT 1 FROM public.user_roles ur
--       WHERE ur.user_id = auth.uid()
--         AND lower(ur.role) IN ('lead', 'tech_lead', 'tech_leader', 'manager')
--     )
--   );
