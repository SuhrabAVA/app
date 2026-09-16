/// Справочник режимов очерёдности и правила выбора партнёра.
///
/// Здесь только чистые функции: редактор их зовёт, чтобы не предлагать
/// заведомо отвергаемый выбор, а рантаймовые фазы T5–T6 будут читать те же
/// значения. Инварианты повторяют validate_product_type_config — сервер
/// остаётся последним словом, но отказ, который видно только при публикации,
/// техлиду ничего не объясняет.
library;

import 'product_type_route.dart';

/// Значения `product_type_stages.execution_mode` в порядке показа.
const List<String> kExecutionModes = <String>[
  'sequential',
  'free_of_chain',
  'parallel_with',
  'parallel_with_previous',
];

/// Короткая подпись режима для выпадающего списка.
String executionModeLabel(String mode) => switch (mode) {
      'sequential' => 'Строго после предыдущего',
      'free_of_chain' => 'Не ждёт предыдущий этап',
      'parallel_with' => 'Параллельно с выбранным этапом',
      'parallel_with_previous' => 'Параллельно с предыдущим',
      _ => mode,
    };

/// Чем режим отличается на практике — показывается под списком.
///
/// Два независимых свойства, которые легко перепутать: ждать ли ЗАВЕРШЕНИЯ
/// предыдущего этапа этого заказа и держать ли очередь МЕЖДУ заказами.
String executionModeHint(String mode) => switch (mode) {
      'sequential' =>
        'Начинается, когда предыдущий этап заказа полностью завершён. '
            'Очередь между заказами соблюдается.',
      'free_of_chain' =>
        'Не ждёт предыдущий этап заказа, но своей очереди среди заказов '
            'дожидается.',
      'parallel_with' =>
        'Начинается, как только НАЧАТ выбранный этап. Очередь между заказами '
            'не держит.',
      'parallel_with_previous' =>
        'То же, но партнёром считается этап, оказавшийся предыдущим в '
            'собранной очереди заказа. Так сегодня работает упаковка.',
      _ => '',
    };

/// Этапы, которые можно выбрать партнёром для [stage].
///
/// Правила ровно те же, что у проверок parallel_partner_after_stage и
/// parallel_partner_unreachable:
///   * партнёр стоит СТРОГО раньше по рангу — иначе этап ждал бы того, чего к
///     его моменту ещё не начали;
///   * под-этап чужого варианта партнёром быть не может: при невыборе того
///     варианта он вообще не появится в очереди, и ждущий этап не начнётся
///     никогда. Обратное направление разрешено — под-этап может ждать общий
///     этап верхнего уровня, тот есть всегда.
List<RouteStage> eligiblePartners(ProductTypeRoute route, RouteStage stage) {
  final result = <RouteStage>[
    for (final candidate in route.stages)
      if (candidate.rowId != stage.rowId &&
          candidate.position < stage.position &&
          _isReachableFrom(stage, candidate))
        candidate,
  ];
  result.sort((a, b) {
    final byPosition = a.position.compareTo(b.position);
    if (byPosition != 0) return byPosition;
    return a.key.compareTo(b.key);
  });
  return result;
}

bool _isReachableFrom(RouteStage stage, RouteStage candidate) {
  if (candidate.level != 1) return true;
  return stage.level == 1 && stage.parentVariantId == candidate.parentVariantId;
}

/// Подпись режима в строке этапа: `null` — показывать нечего.
///
/// Для `sequential` возвращает null намеренно: это режим по умолчанию у
/// подавляющего большинства этапов, и подпись у каждой строки превратилась бы
/// в шум, на фоне которого не видно исключений.
String? executionSummary(ProductTypeRoute route, RouteStage stage) {
  switch (stage.executionMode) {
    case 'sequential':
      return null;
    case 'free_of_chain':
      return 'не ждёт предыдущий этап';
    case 'parallel_with_previous':
      return 'параллельно с предыдущим';
    case 'parallel_with':
      final partner = partnerOf(route, stage);
      return partner == null
          ? 'параллельно с этапом: партнёр не выбран'
          : 'параллельно с «${partner.title}»';
    default:
      return stage.executionMode;
  }
}

/// Этап-партнёр или `null`, если он не выбран либо не найден в этой версии.
RouteStage? partnerOf(ProductTypeRoute route, RouteStage stage) {
  final partnerId = stage.parallelWithStageId;
  if (partnerId == null) return null;
  for (final candidate in route.stages) {
    if (candidate.rowId == partnerId) return candidate;
  }
  return null;
}

/// Этапы, которые ссылаются на [stage] как на партнёра.
///
/// Нужны удалению: `parallel_with_stage_id` объявлен ON DELETE RESTRICT, и без
/// этого списка техлид увидел бы только код нарушения внешнего ключа.
List<RouteStage> dependentsOf(ProductTypeRoute route, RouteStage stage) =>
    <RouteStage>[
      for (final candidate in route.stages)
        if (candidate.parallelWithStageId == stage.rowId) candidate,
    ];
