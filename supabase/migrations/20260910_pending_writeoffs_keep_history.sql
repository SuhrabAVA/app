-- Удаление краски со склада упиралось в историю переходящих списаний.
--
-- СИМПТОМ
-- «update or delete on table "paints" violates foreign key constraint
-- "order_paint_pending_writeoffs_paint_id_fkey"» — карточку краски нельзя
-- удалить, пока по ней есть хоть одна строка переходящего списания. Строки
-- эти накапливаются годами и не удаляются никогда: погашенная получает
-- status <> 'pending', но остаётся в таблице как факт производства.
--
-- ПОЧЕМУ ЗАПРЕТ ЗДЕСЬ НЕ ЗАЩИЩАЕТ
-- Запрет имеет смысл, когда ссылка несёт смысл. Здесь она его почти не несёт:
-- тождество краски в этом механизме — ИМЯ, а не id. Так устроены оба
-- потребителя:
--
--   * серверный guard переходящих красок (20260717) ищет pending-строку по
--     `normalize_paint_name(paint_name)` и на paint_id не смотрит вовсе;
--   * клиент (`getPendingFlexPaintWriteoffs`) принимает строку, если совпал
--     paint_id ИЛИ имя, — совпадения имени достаточно.
--
-- Ссылка на id — удобство, а не опора. Запрет из-за неё не сохранял ни грамма
-- краски: банки на складе давно нет, кладовщик убирает карточку.
--
-- ПОЧЕМУ set null, А НЕ cascade
-- Каскад стёр бы факты производства: сколько краски ушло, по какому заказу и
-- этапу. Эти строки — учёт, а не служебный мусор, и терять их при уборке
-- склада нельзя. set null убирает только ссылку; `paint_name`,
-- `planned_amount`, `actual_used_amount` и статус остаются на месте, и оба
-- потребителя продолжают узнавать строку по имени.
--
-- ЧТО ЭТО МЕНЯЕТ ДЛЯ ЗАЩИТЫ ПЕРЕХОДЯЩИХ КРАСОК
-- Ничего. Guard 20260717 сравнивает имена; строка с paint_id = null для него
-- неотличима от прежней и продолжает запирать краску в чужом заказе.

alter table public.order_paint_pending_writeoffs
  alter column paint_id drop not null;

alter table public.order_paint_pending_writeoffs
  drop constraint if exists order_paint_pending_writeoffs_paint_id_fkey;

alter table public.order_paint_pending_writeoffs
  add constraint order_paint_pending_writeoffs_paint_id_fkey
  foreign key (paint_id) references public.paints(id) on delete set null;

comment on column public.order_paint_pending_writeoffs.paint_id is
  'Ссылка на карточку склада; NULL — карточку удалили. Тождество краски в '
  'этом механизме несёт paint_name (нормализованное имя), а не id: по нему '
  'ищет и серверный guard переходящих красок, и клиентский подбор. Поэтому '
  'внешний ключ стоит ON DELETE SET NULL — уборка склада не должна стирать '
  'факты производства и не должна блокироваться ими.';
