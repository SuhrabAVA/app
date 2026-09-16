/// Таблица отгрузок заказа: когда, сколько, кто, документ.
///
/// Одна на все места показа — диалог отгрузки и архив. Две копии разъехались
/// бы на первом же столбце, а сотрудник сверяет их между собой.
library;

import 'package:flutter/material.dart';

import '../../utils/kostanay_time.dart';
import '../tasks/workspace_design.dart';
import 'order_shipment_rules.dart';

class OrderShipmentsTable extends StatelessWidget {
  const OrderShipmentsTable({
    super.key,
    required this.shipments,
    this.onToggleDocument,
  });

  final List<OrderShipment> shipments;

  /// Переключение галочки документа; `null` — только показ (архив без прав).
  final void Function(OrderShipment shipment, bool hasDocument)?
      onToggleDocument;

  @override
  Widget build(BuildContext context) {
    if (shipments.isEmpty) {
      return const Text(
        'Отгрузок пока не было',
        style: TextStyle(fontSize: 12, color: WorkspaceColors.mutedForeground),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: WorkspaceColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          const _Row(
            cells: ['Дата и время', 'Количество', 'Кто отгрузил', 'Документ'],
            isHeader: true,
          ),
          for (var i = 0; i < shipments.length; i++)
            _ShipmentRow(
              shipment: shipments[i],
              isLast: i == shipments.length - 1,
              onToggleDocument: onToggleDocument,
            ),
        ],
      ),
    );
  }
}

/// Строка отгрузки.
///
/// Галочка документа НЕ сохраняется сразу: она меняет состояние строки, и
/// рядом появляется «Сохранить». Так сделано намеренно — переключение пишется
/// в историю заказа отдельной записью с автором и временем, и запись по
/// случайному касанию была бы ложным следом в документах.
class _ShipmentRow extends StatefulWidget {
  const _ShipmentRow({
    required this.shipment,
    required this.isLast,
    required this.onToggleDocument,
  });

  final OrderShipment shipment;
  final bool isLast;
  final void Function(OrderShipment shipment, bool hasDocument)?
      onToggleDocument;

  @override
  State<_ShipmentRow> createState() => _ShipmentRowState();
}

class _ShipmentRowState extends State<_ShipmentRow> {
  late bool _pending = widget.shipment.hasDocument;

  @override
  void didUpdateWidget(covariant _ShipmentRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Строку перечитали из базы — снимаем несохранённое.
    if (oldWidget.shipment.hasDocument != widget.shipment.hasDocument) {
      _pending = widget.shipment.hasDocument;
    }
  }

  bool get _dirty => _pending != widget.shipment.hasDocument;

  @override
  Widget build(BuildContext context) {
    final shipment = widget.shipment;
    final isLast = widget.isLast;
    final onToggleDocument = widget.onToggleDocument;
    // Не toLocal(): устройство в цехе может стоять в чужом часовом поясе, и
    // партия показывалась бы со сдвигом. Везде показываем время Костаная.
    final when = toKostanayTime(shipment.shippedAt);
    String two(int v) => v.toString().padLeft(2, '0');

    return Container(
      decoration: BoxDecoration(
        border: isLast
            ? null
            : const Border(
                bottom: BorderSide(color: WorkspaceColors.border),
              ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              '${two(when.day)}.${two(when.month)}.${when.year} '
              '${two(when.hour)}:${two(when.minute)}',
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              formatShippedQty(shipment.qty),
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              shipment.shippedBy.isEmpty ? '—' : shipment.shippedBy,
              style: const TextStyle(fontSize: 12.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 128,
            child: onToggleDocument == null
                // Показ без права правки: галочка нарисована, но не нажимается.
                ? Icon(
                    shipment.hasDocument
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                    size: 18,
                    color: shipment.hasDocument
                        ? WorkspaceColors.success
                        : WorkspaceColors.mutedForeground,
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: _pending,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        onChanged: (value) =>
                            setState(() => _pending = value == true),
                      ),
                      // Кнопка появляется только когда есть что сохранять:
                      // постоянная «Сохранить» на каждой строке читалась бы
                      // как «ещё не сохранено» у всех сразу.
                      if (_dirty)
                        TextButton(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: const Size(0, 28),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () =>
                              onToggleDocument(shipment, _pending),
                          child: const Text(
                            'Сохранить',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.cells, this.isHeader = false});

  final List<String> cells;
  final bool isHeader;

  @override
  Widget build(BuildContext context) {
    const flexes = [3, 2, 3];
    return Container(
      decoration: const BoxDecoration(
        color: WorkspaceColors.secondaryBackground,
        border: Border(bottom: BorderSide(color: WorkspaceColors.border)),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(9),
          topRight: Radius.circular(9),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          for (var i = 0; i < 3; i++)
            Expanded(
              flex: flexes[i],
              child: Text(
                cells[i],
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: isHeader ? FontWeight.w600 : FontWeight.w400,
                  color: WorkspaceColors.mutedForeground,
                ),
              ),
            ),
          SizedBox(
            // Та же ширина, что у ячейки строки: там рядом с галочкой живёт
            // кнопка «Сохранить», и колонки иначе разъезжаются.
            width: 128,
            child: Text(
              cells[3],
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: WorkspaceColors.mutedForeground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
