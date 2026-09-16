/// Тип ручки изделия.
///
/// Доменное понятие заказа: выбирается в форме заказа и определяет, какой этап
/// добавит автосборщик очереди (правила R25–R28 в `stage_queue_builder.dart`).
/// Раньше жил в `order_stage_filter.dart` вместе с мёртвой логикой фильтрации —
/// вынесен отдельно, чтобы файл-фильтр можно было удалить.
enum OrderHandleType { none, flat, twisted, dieCut }

/// Тип ручки по её описанию из формы заказа.
///
/// Форма хранит ручку СТРОКОЙ — описанием из справочника ручек, — а правила
/// маршрута и обязательности блоков спрашивают про тип. Разбор жил приватным
/// методом внутри формы заказа; после того как тот же разбор понадобился
/// проверке блоков, он переехал сюда: две копии сопоставления разошлись бы на
/// первом же новом названии ручки.
OrderHandleType orderHandleTypeFromDescription(String? description) {
  final normalized = (description ?? '').trim().toLowerCase();
  if (normalized.isEmpty || normalized == '-') return OrderHandleType.none;
  if (normalized.contains('круч') || normalized.contains('twist')) {
    return OrderHandleType.twisted;
  }
  if (normalized.contains('плоск') || normalized.contains('flat')) {
    return OrderHandleType.flat;
  }
  if (normalized.contains('выруб') || normalized.contains('die cut')) {
    return OrderHandleType.dieCut;
  }
  return OrderHandleType.none;
}
