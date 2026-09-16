import 'package:flutter/material.dart';

import '../orders/product_type_route.dart';
import '../orders/product_type_settings.dart';
import '../orders/product_type_stage_guards.dart';
import 'product_type_stage_condition_editor.dart';
import 'product_type_stage_execution_editor.dart';
import 'product_type_stage_dialogs.dart';
import 'product_type_stage_substages_block.dart';

/// Панель рабочих мест этапа.
///
/// Раскрывается кнопкой «⟨N⟩ РМ» в строке этапа и рисуется ПЛОСКО, сразу за
/// строкой, а не вложенным ExpansionTile: члены связки уже лежат внутри
/// раскрывающейся строки, и третий уровень вложенности сделал бы список
/// нечитаемым.
///
/// Рабочие места выбираются из справочника, а не вводятся текстом. Свободный
/// ввод вернул бы опечатки в идентификаторах, ради которых заведён реестр
/// production_ids.dart.
class ProductTypeStageWorkplacesPanel extends StatelessWidget {
  const ProductTypeStageWorkplacesPanel({
    super.key,
    required this.stage,
    required this.route,
    required this.locked,
    required this.indent,
    required this.onAddWorkplace,
    required this.onRemoveWorkplace,
    required this.onSetDefaultVariant,
    required this.onChangeSelectionMode,
    required this.onChangeCondition,
    required this.onChangeExecution,
    required this.onAddSubStage,
    required this.onDeleteSubStage,
    required this.onCopyFromVariant,
  });

  final RouteStage stage;
  final ProductTypeRoute route;
  /// Правка недоступна: нет черновика, идёт загрузка или запись.
  final bool locked;
  final double indent;

  final Future<void> Function(String workplaceId) onAddWorkplace;
  final Future<void> Function(RouteStageWorkplace workplace) onRemoveWorkplace;
  final Future<void> Function(RouteStageWorkplace variant) onSetDefaultVariant;
  final Future<void> Function(String targetMode) onChangeSelectionMode;
  final Future<void> Function(String? predicate, String? param) onChangeCondition;
  final Future<void> Function(String mode, String? partnerRowId)
      onChangeExecution;
  final Future<void> Function(RouteStageWorkplace variant, String workplaceId)
      onAddSubStage;
  final Future<void> Function(RouteStage subStage) onDeleteSubStage;
  final Future<void> Function(
      RouteStageWorkplace from, RouteStageWorkplace to) onCopyFromVariant;

  /// Под-этапы, привязанные к варианту. Пусто для режима «все РМ».
  List<RouteStage> _subStagesOf(RouteStageWorkplace workplace) => route.stages
      .where((s) => s.level == 1 && s.parentVariantId == workplace.rowId)
      .toList(growable: false);

  List<RouteStage> get _allSubStages => route.stages
      .where((s) =>
          s.level == 1 &&
          stage.workplaces.any((w) => w.rowId == s.parentVariantId))
      .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final modeBlocked = selectionModeChangeBlockedReason(stage);

    return Container(
      color: const Color(0xFFF8F9FC),
      padding: EdgeInsets.only(left: indent, right: 12, top: 8, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ProductTypeStageConditionEditor(
            stage: stage,
            locked: locked,
            onChanged: onChangeCondition,
          ),
          const SizedBox(height: 10),
          ProductTypeStageExecutionEditor(
            stage: stage,
            route: route,
            locked: locked,
            onChanged: onChangeExecution,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  stage.isSwitchable ? 'ВАРИАНТЫ' : 'РАБОЧИЕ МЕСТА',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: Colors.grey.shade600,
                  ),
                ),
              ),
              Tooltip(
                message: modeBlocked ?? '',
                child: TextButton.icon(
                  icon: const Icon(Icons.swap_horiz, size: 16),
                  label: Text(
                    stage.isSwitchable
                        ? 'Все рабочие места'
                        : 'Сделать переключаемым',
                    style: const TextStyle(fontSize: 12),
                  ),
                  onPressed: locked || modeBlocked != null
                      ? null
                      : () => _changeMode(context),
                ),
              ),
            ],
          ),
          for (final workplace in stage.workplaces) _buildRow(context, workplace),
          const SizedBox(height: 4),
          _buildAddControl(context),
          // Под-этапы есть только у вариантов, и только у этапа уровня 0:
          // у под-этапа свои под-этапы потребовали бы level = 2, что
          // запрещено CHECK.
          if (stage.isSwitchable && stage.level == 0)
            ProductTypeStageSubStagesBlock(
              stage: stage,
              route: route,
              locked: locked,
              onAddSubStage: onAddSubStage,
              onDeleteSubStage: onDeleteSubStage,
              onCopyFromVariant: onCopyFromVariant,
            ),
        ],
      ),
    );
  }

  Widget _buildRow(BuildContext context, RouteStageWorkplace workplace) {
    final name = ProductTypeSettings.instance.workplaceName(workplace.workplaceId);
    final blocked = workplaceDeleteBlockedReason(stage, workplace);
    final subStages = _subStagesOf(workplace);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(child: Text(name, style: const TextStyle(fontSize: 13))),
                if (subStages.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text('под-этапов: ${subStages.length}',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade600)),
                  ),
              ],
            ),
          ),
          if (stage.isSwitchable) _buildDefaultControl(workplace),
          Tooltip(
            message: blocked ?? 'Убрать из этапа',
            child: IconButton(
              icon: const Icon(Icons.close, size: 16),
              visualDensity: VisualDensity.compact,
              onPressed: locked || blocked != null
                  ? null
                  : () => _remove(context, workplace, subStages),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDefaultControl(RouteStageWorkplace workplace) {
    if (workplace.isDefault) {
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xFFE8FAF0),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text('по умолчанию',
              style: TextStyle(fontSize: 10, color: Color(0xFF1B7F4B))),
        ),
      );
    }
    return TextButton(
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      onPressed: locked ? null : () => onSetDefaultVariant(workplace),
      child: const Text('сделать по умолчанию',
          style: TextStyle(fontSize: 11)),
    );
  }

  /// Уже входящие В ЭТОТ ЭТАП рабочие места показываем неактивными, а не
  /// прячем. Область именно «в этом этапе»: одно РМ в разных этапах законно и
  /// встречается — «Ручка-склейка ручная» входит и во flat_handle_group, и во
  /// twisted_handle_group.
  Widget _buildAddControl(BuildContext context) {
    final used = stage.workplaces.map((w) => w.workplaceId).toSet();
    final all = ProductTypeSettings.instance.workplaces;

    return PopupMenuButton<String>(
      enabled: !locked,
      onSelected: onAddWorkplace,
      itemBuilder: (_) => [
        for (final workplace in all)
          PopupMenuItem<String>(
            value: workplace.id,
            enabled: !used.contains(workplace.id),
            child: Row(
              children: [
                Expanded(child: Text(workplace.name)),
                if (used.contains(workplace.id))
                  Text('уже используется в этом этапе',
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add, size: 16, color: Colors.indigo.shade400),
            const SizedBox(width: 4),
            Text(
              stage.isSwitchable ? 'Добавить вариант' : 'Добавить рабочее место',
              style: TextStyle(fontSize: 12, color: Colors.indigo.shade400),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _remove(
    BuildContext context,
    RouteStageWorkplace workplace,
    List<RouteStage> subStages,
  ) async {
    final title = workplace.variantTitle ??
        ProductTypeSettings.instance.workplaceName(workplace.workplaceId);
    final confirmed = await confirmVariantDeletion(
      context,
      variantTitle: title,
      subStages: subStages,
    );
    if (!confirmed) return;
    await onRemoveWorkplace(workplace);
  }

  Future<void> _changeMode(BuildContext context) async {
    final target = stage.isSwitchable ? 'all' : 'one_of';
    final confirmed = await confirmSelectionModeChange(
      context,
      stage: stage,
      targetMode: target,
      subStages: target == 'all' ? _allSubStages : const <RouteStage>[],
      route: route,
    );
    if (!confirmed) return;
    await onChangeSelectionMode(target);
  }
}
