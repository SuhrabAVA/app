import '../personnel/workplace_model.dart';

/// Размеры продукта заказа для сравнения в режиме «По размеру».
/// null или значение <= 0 считается отсутствующим параметром.
class SetupDims {
  final double? width;
  final double? height;
  final double? depth;

  const SetupDims({this.width, this.height, this.depth});

  bool get isComplete =>
      _present(width) && _present(height) && _present(depth);

  static bool _present(double? v) => v != null && v > 0;
}

/// Результат подсчёта приладок при завершении наладки.
class SetupCountResult {
  /// Сколько приладок засчитать сотруднику.
  final double qty;

  /// Данные неполные (нет размеров/красок) — требуется проверка данных.
  final bool dataWarning;

  /// Пояснение для журнала/комментария.
  final String note;

  const SetupCountResult({
    required this.qty,
    this.dataWarning = false,
    this.note = '',
  });
}

/// Чистая логика подсчёта приладок по режиму рабочего места.
///
/// Режимы:
///  • byColors — приладок столько, сколько красок в заказе;
///  • byOrder  — ровно одна приладка за заказ;
///  • bySize   — приладка засчитывается, только если размеры заказа
///    (ширина/длина/глубина) отличаются от предыдущего заказа,
///    обработанного на этом рабочем месте (хронология выполнения).
///
/// Граничные случаи bySize:
///  • нет предыдущей наладки (первый заказ на месте) → приладка засчитывается;
///  • у текущего или предыдущего заказа отсутствует любой из размеров →
///    считается несовпадением (приладка засчитывается) + флаг dataWarning;
///  • все три размера совпали → 0 приладок.
///
/// mode == null (админ не выбрал способ) → 1 приладка (легаси-поведение)
/// с предупреждением.
SetupCountResult computeSetupCount({
  required PriladkaCalcMode? mode,
  int paintsCount = 0,
  SetupDims? currentDims,
  SetupDims? previousDims,
  bool hasPrevious = false,
}) {
  switch (mode) {
    case null:
      return const SetupCountResult(
        qty: 1,
        dataWarning: true,
        note: 'способ расчёта приладки не выбран — засчитана 1 приладка',
      );
    case PriladkaCalcMode.byOrder:
      return const SetupCountResult(qty: 1, note: 'по заказу');
    case PriladkaCalcMode.byColors:
      if (paintsCount <= 0) {
        return const SetupCountResult(
          qty: 0,
          dataWarning: true,
          note: 'по краскам: в заказе не указаны краски — 0 приладок',
        );
      }
      return SetupCountResult(
        qty: paintsCount.toDouble(),
        note: 'по краскам: $paintsCount',
      );
    case PriladkaCalcMode.bySize:
      final current = currentDims ?? const SetupDims();
      if (!hasPrevious) {
        return const SetupCountResult(
          qty: 1,
          note: 'по размеру: первый заказ на рабочем месте',
        );
      }
      if (!current.isComplete) {
        return const SetupCountResult(
          qty: 1,
          dataWarning: true,
          note: 'по размеру: у текущего заказа не заполнены размеры — '
              'засчитано как несовпадение',
        );
      }
      final previous = previousDims;
      if (previous == null || !previous.isComplete) {
        return const SetupCountResult(
          qty: 1,
          dataWarning: true,
          note: 'по размеру: у предыдущего заказа не заполнены размеры — '
              'засчитано как несовпадение',
        );
      }
      final same = _dimEquals(current.width, previous.width) &&
          _dimEquals(current.height, previous.height) &&
          _dimEquals(current.depth, previous.depth);
      if (same) {
        return const SetupCountResult(
          qty: 0,
          note: 'по размеру: размеры совпадают с предыдущим заказом — '
              'переналадка не требовалась',
        );
      }
      return const SetupCountResult(
        qty: 1,
        note: 'по размеру: размеры отличаются от предыдущего заказа',
      );
  }
}

bool _dimEquals(double? a, double? b) {
  if (a == null || b == null) return false;
  return (a - b).abs() < 1e-9;
}

/// Маркер количества приладок в тексте комментария setup_done.
/// Формат: «приладок: N». Аналитика (TaskAnalyticsMapper) разбирает его,
/// чтобы принять и явный 0; старые комментарии без маркера = 1 приладка.
String setupDoneCommentText(double qty, {String note = ''}) {
  final n = qty % 1 == 0 ? qty.toStringAsFixed(0) : qty.toString();
  final suffix = note.isEmpty ? '' : ' — $note';
  return 'Завершил(а) настройку станка (приладок: $n)$suffix';
}
