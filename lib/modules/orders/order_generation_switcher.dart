import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../utils/kostanay_time.dart';
import 'order_restart_history_repository.dart';

/// Переключатель поколений заказа (оригинал и возобновления).
///
/// Показывает ряд chips: «Текущий заказ» + по одной кнопке на каждое
/// другое поколение цепочки (подпись — дата создания поколения).
/// Если у заказа нет других поколений и загрузка не идёт, не рисует ничего —
/// экраны без возобновлений выглядят как раньше.
class OrderGenerationSwitcher extends StatelessWidget {
  const OrderGenerationSwitcher({
    super.key,
    required this.generations,
    required this.currentOrderId,
    required this.selectedOrderId,
    required this.onSelected,
    this.loading = false,
    this.currentLabel = 'Текущий заказ',
    this.readOnlyNotice = 'Только просмотр: история предыдущего заказа',
    this.bottomSpacing = 6,
  });

  /// Полная цепочка поколений (см. [RestartHistoryService.loadGenerationChain]).
  final List<OrderGenerationEntry> generations;

  /// Заказ, открытый в модуле (его вкладка — режим записи).
  final String currentOrderId;

  /// Поколение, чья история сейчас показана.
  final String selectedOrderId;

  final ValueChanged<String> onSelected;
  final bool loading;
  final String currentLabel;

  /// Текст пометки «только просмотр»; null — не показывать пометку.
  final String? readOnlyNotice;

  final double bottomSpacing;

  static final DateFormat _dateFormat = DateFormat('dd.MM.yyyy');

  static const _activeBackground = Color(0xFF2F6BFF);
  static const _inactiveBackground = Color(0xFFF1F2F6);
  static const _inactiveForeground = Color(0xFF4A4A57);

  /// Подпись кнопки поколения — дата создания того заказа.
  static String labelFor(OrderGenerationEntry entry) {
    final date = entry.displayDate;
    if (date != null) return _dateFormat.format(toKostanayTime(date));
    return 'Заказ ${entry.generation + 1}';
  }

  @override
  Widget build(BuildContext context) {
    final others = [
      for (final entry in generations)
        if (entry.id != currentOrderId) entry,
    ]
      // Предыдущие поколения — от новых к старым, сразу после текущего.
      ..sort((a, b) => b.generation.compareTo(a.generation));

    if (others.isEmpty && !loading) return const SizedBox.shrink();

    final isHistorySelected = selectedOrderId != currentOrderId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              OrderGenerationChip(
                label: currentLabel,
                selected: !isHistorySelected,
                onTap: () => onSelected(currentOrderId),
              ),
              for (final entry in others)
                OrderGenerationChip(
                  label: labelFor(entry),
                  selected: selectedOrderId == entry.id,
                  onTap: () => onSelected(entry.id),
                ),
            ],
          ),
        ),
        if (loading) const LinearProgressIndicator(),
        if (isHistorySelected && readOnlyNotice != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              readOnlyNotice!,
              style: const TextStyle(color: Colors.orange),
            ),
          ),
        SizedBox(height: bottomSpacing),
      ],
    );
  }
}

/// Пилюля-вкладка поколения.
///
/// Своя, а не [ChoiceChip]: дефолтный чип тянул 48px tap-target и рисовал
/// рамку выбора, из-за чего ряд поколений выглядел тяжелее самих
/// комментариев. Активная — залитая, с галочкой; остальные — светло-серые,
/// без рамок.
class OrderGenerationChip extends StatelessWidget {
  const OrderGenerationChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foreground =
        selected ? Colors.white : OrderGenerationSwitcher._inactiveForeground;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: selected
            ? OrderGenerationSwitcher._activeBackground
            : OrderGenerationSwitcher._inactiveBackground,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected) ...[
                  Icon(Icons.check, size: 14, color: foreground),
                  const SizedBox(width: 5),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                    color: foreground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
