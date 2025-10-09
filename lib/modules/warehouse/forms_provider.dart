import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// Провайдер для модуля нумераций (форм).
/// Переезд с коллекции `forms` в `documents` на таблицу `public.forms_series`.
class FormsProvider with ChangeNotifier {
  final SupabaseClient _sb = Supabase.instance.client;
  final List<Map<String, dynamic>> _series = [];

  List<Map<String, dynamic>> get series => List.unmodifiable(_series);

  Future<void> _ensureAuthed() async {
    final auth = _sb.auth;
    if (auth.currentUser == null) {
      await auth.signInAnonymously();
    }
  }

  /// Загружает список серий из таблицы `forms_series`.
  /// Загружает список серий из таблицы `forms_series`.
  /// Если таблица пуста, делает fallback на `forms` (группировка по серии, max(number)).
  Future<void> load() async {
    await _ensureAuthed();

    final res = await _sb
        .from('forms_series')
        .select()
        .order('created_at', ascending: true);
    final list = (res as List);

    _series.clear();

    if (list.isNotEmpty) {
      _series.addAll(list.map((row) {
        final r = Map<String, dynamic>.from(row as Map);
        return {
          'id': r['id'],
          'series': r['series'],
          'last_number': r['last_number'] ?? 0,
          'created_at': r['created_at'],
          'updated_at': r['updated_at'],
        };
      }));
    } else {
      // fallback: читаем формы и считаем last_number по серии
      dynamic sel = _sb
          .from('forms')
          .select(
              'id, series, number, last_number, product_type, size, colors, updated_at')
          .order('series', ascending: true)
          .limit(10000);
      final forms = await sel;
      final maxBySeries = <String, int>{};
      for (final row in (forms as List)) {
        final r = Map<String, dynamic>.from(row as Map);
        final s = (r['series'] ?? '').toString();
        final n = (r['number'] as num?)?.toInt() ?? 0;
        if (s.isEmpty) continue;
        if (!maxBySeries.containsKey(s) || n > maxBySeries[s]!) {
          maxBySeries[s] = n;
        }
      }
      // Заполним псевдо-строки (без id) для UI, чтобы экран не был пустым
      _series.addAll(maxBySeries.entries.map((e) => {
            'id': const Uuid().v4(),
            'series': e.key,
            'last_number': e.value,
            'created_at': null,
            'updated_at': null,
          }));
    }

    notifyListeners();
  }

  /// Создаёт новую серию.
  Future<void> createSeries(String label,
      {String prefix = '', String suffix = ''}) async {
    await _ensureAuthed();
    final id = const Uuid().v4();
    await _sb.from('forms_series').insert({
      'id': id,
      'series': label,
      'prefix': prefix,
      'suffix': suffix,
      'last_number': 0,
    });
    await load();
  }

  /// Удаляет серию по id.
  Future<void> remove(String id) async {
    await _ensureAuthed();
    await _sb.from('forms_series').delete().eq('id', id);
    await load();
  }

  /// Устанавливает точный номер для серии.
  Future<void> setNumber(String id, int n) async {
    await _ensureAuthed();
    await _sb.from('forms_series').update({
      'last_number': n,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', id);
    await load();
  }

  /// Инкрементирует номер серии (last_number + 1).
  Future<int> increment(String id) async {
    await _ensureAuthed();
    final rows = await _sb
        .from('forms_series')
        .select('last_number')
        .eq('id', id)
        .single();
    final cur = (rows['last_number'] ?? 0) as int;
    final next = cur + 1;
    await _sb.from('forms_series').update({'last_number': next}).eq('id', id);
    await load();
    return next;
  }

  /// Создать новую форму или вернуть существующую по уникальному `code` (series-number)
  /// Возвращает полную строку формы.
  Future<Map<String, dynamic>> createOrGetForm({
    required String series,
    required int number,
    String? title,
    String? productType,
    String? size,
    List<String>? colors,
    String? imageUrl,
    String status = 'in_stock',
    String? description,
  }) async {
    await _ensureAuthed();
    final code = '${series}-${number.toString().padLeft(3, '0')}';
    final payload = {
      'series': series.trim(),
      'number': number,
      'code': code,
      if (title != null) 'title': title.trim(),
      if (productType != null) 'product_type': productType.trim(),
      if (size != null) 'size': size.trim(),
      if (colors != null) 'colors': colors,
      if (imageUrl != null) 'image_url': imageUrl,
      'status': status,
      if (description != null) 'description': description.trim(),
    };
    // UPSERT по уникальному коду
    final res = await _sb
        .from('forms')
        .upsert(payload, onConflict: 'code')
        .select()
        .single();
    return Map<String, dynamic>.from(res);
  }

  /// Поиск форм по названию/серии/коду

  Future<List<Map<String, dynamic>>> searchForms(
      {String? query, int limit = 50}) async {
    await _ensureAuthed();
    final sel = _sb.from('forms').select();
    if (query != null && query.trim().isNotEmpty) {
      final ilike = '%' +
          query.trim().replaceAll('%', '\\%').replaceAll('_', '\\_') +
          '%';
      final filtered = sel.or('title.ilike.' +
          ilike +
          ',series.ilike.' +
          ilike +
          ',code.ilike.' +
          ilike);
      final rows =
          await filtered.order('updated_at', ascending: false).limit(limit);
      return List<Map<String, dynamic>>.from(rows);
    }
    final rows = await sel.order('updated_at', ascending: false).limit(limit);
    return List<Map<String, dynamic>>.from(rows);
  }
}
