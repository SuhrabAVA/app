// lib/modules/production_planning/template_provider.dart
//
// Полная версия провайдера шаблонов производственного плана,
// использующая отдельную таблицу `public.plan_templates` (а не documents).
// Реализовано: загрузка, realtime-подписка, создание/обновление/удаление.
// Совместима с существующими TemplateModel/PlannedStage через fromMap/toMap.
//
// Таблица ожидается со схемой (см. create_plan_templates.sql):
//   id uuid PK, name text, description text, stages jsonb[], is_archived bool,
//   created_by uuid, created_at timestamptz, updated_at timestamptz
//
// Если колонки description/is_archived отсутствуют — запустите миграцию
// migrate_plan_templates_existing.sql из ранее отправленного архива.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'template_model.dart';
import 'planned_stage_model.dart';

class TemplateDeleteException implements Exception {
  TemplateDeleteException(this.message);

  final String message;

  @override
  String toString() => message;
}

class TemplateProvider with ChangeNotifier {
  final _uuid = const Uuid();
  final SupabaseClient _supabase = Supabase.instance.client;

  final List<TemplateModel> _templates = [];
  RealtimeChannel? _tplChannel;

  bool _loading = false;
  Object? _lastError;

  List<TemplateModel> get templates => List.unmodifiable(_templates);
  bool get isLoading => _loading;
  Object? get lastError => _lastError;

  TemplateProvider() {
    _listenTemplates();
  }

  // -------------------------------
  // Internal utils
  // -------------------------------

  Future<void> _fetchAndSetTemplates({bool includeArchived = false}) async {
    _loading = true;
    _lastError = null;
    notifyListeners();
    try {
      final query = _supabase
          .from('plan_templates')
          .select('id, name, description, stages, is_archived');

      if (!includeArchived) {
        query.eq('is_archived', false);
      }

      query.order('name');

      final rows = await query;

      _templates
        ..clear()
        ..addAll((rows as List).map((row) {
          final r = Map<String, dynamic>.from(row as Map);

          // Гарантии структуры для TemplateModel.fromMap
          final data = <String, dynamic>{
            'id': r['id'],
            'name': r['name'],
            'description': r['description'],
            'stages': _normalizeStages(r['stages']),
          };

          return TemplateModel.fromMap(data);
        }));
    } catch (e) {
      _lastError = e;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  List<Map<String, dynamic>> _normalizeStages(dynamic raw) {
    List<Map<String, dynamic>> _sortByOrder(List<Map<String, dynamic>> list) {
      final entries = list.asMap().entries.toList();
      int _orderOf(Map<String, dynamic> m, int fallback) {
        final rawOrder = m['order'] ?? m['step'] ?? m['position'];
        if (rawOrder is num) return rawOrder.toInt();
        if (rawOrder is String) {
          final parsed = int.tryParse(rawOrder);
          if (parsed != null) return parsed;
        }
        return fallback;
      }

      entries.sort((a, b) {
        final ao = _orderOf(a.value, a.key);
        final bo = _orderOf(b.value, b.key);
        final cmp = ao.compareTo(bo);
        if (cmp != 0) return cmp;
        return a.key.compareTo(b.key);
      });

      return entries.map((e) => e.value).toList();
    }

    if (raw == null) return const [];
    if (raw is List) {
      final list = raw.map<Map<String, dynamic>>((e) {
        if (e is Map<String, dynamic>) return e;
        if (e is Map) return Map<String, dynamic>.from(e);
        return <String, dynamic>{};
      }).toList();
      return _sortByOrder(list);
    }
    if (raw is Map) {
      // Старый словарный формат {"1": {...}, "2": {...}}
      final list = (raw as Map).entries.map<Map<String, dynamic>>((e) {
        final v = Map<String, dynamic>.from(e.value as Map);
        v['order'] = int.tryParse(e.key.toString()) ?? v['order'] ?? 0;
        return v;
      }).toList();
      return _sortByOrder(list);
    }
    return const [];
  }

  void _listenTemplates() {
    // 1) Первичная загрузка
    // (без архивных по умолчанию)
    _fetchAndSetTemplates(includeArchived: false);

    // 2) Переподписка на realtime
    if (_tplChannel != null) {
      _supabase.removeChannel(_tplChannel!);
      _tplChannel = null;
    }

    _tplChannel = _supabase.channel('plan_templates_changes');

    // Следим за любыми изменениями в таблице
    _tplChannel!
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'plan_templates',
          callback: (payload) {
            // На любое изменение — перезагружаем список
            _fetchAndSetTemplates(includeArchived: false);
          },
        )
        .subscribe();
  }

  // -------------------------------
  // Public API
  // -------------------------------

  /// Ручная перезагрузка (напр. с показом архивных)
  Future<void> fetchAll(
      {bool includeArchived = false, bool force = true}) async {
    if (!force && _templates.isNotEmpty) return;
    await _fetchAndSetTemplates(includeArchived: includeArchived);
  }

  /// Создание шаблона.
  /// Возвращает id созданной записи (uuid).
  Future<String> createTemplate({
    required String name,
    required List<PlannedStage> stages,
    String? description,
    bool archived = false,
  }) async {
    final id = _uuid.v4();
    final payload = {
      'id': id,
      'name': name,
      'description': description,
      'stages': stages.map((s) => s.toMap()).toList(),
      'is_archived': archived,
    };

    await _supabase.from('plan_templates').insert(payload);
    // Realtime сам подтянет, но обновим локально быстрее
    await _fetchAndSetTemplates(includeArchived: false);
    return id;
  }

  /// Обновление шаблона по id.
  Future<void> updateTemplate({
    required String id,
    required String name,
    required List<PlannedStage> stages,
    String? description,
    bool? archived,
  }) async {
    final payload = <String, dynamic>{
      'name': name,
      'stages': stages.map((s) => s.toMap()).toList(),
      'description': description,
    };

    if (archived != null) payload['is_archived'] = archived;

    await _supabase.from('plan_templates').update(payload).eq('id', id);
    await _fetchAndSetTemplates(includeArchived: false);
  }

  /// Удаление шаблона.
  /// По умолчанию — мягкое (архивация). Для полного удаления укажи hard: true.
  Future<void> deleteTemplate(String id, {bool hard = false}) async {
    Future<bool> hardDelete() async {
      final deleted = await _supabase
          .from('plan_templates')
          .delete()
          .eq('id', id)
          .select('id');
      return (deleted as List).isNotEmpty;
    }

    Future<bool> archiveTemplate() async {
      final updated = await _supabase
          .from('plan_templates')
          .update({'is_archived': true})
          .eq('id', id)
          .select('id');
      return (updated as List).isNotEmpty;
    }

    try {
      bool affected = false;
      if (hard) {
        affected = await hardDelete();
      } else {
        try {
          affected = await archiveTemplate();
        } on PostgrestException catch (e) {
          // На старых инсталляциях update недоступен, либо нет колонки.
          // Тогда пытаемся удалить запись физически.
          if (e.code == '42703' || e.code == '42501' || e.code == 'PGRST204') {
            affected = await hardDelete();
          } else {
            rethrow;
          }
        }
      }

      if (!affected) {
        throw TemplateDeleteException(
          'Шаблон не был удалён: недостаточно прав или шаблон уже удалён.',
        );
      }
    } on PostgrestException catch (e) {
      if (e.code == '23503') {
        throw TemplateDeleteException(
          'Шаблон используется в заказах и не может быть удалён. '
          'Снимите шаблон в связанных заказах или включите ON DELETE SET NULL для orders.stage_template_id.',
        );
      }

      if (e.code == '42501') {
        throw TemplateDeleteException(
          'Недостаточно прав для удаления шаблона (RLS/policy). '
          'Нужно разрешить UPDATE/DELETE для plan_templates.',
        );
      }

      throw TemplateDeleteException('Ошибка удаления шаблона: ${e.message}');
    } catch (e) {
      throw TemplateDeleteException('Ошибка удаления шаблона: $e');
    }

    await _fetchAndSetTemplates(includeArchived: false);
  }

  /// Снятие архива (вернуть в активные).
  Future<void> unarchiveTemplate(String id) async {
    await _supabase
        .from('plan_templates')
        .update({'is_archived': false}).eq('id', id);
    await _fetchAndSetTemplates(includeArchived: false);
  }

  @override
  void dispose() {
    if (_tplChannel != null) {
      _supabase.removeChannel(_tplChannel!);
      _tplChannel = null;
    }
    super.dispose();
  }
}
