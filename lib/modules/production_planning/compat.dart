// lib/modules/production_planning/compat.dart
//
// Совместимость для экранов производства.
// Экспортирует pcompat.PlannedStage и pcompat.decodePlannedStages/encodePlannedStages.
//
// Дефолтный конструктор принимает ИМЕНОВАННЫЕ параметры:
//   PlannedStage(stageId: 'id', stageName: 'Печать', order: 1)
// Для обратной совместимости есть конструктор с позиционными аргументами:
//   PlannedStage.positional('id', 'Печать', 1)
//
// Понимает разные варианты ключей: stage_id/stageId/id, stage_name/stageName/name/title, order/position/idx.

class PlannedStage {
  String stageId;
  String stageName;
  int order;
  Map<String, dynamic> extra;

  // Именованные параметры
  PlannedStage({
    String? stageId,
    required String stageName,
    int order = 0,
    Map<String, dynamic>? extra,
  })  : stageId = stageId ?? '',
        stageName = stageName,
        order = order,
        extra = extra ?? {};

  // Обратная совместимость — позиционные параметры
  PlannedStage.positional([
    String? stageId,
    String? stageName,
    int? order,
    Map<String, dynamic>? extra,
  ])  : stageId = stageId ?? '',
        stageName = stageName ?? '',
        order = order ?? 0,
        extra = extra ?? {};

  // Алиас для старого кода
  factory PlannedStage.named({
    String? stageId,
    required String stageName,
    int order = 0,
    Map<String, dynamic>? extra,
  }) =>
      PlannedStage(
        stageId: stageId,
        stageName: stageName,
        order: order,
        extra: extra,
      );

  factory PlannedStage.fromMap(Map<String, dynamic> m) {
    final workplaceIds =
        _readStringList(m['workplaceIds'] ?? m['workplace_ids']);
    final legacyAlternatives = _readStringList(
      m['alternativeStageIds'] ?? m['alternative_stage_ids'],
    );
    final rawId = workplaceIds.isNotEmpty
        ? workplaceIds.first
        : (m['stage_id'] ??
                m['stageId'] ??
                m['workplaceId'] ??
                m['workplace_id'] ??
                m['id'] ??
                m['code'])
            ?.toString();
    final allWorkplaces = _dedupeOrdered(
      workplaceIds.isNotEmpty
          ? workplaceIds
          : [rawId ?? '', ...legacyAlternatives],
    );
    final name = (m['stage_name'] ?? m['stageName'] ?? m['name'] ?? m['title'])
            ?.toString() ??
        '';
    final o = m['order'] ?? m['position'] ?? m['idx'] ?? 0;

    final result = PlannedStage(
      stageId: allWorkplaces.isNotEmpty ? allWorkplaces.first : rawId,
      stageName: name,
      order: (o is int) ? o : int.tryParse(o.toString()) ?? 0,
    );
    // сохраняем исходные поля как extra + канонические ключи
    final mm = Map<String, dynamic>.from(m);
    mm['stage_id'] = result.stageId.isEmpty ? name : result.stageId;
    mm['stageId'] = result.stageId.isEmpty ? name : result.stageId;
    mm['workplaceId'] = result.stageId.isEmpty ? name : result.stageId;
    if (allWorkplaces.isNotEmpty) {
      mm['workplaceIds'] = allWorkplaces;
      mm['alternativeStageIds'] = allWorkplaces.skip(1).toList();
    }
    mm['stage_name'] = name;
    mm['order'] = result.order;
    result.extra = mm;
    return result;
  }

  Map<String, dynamic> toMap() {
    // Каноническая форма + всё extra
    return <String, dynamic>{
      'stage_id': stageId.isEmpty ? stageName : stageId,
      'stage_name': stageName,
      'order': order,
      ...extra,
    };
  }

  PlannedStage copyWith({
    String? stageId,
    String? stageName,
    int? order,
    Map<String, dynamic>? extra,
  }) {
    return PlannedStage(
      stageId: stageId ?? this.stageId,
      stageName: stageName ?? this.stageName,
      order: order ?? this.order,
      extra: extra ?? Map<String, dynamic>.from(this.extra),
    );
  }
}

List<String> _readStringList(dynamic raw) {
  if (raw is List) return raw.map((e) => e.toString()).toList();
  if (raw is String && raw.trim().isNotEmpty) {
    return raw.split(',').map((e) => e.trim()).toList();
  }
  return const [];
}

List<String> _dedupeOrdered(List<String> values) {
  final seen = <String>{};
  final result = <String>[];
  for (final value in values) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) continue;
    if (!seen.add(trimmed.toLowerCase())) continue;
    result.add(trimmed);
  }
  return result;
}

// Универсальный парсер в список PlannedStage
List<PlannedStage> decodePlannedStages(dynamic raw) {
  final list = _normalizeStagesList(raw);
  final out = <PlannedStage>[];

  for (final item in list) {
    if (item is Map<String, dynamic>) {
      out.add(PlannedStage.fromMap(item));
    } else if (item is Map) {
      out.add(PlannedStage.fromMap(Map<String, dynamic>.from(item)));
    }
  }

  // сортировка по order
  out.sort((a, b) => a.order.compareTo(b.order));
  return out;
}

// Обратная запись в JSON-совместимую структуру
List<Map<String, dynamic>> encodePlannedStages(List<PlannedStage> stages) {
  final enc = stages.map((e) => e.toMap()).toList();
  enc.sort((a, b) {
    final ai = a['order'] is int
        ? a['order'] as int
        : int.tryParse('${a['order']}') ?? 0;
    final bi = b['order'] is int
        ? b['order'] as int
        : int.tryParse('${b['order']}') ?? 0;
    return ai.compareTo(bi);
  });
  return enc;
}

// --------------------- helpers ---------------------

List _normalizeStagesList(dynamic raw) {
  if (raw == null) return const [];
  if (raw is List) return raw;
  if (raw is Map) {
    // Старый вид: {"1": {...}, "2": {...}}
    final items = <Map<String, dynamic>>[];
    raw.forEach((k, v) {
      if (v is Map) {
        final m = Map<String, dynamic>.from(v);
        m['order'] = m['order'] ?? int.tryParse(k.toString()) ?? 0;
        items.add(m);
      }
    });
    return items;
  }
  return const [];
}
