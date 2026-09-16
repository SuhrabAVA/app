/// Выбор условия, при котором блок формы обязателен.
///
/// Отдельным файлом, потому что вкладка блоков занимается списком блоков, а
/// это диалог со своим состоянием: предикат, отрицание и параметр связаны
/// между собой (параметр есть только у `handle_type_is`).
library;

import 'package:flutter/material.dart';

import '../orders/product_type_condition_options.dart';
import '../orders/product_type_settings.dart';
import 'product_type_design.dart';

/// Результат диалога.
///
/// `null` из `showDialog` — техлид закрыл окно, ничего не меняем.
/// [condition] `null` — выбрано «всегда», условия у блока стираются.
class BlockConditionChoice {
  const BlockConditionChoice(this.condition);

  final OrderBlockCondition? condition;
}

Future<BlockConditionChoice?> showBlockConditionDialog({
  required BuildContext context,
  required String blockTitle,
  required OrderBlockCondition? current,
}) =>
    showDialog<BlockConditionChoice>(
      context: context,
      builder: (_) => _BlockConditionDialog(
        blockTitle: blockTitle,
        current: current,
      ),
    );

class _BlockConditionDialog extends StatefulWidget {
  const _BlockConditionDialog({
    required this.blockTitle,
    required this.current,
  });

  final String blockTitle;
  final OrderBlockCondition? current;

  @override
  State<_BlockConditionDialog> createState() => _BlockConditionDialogState();
}

class _BlockConditionDialogState extends State<_BlockConditionDialog> {
  late String? _predicate = widget.current?.predicate;
  late bool _negate = widget.current?.negate ?? false;
  late String? _param =
      widget.current?.param ?? kHandleTypeParamLabels.keys.first;

  bool get _needsParam => _predicate == 'handle_type_is';

  void _submit() {
    if (_predicate == null) {
      Navigator.pop(context, const BlockConditionChoice(null));
      return;
    }
    Navigator.pop(
      context,
      BlockConditionChoice(OrderBlockCondition(
        predicate: _predicate!,
        negate: _negate,
        param: _needsParam ? _param : null,
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Когда обязателен: ${widget.blockTitle}'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Условие проверяется у самого заказа. Если оно не выполнено, '
                'блок для этого заказа обязательным не считается.',
                style: TextStyle(fontSize: 12, color: PtColors.mutedStrong),
              ),
              const SizedBox(height: 12),
              for (final option in kBlockConditionOptions)
                RadioListTile<String?>(
                  value: option.predicate,
                  groupValue: _predicate,
                  onChanged: (value) => setState(() => _predicate = value),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(option.label),
                ),
              if (_needsParam) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _param,
                  decoration: const InputDecoration(
                    labelText: 'Тип ручки',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final entry in kHandleTypeParamLabels.entries)
                      DropdownMenuItem<String>(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                  ],
                  onChanged: (value) => setState(() => _param = value),
                ),
              ],
              if (_predicate != null) ...[
                const SizedBox(height: 8),
                // Отрицание вынесено отдельной галочкой, а не удвоенным
                // списком: «если НЕТ печатной формы» — такой же осмысленный
                // случай, как и прямой, и дублировать ради него шесть строк
                // значит удвоить список на пустом месте.
                CheckboxListTile(
                  value: _negate,
                  onChanged: (value) => setState(() => _negate = value == true),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Наоборот — когда этого НЕТ'),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Сохранить')),
      ],
    );
  }
}
