import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

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

  /// Подпись кнопки поколения — дата создания того заказа.
  static String labelFor(OrderGenerationEntry entry) {
    final date = entry.displayDate;
    if (date != null) return _dateFormat.format(date.toLocal());
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
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(currentLabel),
                  selected: !isHistorySelected,
                  onSelected: (_) => onSelected(currentOrderId),
                ),
              ),
              for (final entry in others)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(labelFor(entry)),
                    selected: selectedOrderId == entry.id,
                    onSelected: (_) => onSelected(entry.id),
                  ),
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
