/// Диалоги-предупреждения редактора маршрута.
///
/// Оба закрывают один и тот же класс дефекта: действие уносит с собой то, о
/// чём техлид не просил и чего не видит на экране. Перечисление строится из
/// уже загруженного маршрута, лишнего запроса не нужно.
library;

import 'package:flutter/material.dart';

import '../orders/product_type_route.dart';
import '../orders/product_type_settings.dart';

/// Удаление рабочего места, которое является вариантом с под-этапами.
///
/// `product_type_stages.parent_variant_id` ссылается на
/// `product_type_stage_workplaces` с ON DELETE CASCADE, поэтому обычный DELETE
/// одной строки бесшумно уносит под-этапы: убрать «Трубу» из переключателя
/// П-образного пакета значит потерять «Сборку дно+картон» и «Склейку дна».
/// Атомарности здесь достаточно (это один оператор), не хватало именно голоса.
Future<bool> confirmVariantDeletion(
  BuildContext context, {
  required String variantTitle,
  required List<RouteStage> subStages,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Удалить вариант «$variantTitle»?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (subStages.isEmpty)
            const Text('Вариант будет убран из переключаемого этапа.')
          else ...[
            const Text('Вместе с вариантом будут удалены его под-этапы:'),
            const SizedBox(height: 8),
            for (final stage in subStages)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('•  ${stage.title}'),
              ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(subStages.isEmpty
              ? 'Удалить вариант'
              : 'Удалить вариант и под-этапы'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Смена режима этапа.
///
/// Оба направления меняют то, что оператор увидит в очереди: для `one_of` имя
/// берётся из подписи выбранного варианта, для `all` — из названия этапа.
/// Без предупреждения техлид переключил бы тумблер и не понял, почему в
/// очереди другое слово.
///
/// Направление one_of → all вдобавок удаляет под-этапы вариантов: условие
/// «выбран вариант X» перестаёт существовать, и переинтерпретировать их не во
/// что. Каскад здесь НЕ срабатывает сам — строки рабочих мест не удаляются, —
/// поэтому без явного удаления под-этапы остались бы жить у более не
/// переключаемого этапа, а техлид узнал бы об этом при публикации.
Future<bool> confirmSelectionModeChange(
  BuildContext context, {
  required RouteStage stage,
  required String targetMode,
  required List<RouteStage> subStages,
  required ProductTypeRoute route,
}) async {
  final toOneOf = targetMode == 'one_of';
  final defaultVariantTitle = _defaultVariantTitle(stage);

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(toOneOf
          ? 'Сделать «${stage.title}» переключаемым?'
          : 'Переключить «${stage.title}» в режим «все рабочие места»?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(toOneOf
                ? 'Рабочие места станут альтернативами: в план пойдёт только '
                    'выбранный вариант.'
                : 'Варианты перестанут быть альтернативами: в план пойдут все '
                    '${stage.workplaces.length} рабочих мест сразу, одним шагом.'),
            if (!toOneOf && subStages.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('Будут удалены под-этапы, привязанные к вариантам:'),
              const SizedBox(height: 6),
              for (final sub in subStages)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('•  ${sub.title}'
                      '${_ownerSuffix(sub, route)}'),
                ),
            ],
            const SizedBox(height: 12),
            Text(
              toOneOf
                  ? 'Название этапа в очереди станет названием выбранного '
                      'варианта${defaultVariantTitle == null ? '' : ' (по умолчанию «$defaultVariantTitle»)'} '
                      'вместо «${stage.title}». Подписи вариантов заполнятся '
                      'именами рабочих мест.'
                  : 'Название этапа в очереди станет «${stage.title}» вместо '
                      'названия выбранного варианта.',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(!toOneOf && subStages.isNotEmpty
              ? 'Переключить и удалить'
              : 'Переключить'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Какое имя увидит оператор после конверсии в `one_of`: подпись варианта по
/// умолчанию. До конверсии подписи ещё не заполнены, поэтому берём имя
/// рабочего места — ровно его и проставит функция.
String? _defaultVariantTitle(RouteStage stage) {
  if (stage.workplaces.isEmpty) return null;
  final first = stage.workplaces.first;
  return first.variantTitle ??
      ProductTypeSettings.instance.workplaceName(first.workplaceId);
}

/// «— вариант «Труба»» для перечисления в диалоге: без этого две одинаковые
/// «Вставки картона» в списке неразличимы.
String _ownerSuffix(RouteStage subStage, ProductTypeRoute route) {
  for (final parent in route.stages) {
    for (final workplace in parent.workplaces) {
      if (workplace.rowId != subStage.parentVariantId) continue;
      final title = workplace.variantTitle ??
          ProductTypeSettings.instance.workplaceName(workplace.workplaceId);
      return '  — «$title»';
    }
  }
  return '';
}

/// Удаление этапа целиком.
///
/// Здесь перечисления нет намеренно: с этапом уходят только его собственные
/// рабочие места, условие и под-этапы его вариантов — то есть ровно то, что
/// техлид видит в этой же строке и её панели. Списком предупреждаем там, где
/// уносится НЕВИДИМОЕ: удаление варианта и переход one_of → all.
Future<bool> confirmStageDeletion(
  BuildContext context, {
  required RouteStage stage,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Удалить этап «${stage.title}»?'),
      content: const Text(
        'Вместе с этапом удалятся его рабочие места, условия и под-этапы '
        'вариантов.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Удалить'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Удаление под-этапа варианта.
///
/// Под-этап — лист графа: своих под-этапов у него нет по CHECK на level, и
/// каскадом уходят только его рабочие места и условие. Перечисляем именно их,
/// чтобы окно подтверждения не было пустым ритуалом.
Future<bool> confirmSubStageDeletion(
  BuildContext context, {
  required RouteStage subStage,
  required String variantTitle,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Удалить под-этап «${subStage.title}»?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Под-этап варианта «$variantTitle». Вместе с ним удалятся:'),
          const SizedBox(height: 8),
          Text('•  рабочих мест: ${subStage.workplaces.length}'),
          if (subStage.conditions.isNotEmpty) const Text('•  условие этапа'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Удалить под-этап'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Создание этапа-группы: подпись и первое рабочее место.
///
/// Первое РМ обязательно сразу: этап без рабочих мест не проходит
/// validate_product_type_config (stage_without_workplaces), и создавать
/// заведомо невалидную строку, чтобы техлид её потом чинил, незачем.
Future<({String title, String workplaceId})?> promptGroupStage(
  BuildContext context,
) async {
  final titleController = TextEditingController();
  String? workplaceId;

  return showDialog<({String title, String workplaceId})?>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setInner) => AlertDialog(
        title: const Text('Новый этап-группа'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Несколько рабочих мест на одном шаге: все попадут в план '
              'строками с общим номером шага.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: titleController,
              decoration: const InputDecoration(
                labelText: 'Подпись этапа',
                hintText: 'например, Склейка дна',
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: workplaceId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Первое рабочее место'),
              items: [
                for (final w in ProductTypeSettings.instance.workplaces)
                  DropdownMenuItem<String>(value: w.id, child: Text(w.name)),
              ],
              onChanged: (value) => setInner(() => workplaceId = value),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: titleController.text.trim().isEmpty || workplaceId == null
                ? null
                : () => Navigator.pop(ctx, (
                      title: titleController.text.trim(),
                      workplaceId: workplaceId!,
                    )),
            child: const Text('Создать'),
          ),
        ],
      ),
    ),
  );
}
