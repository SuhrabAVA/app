import 'package:flutter/material.dart';

import '../orders/order_handle_type.dart';
import '../orders/product_type_route.dart';
import '../orders/product_type_settings.dart';
import '../orders/stage_queue_builder.dart';

/// Превью очереди заказа для текущего маршрута.
///
/// Строится ТЕМ ЖЕ сборщиком, который собирает очередь настоящего заказа
/// (`buildOrderStagesFromRoute`), а не отдельной отрисовкой конфига. Поэтому
/// техлид видит ровно то, что получит заказ, и расхождение между «как
/// выглядит в редакторе» и «как собралось» невозможно по построению.
///
/// Переключатели условий здесь не украшение: они показывают, что именно
/// делает условие. Этап появляется и исчезает на глазах — это дешевле любого
/// объяснения в подсказке.
class ProductTypeStagePreview extends StatefulWidget {
  const ProductTypeStagePreview({super.key, required this.route});

  final ProductTypeRoute route;

  @override
  State<ProductTypeStagePreview> createState() =>
      _ProductTypeStagePreviewState();
}

class _ProductTypeStagePreviewState extends State<ProductTypeStagePreview> {
  bool _paint = false;
  bool _cardboard = false;
  bool _trimming = false;
  bool _bobbin = false;
  OrderHandleType _handle = OrderHandleType.none;
  final Map<String, String> _variants = <String, String>{};

  List<BuiltOrderStage> _queue() {
    final draft = OrderStageQueueDraft(
      productTypeId: widget.route.productTypeId,
      hasPaint: _paint,
      hasCardboard: _cardboard,
      hasTrimming: _trimming,
      handleType: _handle,
      requiresBobbinCutting: _bobbin,
      selectedSwitchableStageIdsByStageKey: Map<String, String>.from(_variants),
    );
    return buildOrderStagesFromRoute(draft, widget.route);
  }

  @override
  Widget build(BuildContext context) {
    final queue = _queue();
    return Container(
      color: const Color(0xFFF6F7FB),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ОЧЕРЕДЬ ЗАКАЗА',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: Colors.grey.shade600,
            ),
          ),
          const SizedBox(height: 8),
          if (queue.isEmpty)
            Text('Очередь пуста',
                style: TextStyle(color: Colors.grey.shade500))
          else
            Wrap(
              spacing: 4,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (var i = 0; i < queue.length; i++) ...[
                  if (i > 0)
                    Icon(Icons.arrow_right,
                        size: 18, color: Colors.grey.shade400),
                  _chip('${i + 1}. ${queue[i].stageName}'),
                ],
              ],
            ),
          const SizedBox(height: 12),
          Text('УСЛОВИЯ ПРЕВЬЮ',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                color: Colors.grey.shade500,
              )),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _filter('Краски', _paint, (v) => setState(() => _paint = v)),
              _filter('Картон', _cardboard,
                  (v) => setState(() => _cardboard = v)),
              _filter('Подрезка', _trimming,
                  (v) => setState(() => _trimming = v)),
              _filter('Бабинорезка', _bobbin,
                  (v) => setState(() => _bobbin = v)),
              DropdownButton<OrderHandleType>(
                value: _handle,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(
                      value: OrderHandleType.none, child: Text('без ручки')),
                  DropdownMenuItem(
                      value: OrderHandleType.flat, child: Text('плоская')),
                  DropdownMenuItem(
                      value: OrderHandleType.twisted, child: Text('кручёная')),
                  DropdownMenuItem(
                      value: OrderHandleType.dieCut, child: Text('вырубка')),
                ],
                onChanged: (v) =>
                    setState(() => _handle = v ?? OrderHandleType.none),
              ),
            ],
          ),
          ..._variantPickers(),
        ],
      ),
    );
  }

  List<Widget> _variantPickers() {
    final switches = widget.route.switchableStages.toList();
    if (switches.isEmpty) return const <Widget>[];

    return [
      const SizedBox(height: 6),
      for (final stage in switches)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('${stage.title}:',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              for (final variant in stage.workplaces)
                ChoiceChip(
                  label: Text(
                    variant.variantTitle ??
                        ProductTypeSettings.instance
                            .workplaceName(variant.workplaceId),
                    style: const TextStyle(fontSize: 11),
                  ),
                  selected:
                      (_variants[stage.key] ?? _defaultVariantId(stage)) ==
                          variant.workplaceId,
                  onSelected: (_) => setState(
                      () => _variants[stage.key] = variant.workplaceId),
                ),
            ],
          ),
        ),
    ];
  }

  String? _defaultVariantId(RouteStage stage) {
    for (final w in stage.workplaces) {
      if (w.isDefault) return w.workplaceId;
    }
    return stage.workplaces.isEmpty ? null : stage.workplaces.first.workplaceId;
  }

  Widget _chip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFD8DCE8)),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  Widget _filter(String label, bool value, ValueChanged<bool> onChanged) {
    return FilterChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      selected: value,
      onSelected: onChanged,
    );
  }
}
