import 'package:flutter/material.dart';

import '../orders/paper_usage_rules.dart';

/// Ответ окна расхода бумаги.
class PaperUsageDialogResult {
  const PaperUsageDialogResult.save(this.qtyByPaperId) : openPaperEditor = false;

  const PaperUsageDialogResult.editPaper()
      : qtyByPaperId = const <String, double>{},
        openPaperEditor = true;

  /// Расход по каждой бумаге заказа, метры. Ноль — бумага в эту смену не шла.
  final Map<String, double> qtyByPaperId;

  /// Сотрудник нажал «Изменить бумагу».
  final bool openPaperEditor;
}

/// Окно «Расход бумаги» этапа бумаги — единственное окно этого действия.
///
/// В поле подставлен остаток плана (план минус уже списанное прошлыми
/// сменами). Записанное сразу уходит со склада и оно же засчитывается как
/// сделанное количество этапа: при нескольких бумагах — их сумма. Отдельного
/// окна количества на этом этапе нет, иначе одно и то же число спрашивали бы
/// дважды. Больше, чем есть на складе для заказа, сохранить нельзя.
Future<PaperUsageDialogResult?> showPaperUsageDialog(
  BuildContext context, {
  required PaperUsageState state,
  required String actionLabel,
}) {
  return showDialog<PaperUsageDialogResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PaperUsageDialog(state: state, actionLabel: actionLabel),
  );
}

class _PaperUsageDialog extends StatefulWidget {
  const _PaperUsageDialog({required this.state, required this.actionLabel});

  final PaperUsageState state;
  final String actionLabel;

  @override
  State<_PaperUsageDialog> createState() => _PaperUsageDialogState();
}

class _PaperUsageDialogState extends State<_PaperUsageDialog> {
  late final List<PaperUsageRow> _rows = widget.state.orderPapers;
  late final Map<String, TextEditingController> _controllers = {
    for (final row in _rows)
      row.paperId: TextEditingController(text: formatPaperMeters(row.remaining)),
  };

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String? _errorFor(PaperUsageRow row) =>
      validatePaperUsageInput(_controllers[row.paperId]!.text, row);

  bool get _hasErrors => _rows.any((row) => _errorFor(row) != null);

  /// Сумма по всем бумагам — она же сделанное количество этапа.
  double get _total {
    var sum = 0.0;
    for (final row in _rows) {
      sum += double.tryParse(
            _controllers[row.paperId]!.text.trim().replaceAll(',', '.'),
          ) ??
          0;
    }
    return sum;
  }

  bool get _canSave => !_hasErrors && _total > 0;

  void _save() {
    if (!_canSave) {
      setState(() {});
      return;
    }
    final result = <String, double>{};
    for (final row in _rows) {
      final value = double.parse(
        _controllers[row.paperId]!.text.trim().replaceAll(',', '.'),
      );
      result.update(row.paperId, (sum) => sum + value, ifAbsent: () => value);
    }
    Navigator.of(context).pop(PaperUsageDialogResult.save(result));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Расход бумаги'),
      content: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Сколько бумаги израсходовано ${widget.actionLabel}. '
              'Это количество спишется со склада и зачтётся как сделанное '
              'на этапе.',
            ),
            const SizedBox(height: 12),
            if (_rows.isEmpty)
              const Text(
                'В заказе не указана бумага. При необходимости нажмите «Изменить бумагу».',
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final row in _rows)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Card(
                          margin: EdgeInsets.zero,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  'Бумага №${row.slotIndex + 1}: ${row.title}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  [
                                    'План: ${formatPaperMeters(row.plan)} м',
                                    if (row.written > 0)
                                      'уже списано: ${formatPaperMeters(row.written)} м',
                                    'на складе для заказа: '
                                        '${formatPaperMeters(row.availableForOrder)} м',
                                  ].join(' · '),
                                  style: theme.textTheme.bodySmall,
                                ),
                                const SizedBox(height: 10),
                                TextField(
                                  controller: _controllers[row.paperId],
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                                  decoration: InputDecoration(
                                    labelText: 'Фактический расход',
                                    suffixText: 'м',
                                    border: const OutlineInputBorder(),
                                    errorText: _errorFor(row),
                                    errorMaxLines: 3,
                                  ),
                                  onChanged: (_) => setState(() {}),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (_rows.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Будет зачтено на этапе: ${formatPaperMeters(_total)} '
                '${_rows.first.unit}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (_total <= 0)
                Text(
                  'Укажите расход хотя бы по одной бумаге.',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context)
              .pop(const PaperUsageDialogResult.editPaper()),
          child: const Text('Изменить бумагу'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _canSave ? _save : null,
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}
