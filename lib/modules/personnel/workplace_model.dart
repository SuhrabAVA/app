class WorkplaceModel {
  final String id;
  final String name;
  final String? description;
  final List<String> positionIds;
  final bool hasMachine;
  final int maxConcurrentWorkers;
  final String? unit;
  final WorkplaceExecutionMode executionMode;

  WorkplaceModel({
    required this.id,
    required this.name,
    this.description,
    required this.positionIds,
    this.hasMachine = false,
    this.maxConcurrentWorkers = 0,
    this.unit,
    this.executionMode = WorkplaceExecutionMode.joint,
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
      );
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
