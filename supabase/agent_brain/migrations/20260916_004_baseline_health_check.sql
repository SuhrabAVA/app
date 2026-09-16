begin;

insert into public.ai_quality_checks
  (code, title, description, severity, confidence, sql_template, schedule, source_rule_codes, sample_limit, active)
values
  (
    'DH-BASELINE',
    'Базовая диагностика Easy Pack Pro',
    'Запускает существующую public.data_health_report(). Новые проверки не дублируют её коды.',
    'high',
    'confirmed',
    'select code, severity, title, affected, hint, sample from public.data_health_report()',
    'daily',
    array['TRAP-09'],
    10,
    true
  )
on conflict (code) do update set
  title = excluded.title,
  description = excluded.description,
  severity = excluded.severity,
  confidence = excluded.confidence,
  sql_template = excluded.sql_template,
  schedule = excluded.schedule,
  source_rule_codes = excluded.source_rule_codes,
  sample_limit = excluded.sample_limit,
  active = excluded.active,
  updated_at = now();

commit;

