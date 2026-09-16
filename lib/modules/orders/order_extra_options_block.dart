/// Блок «Дополнительные опции» в форме заказа.
///
/// Строки приходят готовыми из [buildOrderExtraOptionRows] — виджет их только
/// рисует и сообщает наверх новый список. Ни справочник, ни снимок он не
/// читает: правила «что показать» живут в чистом слое и проверены тестами,
/// здесь остаётся разметка.
library;

import 'package:flutter/material.dart';

import 'order_extra_options.dart';
import 'order_form_design.dart';

class OrderExtraOptionsBlock extends StatelessWidget {
  const OrderExtraOptionsBlock({
    super.key,
    required this.rows,
    required this.onChanged,
    this.labelWidth = OrderFormMetrics.labelWidth,
    this.enabled = true,
  });

  final List<OrderExtraOptionRow> rows;
  final ValueChanged<List<OrderExtraOptionRow>> onChanged;
  final double labelWidth;
  final bool enabled;

  void _apply(int index, String? valueId) {
    final next = List<OrderExtraOptionRow>.from(rows);
    next[index] = next[index].withChoice(valueId);
    onChanged(next);
  }

  /// Убирает значение снятой с учёта опции.
  ///
  /// Отдельно от [_apply] потому, что у такой строки нет ни списка вариантов,
  /// ни возможности выбрать заново: единственное осмысленное действие — снять.
  void _drop(int index) {
    final next = List<OrderExtraOptionRow>.from(rows)..removeAt(index);
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < rows.length; index++)
          _row(rows[index], index),
      ],
    );
  }

  Widget _row(OrderExtraOptionRow row, int index) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 5),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: OrderFormColors.divider)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(
              row.title,
              style: const TextStyle(fontSize: 12, color: OrderFormColors.label),
            ),
          ),
          Expanded(child: _control(row, index)),
        ],
      ),
    );
  }

  Widget _control(OrderExtraOptionRow row, int index) {
    if (row.isRetired) return _retired(row, index);
    if (row.isBoolean) return _booleanChoice(row, index);
    return _selectChoice(row, index);
  }

  /// Да/Нет капсулами, а не радиокнопками: повторное нажатие по выбранной
  /// капсуле снимает выбор. Заполнять опции необязательно, а радиокнопка
  /// снять выбор не даёт — менеджеру пришлось бы переоткрывать заказ, чтобы
  /// исправить случайное нажатие.
  Widget _booleanChoice(OrderExtraOptionRow row, int index) {
    return Wrap(
      spacing: 8,
      children: [
        for (final entry in const <MapEntry<String, String>>[
          MapEntry(kOrderOptionYes, 'Да'),
          MapEntry(kOrderOptionNo, 'Нет'),
        ])
          ChoiceChip(
            label: Text(entry.value),
            selected: row.valueId == entry.key,
            onSelected: !enabled
                ? null
                : (selected) => _apply(index, selected ? entry.key : null),
            selectedColor: OrderFormColors.accentSoft,
            labelStyle: TextStyle(
              fontSize: 12,
              color: row.valueId == entry.key
                  ? OrderFormColors.accent
                  : OrderFormColors.muted,
            ),
            side: BorderSide(
              color: row.valueId == entry.key
                  ? OrderFormColors.accentBorder
                  : OrderFormColors.border,
            ),
          ),
      ],
    );
  }

  Widget _selectChoice(OrderExtraOptionRow row, int index) {
    return DropdownButtonFormField<String?>(
      initialValue: row.valueId,
      isExpanded: true,
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        filled: true,
        fillColor: OrderFormColors.fieldFill,
      ),
      hint: const Text('выбрать', style: TextStyle(fontSize: 12)),
      items: [
        // Пустой пункт — способ снять выбор. Без него необязательную опцию
        // нельзя было бы вернуть в «не заполнено».
        const DropdownMenuItem<String?>(
          value: null,
          child: Text('— не выбрано —',
              style: TextStyle(fontSize: 12, color: OrderFormColors.muted)),
        ),
        for (final choice in row.choices)
          DropdownMenuItem<String?>(
            value: choice.id,
            child: Text(
              choice.title,
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: !enabled ? null : (value) => _apply(index, value),
    );
  }

  /// Опции больше нет в справочнике, а значение в заказе есть: показываем как
  /// есть и даём только убрать. Предлагать выбор нечем — вариантов у снятой
  /// опции больше не существует.
  Widget _retired(OrderExtraOptionRow row, int index) {
    return Row(
      children: [
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(
                text: row.valueLabel ?? '—',
                style: const TextStyle(
                    fontSize: 13, color: OrderFormColors.text),
              ),
              const TextSpan(
                text: '  опция снята',
                style:
                    TextStyle(fontSize: 11, color: OrderFormColors.placeholder),
              ),
            ]),
          ),
        ),
        IconButton(
          tooltip: 'Убрать из заказа',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close, size: 16),
          color: OrderFormColors.muted,
          onPressed: !enabled ? null : () => _drop(index),
        ),
      ],
    );
  }
}
