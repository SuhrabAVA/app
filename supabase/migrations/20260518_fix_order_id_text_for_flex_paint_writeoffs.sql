-- Fix for flex-printing paint write-off failure:
-- column "order_id" is of type uuid but expression is of type text.
--
-- The Flutter/PostgREST layer and the existing RPC functions pass order_id as text.
-- These side tables are queried by order_id::text in the RPCs, so keep their order_id
-- columns as text to avoid PL/pgSQL text -> uuid insert failures.

alter table if exists public.order_paint_pending_writeoffs
  drop constraint if exists order_paint_pending_writeoffs_order_id_fkey;

alter table if exists public.order_paint_reservations
  drop constraint if exists order_paint_reservations_order_id_fkey;

alter table if exists public.order_events
  drop constraint if exists order_events_order_id_fkey;

alter table if exists public.order_paint_pending_writeoffs
  alter column order_id type text using order_id::text;

alter table if exists public.order_paint_reservations
  alter column order_id type text using order_id::text;

alter table if exists public.order_events
  alter column order_id type text using order_id::text;

create index if not exists order_paint_pending_writeoffs_order_id_text_idx
  on public.order_paint_pending_writeoffs(order_id);

create index if not exists order_paint_reservations_order_id_text_idx
  on public.order_paint_reservations(order_id);

create index if not exists order_events_order_id_text_idx
  on public.order_events(order_id);
