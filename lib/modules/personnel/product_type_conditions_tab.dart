import 'package:flutter/material.dart';

import '../orders/product_type_condition_options.dart';
import '../orders/product_type_route.dart';
import '../orders/product_type_settings.dart';

/// Вкладка «Условия» — перечень условных этапов маршрута.
///
/// ТОЛЬКО ДЛЯ ЧТЕНИЯ, СОЗНАТЕЛЬНО.
/// Условно добавляемый этап — это обычный этап с условием, а не отдельная
/// сущность. Правка идёт в строке этапа, на вкладке «Очередь этапов»; здесь
/// только сводный список с переходом к нужной строке. Два пути правки одной
/// строки разъехались бы на первом же расхождении.
///
/// Смысл вкладки — ответить на вопрос «при каких обстоятельствах маршрут
/// меняется», не пролистывая весь список: у П-образного пакета условных
/// этапов семь из тринадцати.
class ProductTypeConditionsTab extends StatelessWidget {
  const ProductTypeConditionsTab({
    super.key,
    required this.route,
    required this.onOpenStage,
  });

  final ProductTypeRoute? route;

  /// Переводит на вкладку «Очередь этапов» и подсвечивает строку этапа.
  final void Function(RouteStage stage) onOpenStage;

  @override
  Widget build(BuildContext context) {
    final current = route;
    if (current == null) {
      return const Center(child: Text('У типа продукта нет версии настроек.'));
    }

    final conditional = current.stages
        .where((s) => s.conditions.isNotEmpty)
        .toList(growable: false)
      ..sort((a, b) {
        final byPosition = a.position.compareTo(b.position);
        return byPosition != 0 ? byPosition : a.key.compareTo(b.key);
      });

    if (conditional.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Условий нет: все этапы маршрута добавляются всегда.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Text(
            'Этапы, которые попадают в очередь не всегда. Условие правится в '
            'строке этапа на вкладке «Очередь этапов».',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ),
        for (final stage in conditional) _buildRow(context, current, stage),
      ],
    );
  }

  Widget _buildRow(
    BuildContext context,
    ProductTypeRoute route,
    RouteStage stage,
  ) {
    return ListTile(
      leading: SizedBox(
        width: 30,
        child: Text('${stage.position}',
            style: TextStyle(
                fontWeight: FontWeight.w600, color: Colors.grey.shade600)),
      ),
      title: Row(
        children: [
          Flexible(child: Text(stage.title)),
          if (stage.level == 1) ...[
            const SizedBox(width: 6),
            _variantBadge(route, stage),
          ],
        ],
      ),
      subtitle: Text(
        stageConditionSummary(stage),
        style: const TextStyle(fontSize: 12, color: Color(0xFF5B21B6)),
      ),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () => onOpenStage(stage),
    );
  }

  /// У под-этапа условие срабатывает только при выбранном варианте — без
  /// бейджа перечень вводил бы в заблуждение.
  Widget _variantBadge(ProductTypeRoute route, RouteStage stage) {
    var title = '';
    for (final parent in route.stages) {
      for (final workplace in parent.workplaces) {
        if (workplace.rowId != stage.parentVariantId) continue;
        title = workplace.variantTitle ??
            ProductTypeSettings.instance.workplaceName(workplace.workplaceId);
      }
    }
    if (title.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFFEFEAFF),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text('только $title',
          style: const TextStyle(fontSize: 10, color: Color(0xFF5B21B6))),
    );
  }
}
