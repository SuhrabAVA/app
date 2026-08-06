import 'package:flutter/material.dart';

import '../orders/product_type_route.dart';
import '../orders/product_type_settings.dart';
import '../orders/production_ids.dart';

/// Этапы, подпись которых задана системой.
///
/// Постобработка `normalizeBuiltOrderStageQueue` принудительно переименовывает
/// эти три этапа. Дай техлиду поле ввода — он переименует, увидит в очереди
/// прежнее имя и пойдёт искать баг. Поэтому подпись показываем, но не даём
/// править. Ключи берутся из реестра `production_ids.dart`, а не литералами.
const Set<String> kSystemNamedStageKeys = <String>{
  wpBobbinUuid,
  wpFlexPrintingUuid,
  wpPackagingUuid,
};

/// Отрисовка одной строки списка. Строка — это ГРУППА ранга, а не этап.
///
/// Вынесено из `product_type_stages_tab.dart`, который перестал помещаться в
/// лимит 500 строк, когда к нему добавилась панель рабочих мест.
class StageRowBuilder {
  const StageRowBuilder({
    required this.route,
    required this.locked,
    required this.expandedStageId,
    required this.reorderFor,
    required this.onMove,
    required this.onToggleEnabled,
    required this.onDeleteStage,
    required this.onToggleWorkplaces,
    required this.buildWorkplacesPanel,
  });

  final ProductTypeRoute route;
  /// Правка недоступна: нет черновика, идёт загрузка или запись.
  final bool locked;
  final String? expandedStageId;

  final StageGroupReorder? Function(StageGroup group, int delta) reorderFor;
  final void Function(StageGroup group, int delta) onMove;
  final void Function(RouteStage stage, bool value) onToggleEnabled;
  final void Function(RouteStage stage) onDeleteStage;
  final void Function(RouteStage stage) onToggleWorkplaces;
  final Widget Function(RouteStage stage, double indent) buildWorkplacesPanel;

  Widget build(BuildContext context, StageGroup group) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (group.stages.length == 1)
          _singleTile(context, group, group.stages.first)
        else
          _bundleTile(context, group),
        const Divider(height: 1, indent: 16),
      ],
    );
  }

  Widget _singleTile(BuildContext context, StageGroup group, RouteStage stage) {
    final indent = group.isSubQueue ? 40.0 : 16.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Opacity(
          opacity: stage.isEnabled ? 1 : 0.5,
          child: ListTile(
            contentPadding: EdgeInsets.only(left: indent, right: 8),
            leading: _positionBadge(group),
            title: Row(
              children: [
                Flexible(child: Text(stage.title)),
                if (kSystemNamedStageKeys.contains(stage.key)) _systemNameLock(),
                if (group.isSubQueue) ..._variantBadges(group),
              ],
            ),
            subtitle: _subtitle(stage),
            trailing: _rowActions(group, stage),
          ),
        ),
        if (expandedStageId == stage.rowId)
          buildWorkplacesPanel(stage, indent + 18),
      ],
    );
  }

  /// Свёрнутая строка связки: раскрывается, чтобы править членов по отдельности.
  Widget _bundleTile(BuildContext context, StageGroup group) {
    final indent = group.isSubQueue ? 40.0 : 16.0;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.only(left: indent, right: 8),
        leading: _positionBadge(group),
        title: Row(
          children: [
            Flexible(child: Text(_bundleTitle(group))),
            if (group.isSubQueue) ..._variantBadges(group),
          ],
        ),
        subtitle: Text(
          'Взаимоисключающие: в очередь попадёт не более одного',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        trailing: _rowActions(group, null),
        childrenPadding: EdgeInsets.only(left: indent + 16, bottom: 4),
        children: [
          for (final stage in group.stages) ...[
            Opacity(
              opacity: stage.isEnabled ? 1 : 0.5,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Row(
                  children: [
                    Flexible(child: Text(stage.title)),
                    if (kSystemNamedStageKeys.contains(stage.key))
                      _systemNameLock(),
                  ],
                ),
                subtitle: _subtitle(stage),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _workplacesButton(stage),
                    Switch(
                      value: stage.isEnabled,
                      onChanged:
                          locked ? null : (v) => onToggleEnabled(stage, v),
                    ),
                    IconButton(
                      tooltip: 'Удалить этап',
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: locked ? null : () => onDeleteStage(stage),
                    ),
                  ],
                ),
              ),
            ),
            if (expandedStageId == stage.rowId)
              buildWorkplacesPanel(stage, 0),
          ],
        ],
      ),
    );
  }

  Widget _subtitle(RouteStage stage) => Text(
        _stageSubtitle(stage),
        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
      );

  /// Подпись связки. Если все члены различаются одним и тем же предикатом,
  /// говорим об этом прямо — так техлиду видно, чем они переключаются.
  String _bundleTitle(StageGroup group) {
    final predicates =
        group.stages.expand((s) => s.conditions.map((c) => c.predicate)).toSet();
    if (predicates.length == 1 &&
        group.stages.every((s) => s.conditions.length == 1)) {
      final label = switch (predicates.first) {
        'handle_type_is' => 'Ручка',
        _ => 'Этап',
      };
      return '$label — ${group.stages.length} варианта по условию';
    }
    return '${group.stages.length} этапа на одном шаге';
  }

  Widget _positionBadge(StageGroup group) => SizedBox(
        width: 34,
        child: Text('${group.position}',
            style: TextStyle(
                fontWeight: FontWeight.w600, color: Colors.grey.shade600)),
      );

  Widget _systemNameLock() => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Tooltip(
          message: 'Имя задано системой: сборка очереди всё равно вернёт его',
          child:
              Icon(Icons.lock_outline, size: 14, color: Colors.grey.shade500),
        ),
      );

  /// Бейджи вариантов-владельцев у под-этапа: список отвечает на вопрос ГДЕ,
  /// бейдж — на вопрос ЧЬЁ.
  List<Widget> _variantBadges(StageGroup group) {
    final titles = <String>[];
    for (final stage in group.stages) {
      for (final parent in route.stages) {
        for (final workplace in parent.workplaces) {
          if (workplace.rowId != stage.parentVariantId) continue;
          titles.add(workplace.variantTitle ??
              ProductTypeSettings.instance
                  .workplaceName(workplace.workplaceId));
        }
      }
    }
    return [
      for (final title in titles)
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFFEFEAFF),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(title,
                style:
                    const TextStyle(fontSize: 10, color: Color(0xFF5B21B6))),
          ),
        ),
    ];
  }

  Widget _workplacesButton(RouteStage stage) {
    final open = expandedStageId == stage.rowId;
    return Tooltip(
      message: stage.isSwitchable ? 'Варианты этапа' : 'Рабочие места этапа',
      child: TextButton(
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
        // Раскрытие панели — чистое состояние экрана, а не запись. В режиме
        // чтения она тоже должна открываться: посмотреть состав этапа можно
        // без черновика, неактивны внутри неё будут только действия.
        onPressed: () => onToggleWorkplaces(stage),
        child: Text(
          '${open ? '▾' : '▸'} ${stage.workplaces.length} РМ',
          style: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }

  Widget _rowActions(StageGroup group, RouteStage? single) {
    if (group.isPinned) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (single != null) _workplacesButton(single),
          Tooltip(
            message: 'Упаковка всегда завершает очередь: количество заказа '
                'пересчитывается после её завершения',
            child: Icon(Icons.push_pin_outlined,
                size: 18, color: Colors.grey.shade500),
          ),
        ],
      );
    }

    final up = reorderFor(group, -1);
    final down = reorderFor(group, 1);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _moveButton(Icons.arrow_upward, 'Выше', up, () => onMove(group, -1)),
        _moveButton(Icons.arrow_downward, 'Ниже', down, () => onMove(group, 1)),
        if (single != null) ...[
          _workplacesButton(single),
          Switch(
            value: single.isEnabled,
            onChanged: locked ? null : (v) => onToggleEnabled(single, v),
          ),
          IconButton(
            tooltip: 'Удалить этап',
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: locked ? null : () => onDeleteStage(single),
          ),
        ],
      ],
    );
  }

  /// Невозможный ход показываем неактивной кнопкой с причиной в подсказке —
  /// молчаливый отказ после нажатия оставил бы техлида гадать.
  Widget _moveButton(
    IconData icon,
    String label,
    StageGroupReorder? reorder,
    VoidCallback onPressed,
  ) {
    final allowed = reorder?.isAllowed ?? false;
    return Tooltip(
      message: allowed ? label : (reorder?.blockedReason ?? label),
      child: IconButton(
        icon: Icon(icon, size: 18),
        onPressed: locked || !allowed ? null : onPressed,
      ),
    );
  }

  String _stageSubtitle(RouteStage stage) {
    final parts = <String>[];
    if (stage.conditions.isEmpty) {
      parts.add('всегда');
    } else {
      parts.add('если: ${stage.conditions.map(_conditionLabel).join(' и ')}');
    }
    final subStages = route.stages
        .where((s) =>
            s.level == 1 &&
            stage.workplaces.any((w) => w.rowId == s.parentVariantId))
        .length;
    if (subStages > 0) parts.add('под-этапов: $subStages');
    return parts.join(' · ');
  }

  String _conditionLabel(RouteCondition condition) {
    final base = switch (condition.predicate) {
      'has_paint' => 'есть краски',
      'has_cardboard' => 'есть картон',
      'has_trimming' => 'есть подрезка',
      'needs_bobbin_cutting' => 'заказ уже формата бумаги',
      'handle_type_is' => 'ручка ${condition.param ?? ''}',
      _ => condition.predicate,
    };
    return condition.negate ? 'не $base' : base;
  }
}
