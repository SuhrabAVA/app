/// Расход бумаги по факту на первом рулонном этапе (правило от 15.09.2026).
///
/// Бумага списывается не по брони, а по тому, что написали сотрудники этапа
/// бумаги: первого по маршруту из Бабинорезки/Флексопечати, без них — первого
/// шага. Каждый исполнитель и каждая смена пишут свою часть (пересмена,
/// «Завершить участие», закрытие этапа), и записанное сразу уходит со склада.
/// Сервер — `record_order_paper_usage` и `order_paper_usage_state`
/// (миграция 20260915_integrity_16).
library;

import '../tasks/task_model.dart';

/// Когда сотрудник пишет расход.
enum PaperUsageKind { shift, participant, finish }

extension PaperUsageKindWire on PaperUsageKind {
  String get wire => switch (this) {
        PaperUsageKind.shift => 'shift',
        PaperUsageKind.participant => 'participant',
        PaperUsageKind.finish => 'finish',
      };
}

double _toDouble(Object? raw) {
  if (raw is num) return raw.toDouble();
  return double.tryParse((raw ?? '').toString().trim().replaceAll(',', '.')) ??
      0;
}

/// Одна бумага заказа глазами окна расхода.
class PaperUsageRow {
  const PaperUsageRow({
    required this.slotIndex,
    required this.paperId,
    required this.name,
    required this.format,
    required this.grammage,
    required this.unit,
    required this.inOrder,
    required this.plan,
    required this.written,
    required this.reserved,
    required this.stock,
    required this.availableForOrder,
  });

  factory PaperUsageRow.fromJson(Map<String, dynamic> json) => PaperUsageRow(
        slotIndex: _toDouble(json['slot_index']).toInt(),
        paperId: (json['paper_id'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        format: (json['format'] ?? '').toString(),
        grammage: (json['grammage'] ?? '').toString(),
        unit: (json['unit'] ?? 'м').toString(),
        inOrder: json['in_order'] != false,
        plan: _toDouble(json['plan']),
        written: _toDouble(json['written']),
        reserved: _toDouble(json['reserved']),
        stock: _toDouble(json['stock']),
        availableForOrder: _toDouble(json['available_for_order']),
      );

  final int slotIndex;
  final String paperId;
  final String name;
  final String format;
  final String grammage;
  final String unit;

  /// false — бумагу уже списали, но из заказа её убрали (заменили другой).
  final bool inOrder;

  /// «Длина L» бумаги в заказе.
  final double plan;

  /// Уже списано по заказу (все смены, все круги этапа).
  final double written;

  /// Бронь заказа по этой бумаге.
  final double reserved;

  /// Остаток на складе целиком.
  final double stock;

  /// Сколько можно списать для этого заказа: остаток минус брони других.
  final double availableForOrder;

  /// Остаток плана — то, что подставляется в поле расхода.
  double get remaining {
    final value = plan - written;
    return value > 0 ? value : 0;
  }

  String get title {
    final spec = [format.trim(), grammage.trim()]
        .where((part) => part.isNotEmpty)
        .join('/');
    return [name.trim(), spec].where((part) => part.isNotEmpty).join(' ');
  }
}

/// Бумага заказа целиком.
class PaperUsageState {
  const PaperUsageState({
    required this.stageKey,
    required this.closed,
    required this.hasFactUsage,
    required this.papers,
  });

  factory PaperUsageState.fromJson(Map<String, dynamic> json) {
    final raw = json['papers'];
    return PaperUsageState(
      stageKey: (json['stage_key'] ?? '').toString(),
      closed: json['closed'] == true,
      hasFactUsage: json['has_fact_usage'] == true,
      papers: raw is List
          ? raw
              .whereType<Map>()
              .map((row) => PaperUsageRow.fromJson(Map<String, dynamic>.from(row)))
              .where((row) => row.paperId.isNotEmpty)
              .toList(growable: false)
          : const <PaperUsageRow>[],
    );
  }

  /// Групповой ключ этапа бумаги; пусто — у заказа нет маршрута.
  final String stageKey;

  /// Этап бумаги закрыт: остаток брони снят, длины в заказе — итог.
  final bool closed;

  /// Есть расход, записанный сотрудниками (а не списанный по брони).
  final bool hasFactUsage;

  final List<PaperUsageRow> papers;

  /// Бумага, которую можно писать в окне: всё, что есть в заказе.
  List<PaperUsageRow> get orderPapers =>
      papers.where((row) => row.inOrder).toList(growable: false);

  double get totalWritten =>
      papers.fold<double>(0, (sum, row) => sum + row.written);

  /// Списано по конкретной бумаге (для «Длина: 3000 м · списано 1200 м»).
  Map<String, double> get writtenByPaperId => {
        for (final row in papers)
          if (row.written > 0) row.paperId: row.written,
      };

  /// Этот ли этап пишет расход бумаги.
  bool isPaperStage(TaskModel task) =>
      isPaperUsageStage(stageKey: stageKey, task: task);
}

/// Этап задачи совпадает с этапом бумаги заказа.
///
/// Ключ сервера — групповой (`stage_group_key`, а без него `stage_id`), как в
/// `order_paper_writeoff_stage_key`; сравниваем обоими способами, чтобы не
/// промахнуться у задач с пустым групповым ключом.
bool isPaperUsageStage({required String stageKey, required TaskModel task}) {
  final key = stageKey.trim();
  if (key.isEmpty) return false;
  final group = task.stageGroupKey.trim();
  final stageId = task.stageId.trim();
  return (group.isNotEmpty ? group : stageId) == key || stageId == key;
}

/// Проверка одного поля расхода. `null` — всё в порядке.
///
/// Больше, чем есть на складе для заказа, записать нельзя: сервер тоже
/// откажет, но сотрудник должен увидеть причину до нажатия.
String? validatePaperUsageInput(String raw, PaperUsageRow row) {
  final text = raw.trim().replaceAll(',', '.');
  if (text.isEmpty) return 'Укажите расход (0, если эта бумага не шла).';
  final value = double.tryParse(text);
  if (value == null) return 'Расход должен быть числом.';
  if (value < 0) return 'Расход не может быть отрицательным.';
  if (value - row.availableForOrder > 0.0005) {
    return 'На складе для заказа только ${formatPaperMeters(row.availableForOrder)} м. '
        'Сохранить нельзя, пока склад не пополнят.';
  }
  return null;
}

/// Метры без лишних нулей: 1200, 1200.5, 0.25.
String formatPaperMeters(double value) {
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  return value
      .toStringAsFixed(3)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

/// Подпись «списано» в деталях заказа, пока этап бумаги идёт.
///
/// После закрытия этапа длина в заказе уже равна итогу, и повторять её
/// рядом незачем.
String? paperWrittenSuffix({
  required PaperUsageState? state,
  required String? paperId,
}) {
  if (state == null || state.closed) return null;
  final id = (paperId ?? '').trim();
  if (id.isEmpty) return null;
  final written = state.writtenByPaperId[id];
  if (written == null || written <= 0) return null;
  return 'списано ${formatPaperMeters(written)} м';
}
