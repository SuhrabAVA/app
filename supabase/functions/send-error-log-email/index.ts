// Отправка журнала ошибок на почту (задача 2026-07-29).
//
// Читает из app_error_logs партии, по которым письмо ещё не уходило
// (emailed_at is null), склеивает их в одно письмо и помечает отправленными.
//
// Запуск: по расписанию (pg_cron / Supabase Schedules) — например, раз в
// 15 минут. Клиент письмо не шлёт: ключ почтового сервиса не должен попадать
// в APK, иначе им сможет воспользоваться любой, кто вскроет сборку.
//
// Переменные окружения (Dashboard → Edge Functions → Secrets):
//   RESEND_API_KEY   — ключ Resend (resend.com, бесплатный тариф)
//   ERROR_LOG_TO     — получатель, напр. suhrabavakov81@gmail.com
//   ERROR_LOG_FROM   — отправитель, напр. onboarding@resend.dev
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY — подставляются платформой.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

interface ErrorEntry {
  time?: string;
  source?: string;
  message?: string;
  stack?: string;
  context?: string;
}

interface LogRow {
  id: string;
  created_at: string;
  employee_name: string | null;
  employee_id: string | null;
  device_model: string | null;
  platform: string | null;
  app_version: string | null;
  session_id: string;
  reason: string;
  entries_count: number;
  entries: ErrorEntry[];
}

const escapeHtml = (value: string): string =>
  value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');

function renderRow(row: LogRow): string {
  const header = [
    row.employee_name?.trim() || 'без имени',
    row.platform || '',
    row.device_model || '',
    `причина: ${row.reason}`,
  ]
    .filter((part) => part !== '')
    .join(' · ');

  const entries = (row.entries ?? [])
    .map((e) => {
      const time = e.time ? new Date(e.time).toLocaleString('ru-RU') : '';
      const head = `${time} [${e.source ?? '—'}]${
        e.context ? ` (${e.context})` : ''
      }`;
      const stack = e.stack
        ? `<pre style="margin:4px 0 0;white-space:pre-wrap;color:#64748b;font-size:11px">${escapeHtml(
            e.stack.slice(0, 4000),
          )}</pre>`
        : '';
      return `<li style="margin-bottom:10px">
        <div style="color:#64748b;font-size:11px">${escapeHtml(head)}</div>
        <div style="font-family:monospace;font-size:12px">${escapeHtml(
          e.message ?? '',
        )}</div>
        ${stack}
      </li>`;
    })
    .join('');

  return `<section style="margin-bottom:24px">
    <h3 style="margin:0 0 4px;font-size:14px">${escapeHtml(header)}</h3>
    <div style="color:#94a3b8;font-size:11px;margin-bottom:8px">
      ${new Date(row.created_at).toLocaleString('ru-RU')} · записей: ${
    row.entries_count
  }
    </div>
    <ul style="margin:0;padding-left:16px">${entries}</ul>
  </section>`;
}

Deno.serve(async () => {
  const resendKey = Deno.env.get('RESEND_API_KEY');
  const to = Deno.env.get('ERROR_LOG_TO');
  const from = Deno.env.get('ERROR_LOG_FROM') ?? 'onboarding@resend.dev';

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  const { data, error } = await supabase
    .from('app_error_logs')
    .select('*')
    .is('emailed_at', null)
    .order('created_at', { ascending: true })
    .limit(50);

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const rows = (data ?? []) as LogRow[];
  if (rows.length === 0) {
    return new Response(JSON.stringify({ sent: 0, reason: 'nothing new' }), {
      headers: { 'Content-Type': 'application/json' },
    });
  }

  if (!resendKey || !to) {
    return new Response(
      JSON.stringify({
        error: 'RESEND_API_KEY или ERROR_LOG_TO не заданы в секретах функции',
        pending: rows.length,
      }),
      { status: 400, headers: { 'Content-Type': 'application/json' } },
    );
  }

  const totalEntries = rows.reduce((sum, r) => sum + (r.entries_count ?? 0), 0);
  const html = `<div style="font-family:system-ui,Segoe UI,sans-serif;color:#0f172a">
    <h2 style="font-size:16px;margin:0 0 12px">
      Easy Pack Pro — журнал ошибок (${totalEntries} записей, сессий: ${rows.length})
    </h2>
    ${rows.map(renderRow).join('')}
  </div>`;

  const mail = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${resendKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from,
      to: [to],
      subject: `Easy Pack Pro: ошибки (${totalEntries}) — ${new Date().toLocaleDateString('ru-RU')}`,
      html,
    }),
  });

  if (!mail.ok) {
    const body = await mail.text();
    return new Response(JSON.stringify({ error: 'resend failed', body }), {
      status: 502,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  // Помечаем отправленным только после успешной доставки в Resend —
  // иначе при сбое партия потерялась бы без письма.
  await supabase
    .from('app_error_logs')
    .update({ emailed_at: new Date().toISOString() })
    .in('id', rows.map((r) => r.id));

  return new Response(
    JSON.stringify({ sent: rows.length, entries: totalEntries }),
    { headers: { 'Content-Type': 'application/json' } },
  );
});
