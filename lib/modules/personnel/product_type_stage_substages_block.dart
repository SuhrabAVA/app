import 'package:flutter/material.dart';

import '../orders/product_type_route.dart';
import '../orders/product_type_settings.dart';

/// Под-этапы вариантов переключаемого этапа.
///
/// Показывается только у `selection_mode = one_of`: у режима «все рабочие
/// места» вариантов нет, и владеть под-этапами нечему.
///
/// ЭТО УПРАВЛЕНИЕ ПРИНАДЛЕЖНОСТЬЮ, А НЕ РЕДАКТОР ЭТАПА.
/// Здесь видно, ЧЕЙ под-этап и какие они есть у варианта; править его рабочие
/// места и условие нужно в общем списке, где у под-этапа своя строка со своей
/// панелью. Это то же разделение, что и во всём экране: панель отвечает на
/// вопрос ЧЬЁ, список — на вопрос ГДЕ. Вложить панель внутрь панели значило бы
/// завести второй путь правки одного и того же.
///
/// Глубина ограничена схемой: под-этап имеет level = 1, и его собственные
/// под-этапы потребовали бы level = 2, что запрещает CHECK. Поэтому у
/// под-этапа этот блок не показывается вовсе — кнопка, гарантированно
/// упирающаяся в констрейнт, хуже отсутствующей.
class ProductTypeStageSubStagesBlock extends StatefulWidget {
  const ProductTypeStageSubStagesBlock({
    super.key,
    required this.stage,
    required this.route,
    required this.locked,
    required this.onAddSubStage,
    required this.onDeleteSubStage,
    required this.onCopyFromVariant,
  });

  final RouteStage stage;
  final ProductTypeRoute route;
  final bool locked;

  final Future<void> Function(RouteStageWorkplace variant, String workplaceId)
      onAddSubStage;
  final Future<void> Function(RouteStage subStage) onDeleteSubStage;
  final Future<void> Function(
      RouteStageWorkplace from, RouteStageWorkplace to) onCopyFromVariant;

  @override
  State<ProductTypeStageSubStagesBlock> createState() =>
      _ProductTypeStageSubStagesBlockState();
}

class _ProductTypeStageSubStagesBlockState
    extends State<ProductTypeStageSubStagesBlock> {
  /// Какой вариант показан. Локальное состояние панели, не настройка.
  String? _selectedVariantRowId;

  RouteStageWorkplace get _selectedVariant {
    for (final variant in widget.stage.workplaces) {
      if (variant.rowId == _selectedVariantRowId) return variant;
    }
    for (final variant in widget.stage.workplaces) {
      if (variant.isDefault) return variant;
    }
    return widget.stage.workplaces.first;
  }

  List<RouteStage> _subStagesOf(RouteStageWorkplace variant) => widget
      .route.stages
      .where((s) => s.level == 1 && s.parentVariantId == variant.rowId)
      .toList(growable: false)
    ..sort((a, b) => a.position.compareTo(b.position));

  String _variantLabel(RouteStageWorkplace variant) =>
      variant.variantTitle ??
      ProductTypeSettings.instance.workplaceName(variant.workplaceId);

  /// Варианты того же этапа, у которых под-этапы есть, — источники копирования.
  List<RouteStageWorkplace> _copySources(RouteStageWorkplace target) => widget
      .stage.workplaces
      .where((v) => v.rowId != target.rowId && _subStagesOf(v).isNotEmpty)
      .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    if (!widget.stage.isSwitchable || widget.stage.workplaces.isEmpty) {
      return const SizedBox.shrink();
    }

    final variant = _selectedVariant;
    final subStages = _subStagesOf(variant);
    final sources = _copySources(variant);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        Text('ПОД-ЭТАПЫ ВАРИАНТА',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: Colors.grey.shade600,
            )),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          children: [
            for (final v in widget.stage.workplaces)
              ChoiceChip(
                label: Text(
                  '${_variantLabel(v)}'
                  '${_subStagesOf(v).isEmpty ? '' : ' · ${_subStagesOf(v).length}'}',
                  style: const TextStyle(fontSize: 11),
                ),
                selected: v.rowId == variant.rowId,
                onSelected: (_) =>
                    setState(() => _selectedVariantRowId = v.rowId),
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (subStages.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'У варианта «${_variantLabel(variant)}» под-этапов нет.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
          )
        else
          for (final sub in subStages) _buildSubStageRow(sub),
        Row(
          children: [
            _addControl(variant),
            if (sources.isNotEmpty) _copyControl(variant, sources),
          ],
        ),
      ],
    );
  }

  Widget _buildSubStageRow(RouteStage sub) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text('${sub.position}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ),
          Expanded(
            child: Text(sub.title, style: const TextStyle(fontSize: 13)),
          ),
          Text(
            sub.conditions.isEmpty ? 'всегда' : 'по условию',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
          ),
          Tooltip(
            message: 'Удалить под-этап',
            child: IconButton(
              icon: const Icon(Icons.delete_outline, size: 16),
              visualDensity: VisualDensity.compact,
              onPressed:
                  widget.locked ? null : () => widget.onDeleteSubStage(sub),
            ),
          ),
        ],
      ),
    );
  }

  /// Рабочие места для нового под-этапа: занятые ЭТИМ вариантом неактивны.
  ///
  /// Ключ под-этапа с одним рабочим местом равен uuid этого места, а
  /// уникальность — (config_id, parent_variant_id, stage_group_key). Значит
  /// одно и то же РМ нельзя дважды под одним вариантом, но под разными —
  /// можно, и это законно: «Вставка картона» стоит под обоими автоматами.
  Widget _addControl(RouteStageWorkplace variant) {
    final used = _subStagesOf(variant).map((s) => s.key).toSet();
    return PopupMenuButton<String>(
      enabled: !widget.locked,
      onSelected: (workplaceId) => widget.onAddSubStage(variant, workplaceId),
      itemBuilder: (_) => [
        for (final workplace in ProductTypeSettings.instance.workplaces)
          PopupMenuItem<String>(
            value: workplace.id,
            enabled: !used.contains(workplace.id),
            child: Row(
              children: [
                Expanded(child: Text(workplace.name)),
                if (used.contains(workplace.id))
                  Text('уже есть у этого варианта',
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add, size: 16, color: Colors.indigo.shade400),
            const SizedBox(width: 4),
            Text('Добавить под-этап',
                style: TextStyle(fontSize: 12, color: Colors.indigo.shade400)),
          ],
        ),
      ),
    );
  }

  Widget _copyControl(
    RouteStageWorkplace target,
    List<RouteStageWorkplace> sources,
  ) {
    return PopupMenuButton<String>(
      enabled: !widget.locked,
      onSelected: (fromRowId) {
        final from = sources.firstWhere((v) => v.rowId == fromRowId);
        widget.onCopyFromVariant(from, target);
      },
      itemBuilder: (_) => [
        for (final source in sources)
          PopupMenuItem<String>(
            value: source.rowId,
            child: Text(
                '${_variantLabel(source)} · ${_subStagesOf(source).length}'),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.copy_all_outlined, size: 15, color: Colors.grey.shade600),
            const SizedBox(width: 4),
            Text('Скопировать из варианта',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ],
        ),
      ),
    );
  }
}
