class WorkplaceModel {
  final String id;
  final String name;
  final String? description;
  final List<String> positionIds;
  final bool hasMachine;
  final int maxConcurrentWorkers;
  final String? unit;
  final WorkplaceExecutionMode executionMode;

  /// Способ расчёта приладки. null = не выбран (обязателен при hasMachine).
  final PriladkaCalcMode? priladkaCalcMode;

  /// Цена за одну засчитанную приладку (₸).
  final double priladkaPrice;

  /// Делить ли количество этапа между участниками пропорционально
  /// отработанному времени.
  ///
  /// false — бригада обслуживает одну машину (Флексопечать, автоматы,
  /// Бабинорезка и т.п.): тираж делает станок, а не сумма человеко-часов,
  /// поэтому каждому участнику записывается полное количество, а разницу в
  /// оплате делает ставка помощника.
  final bool splitQuantityByTime;

  WorkplaceModel({
    required this.id,
    required this.name,
    this.description,
    required this.positionIds,
    this.hasMachine = false,
    this.maxConcurrentWorkers = 0,
    this.unit,
    this.executionMode = WorkplaceExecutionMode.joint,
    this.priladkaCalcMode,
    this.priladkaPrice = 0,
    this.splitQuantityByTime = true,
  });

  /// Преобразование модели рабочего места в [Map] для сохранения в базе данных.
  /// В Supabase это представление используется для вставки или обновления
  /// строки в таблице `workplaces`.
  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'description': description,
        'positionIds': positionIds,
        'has_machine': hasMachine,
        'max_concurrent_workers': maxConcurrentWorkers,
        'unit': unit,
        'execution_mode': executionMode.name,
        'priladka_calc_mode': priladkaCalcMode?.dbValue,
        'priladka_price': priladkaPrice,
        'split_quantity_by_time': splitQuantityByTime,
      };

  /// Создание модели из [Map], полученного из базы данных. Использует snake_case
  /// для чтения полей Supabase.
  factory WorkplaceModel.fromMap(Map<String, dynamic> map, String id) =>
      WorkplaceModel(
        id: id,
        name: (() {
          final candidates = [
            map['name'],
            map['title'],
            map['short_name'],
            map['code'],
            map['workplace_name'],
            map['stage_name'],
          ];
          for (final candidate in candidates) {
            if (candidate == null) continue;
            final text = candidate.toString().trim();
            if (text.isNotEmpty) return text;
          }
          return '';
        })(),
        description: map['description'] as String?,
        positionIds: List<String>.from(map['positionIds'] ?? []),
        hasMachine:
            map['has_machine'] as bool? ?? map['hasMachine'] as bool? ?? false,
        maxConcurrentWorkers: (map['max_concurrent_workers'] as int?) ??
            (map['maxConcurrentWorkers'] as int?) ??
            0,
        unit: map['unit'] as String?,
        executionMode:
            parseWorkplaceExecutionMode(map['execution_mode'] ?? map['executionMode']),
        priladkaCalcMode: parsePriladkaCalcMode(
            map['priladka_calc_mode'] ?? map['priladkaCalcMode']),
        priladkaPrice: (() {
          final raw = map['priladka_price'] ?? map['priladkaPrice'];
          if (raw is num) return raw.toDouble();
          return double.tryParse('$raw'.replaceAll(',', '.')) ?? 0.0;
        })(),
        // Значение по умолчанию — true: до применения миграции колонки нет,
        // и деление по времени должно работать так же, как на любом обычном
        // рабочем месте.
        //
        // Разбор через as bool? здесь недопустим: если драйвер отдаст булево
        // строкой, приведение бросит исключение и упадёт загрузка ВСЕГО
        // справочника рабочих мест. Неизвестное значение трактуем как true —
        // обычное поведение безопаснее, чем молча выключить деление и выдать
        // каждому участнику полный тираж.
        splitQuantityByTime: _parseSplitQuantityByTime(
          map['split_quantity_by_time'] ?? map['splitQuantityByTime'],
        ),
      );
}

bool _parseSplitQuantityByTime(dynamic raw) {
  if (raw is bool) return raw;
  if (raw is num) return raw != 0;
  if (raw is String) {
    switch (raw.trim().toLowerCase()) {
      case 'false':
      case 'f':
      case '0':
        return false;
      case 'true':
      case 't':
      case '1':
        return true;
    }
  }
  return true;
}

/// Способ расчёта приладки на рабочем месте с включённой приладкой.
enum PriladkaCalcMode { byColors, byOrder, bySize }

extension PriladkaCalcModeX on PriladkaCalcMode {
  /// Значение для БД (workplaces.priladka_calc_mode).
  String get dbValue {
    switch (this) {
      case PriladkaCalcMode.byColors:
        return 'by_colors';
      case PriladkaCalcMode.byOrder:
        return 'by_order';
      case PriladkaCalcMode.bySize:
        return 'by_size';
    }
  }

  String get label {
    switch (this) {
      case PriladkaCalcMode.byColors:
        return 'По краскам';
      case PriladkaCalcMode.byOrder:
        return 'По заказу';
      case PriladkaCalcMode.bySize:
        return 'По размеру';
    }
  }
}

PriladkaCalcMode? parsePriladkaCalcMode(dynamic raw) {
  final value = raw?.toString().trim().toLowerCase() ?? '';
  switch (value) {
    case 'by_colors':
    case 'bycolors':
      return PriladkaCalcMode.byColors;
    case 'by_order':
    case 'byorder':
      return PriladkaCalcMode.byOrder;
    case 'by_size':
    case 'bysize':
      return PriladkaCalcMode.bySize;
  }
  return null;
}

enum WorkplaceExecutionMode { separate, joint }

WorkplaceExecutionMode parseWorkplaceExecutionMode(dynamic raw) {
  final value = raw?.toString().trim().toLowerCase() ?? '';
  if (value.contains('separate') || value.contains('отдель')) {
    return WorkplaceExecutionMode.separate;
  }
  if (value.contains('joint') ||
      value.contains('совмест') ||
      value.contains('одиноч') ||
      value.contains('solo') ||
      value.contains('один')) {
    return WorkplaceExecutionMode.joint;
  }
  return WorkplaceExecutionMode.joint;
}