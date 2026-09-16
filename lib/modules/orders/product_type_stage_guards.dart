/// Правила, запрещающие правку маршрута, — чистыми функциями.
///
/// Вынесены из виджета панели рабочих мест: это логика, в порядке которой уже
/// был дефект (при ровно двух вариантах подсказка «назначьте по умолчанию
/// другой» вела в тупик — после переназначения удаление всё равно оставалось
/// заблокированным). Логика, где однажды ошиблись в порядке условий, обязана
/// быть проверяемой без поднятия виджета.
///
/// Возвращают причину отказа для подсказки или null, если действие можно.
/// Молчаливый отказ после нажатия здесь недопустим: кнопка становится
/// неактивной, а причина уходит в tooltip.
library;

import 'product_type_execution_options.dart';
import 'product_type_route.dart';

/// Почему нельзя убрать рабочее место из этапа; null — можно.
///
/// ПОРЯДОК ПРАВИЛ ЗНАЧИМ. Проверка «вариантов меньше двух» идёт ПЕРВОЙ и не
/// смотрит на признак по умолчанию: иначе при ровно двух вариантах техлид
/// получил бы совет переназначить вариант по умолчанию, выполнил бы его — и
/// упёрся в ту же неактивную кнопку. Правило про вариант по умолчанию
/// осмысленно только когда вариантов три и больше.
String? workplaceDeleteBlockedReason(
  RouteStage stage,
  RouteStageWorkplace workplace,
) {
  final count = stage.workplaces.length;

  if (stage.isSwitchable) {
    if (count <= 2) {
      return 'Переключаемому этапу нужно не меньше двух вариантов. '
          'Чтобы оставить один — переключите этап в режим «все рабочие места»';
    }
    if (workplace.isDefault) {
      return 'Сначала назначьте вариантом по умолчанию другой';
    }
    return null;
  }

  if (count <= 1) {
    return 'Этап без рабочего места не попадёт в план — удалите этап целиком';
  }
  return null;
}

/// Почему нельзя удалить этап; null — можно.
///
/// `parallel_with_stage_id` объявлен ON DELETE RESTRICT намеренно: обнуление
/// оставило бы зависимый этап в режиме «параллельно» без партнёра, то есть в
/// невалидном состоянии, о котором техлид узнал бы только при публикации. Но
/// голый отказ внешнего ключа ему ничего не скажет, поэтому зависимые этапы
/// перечисляем ДО вызова и удаление блокируем здесь.
///
/// Под-этапы удаляемого этапа в перечисление не входят: они уйдут каскадом
/// вместе с ним, и их собственные ссылки исчезнут заодно.
String? stageDeleteBlockedReason(ProductTypeRoute route, RouteStage stage) {
  final dependents = <RouteStage>[
    for (final dependent in dependentsOf(route, stage))
      if (!_isDescendantOf(route, dependent, stage)) dependent,
  ];
  if (dependents.isEmpty) return null;

  final names = dependents.map((s) => '«${s.title}»').join(', ');
  return 'Сначала смените режим у этапов, идущих параллельно с этим: $names';
}

/// Уйдёт ли [candidate] каскадом вместе с [stage] — то есть является ли он
/// под-этапом одного из вариантов этого этапа.
bool _isDescendantOf(
  ProductTypeRoute route,
  RouteStage candidate,
  RouteStage stage,
) {
  final parentVariantId = candidate.parentVariantId;
  if (parentVariantId == null) return false;
  return stage.workplaces.any((w) => w.rowId == parentVariantId);
}

/// Почему нельзя сменить режим этапа; null — можно.
///
/// Обратный переход (one_of → all) не запрещён никогда: он разрушителен, но
/// об этом предупреждает диалог со списком под-этапов, а не блокировка.
String? selectionModeChangeBlockedReason(RouteStage stage) {
  if (!stage.isSwitchable && stage.workplaces.length < 2) {
    return 'Добавьте второе рабочее место, чтобы сделать этап переключаемым';
  }
  return null;
}
